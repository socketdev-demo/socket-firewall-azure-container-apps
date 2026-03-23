terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}

data "azurerm_client_config" "current" {}

locals {
  env_name = var.environment_name

  routes = [for name, upstream in var.registries : {
    path     = "/${name}"
    upstream = upstream
    registry = name
  }]

  socket_yml = yamlencode({
    ports = {
      http  = 8080
      https = 8443
    }
    socket = {
      api_url   = "https://api.socket.dev"
      fail_open = var.socket_fail_open
    }
    cache = {
      ttl = 600
    }
    ssl = {
      cert = "/mnt/config/ssl-cert"
      key  = "/mnt/config/ssl-key"
    }
    path_routing = {
      enabled = true
      domain  = "${var.domain} localhost"
      routes  = local.routes
    }
  })
}

# ── Resource Group ───────────────────────────────────────────────────────────

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ── Log Analytics ────────────────────────────────────────────────────────────

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.env_name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ── Managed Identity ─────────────────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "this" {
  name                = "id-${local.env_name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# ── Key Vault ────────────────────────────────────────────────────────────────

resource "azurerm_key_vault" "this" {
  name                       = "kv-${local.env_name}"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  enable_rbac_authorization  = true
  tags                       = var.tags
}

# Grant the managed identity access to read secrets
resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# Grant the deploying principal access to write secrets
resource "azurerm_role_assignment" "kv_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "socket_api_token" {
  name         = "socket-api-token"
  value        = var.socket_api_token
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "ssl_cert" {
  name         = "ssl-cert"
  value        = var.ssl_cert
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "ssl_key" {
  name         = "ssl-key"
  value        = var.ssl_key
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.kv_secrets_officer]
}

# ── Container Apps Environment ───────────────────────────────────────────────

resource "azurerm_container_app_environment" "this" {
  name                           = "cae-${local.env_name}"
  location                       = azurerm_resource_group.this.location
  resource_group_name            = azurerm_resource_group.this.name
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id       = var.subnet_id
  internal_load_balancer_enabled = true
  tags                           = var.tags
}

# ── Container Apps Environment Storage (socket.yml) ─────────────────────────
# Azure Container Apps supports Azure Files for volume mounts. For the config
# file and SSL certs we use Container App secrets + volume mounts of type
# "Secret", which are projected as files inside the container.

# ── Container App ────────────────────────────────────────────────────────────

resource "azurerm_container_app" "firewall" {
  name                         = "ca-${local.env_name}"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  # ── Secrets (pulled from Key Vault via managed identity) ─────────────────

  secret {
    name                = "socket-api-token"
    key_vault_secret_id = azurerm_key_vault_secret.socket_api_token.versionless_id
    identity            = azurerm_user_assigned_identity.this.id
  }

  secret {
    name                = "ssl-cert"
    key_vault_secret_id = azurerm_key_vault_secret.ssl_cert.versionless_id
    identity            = azurerm_user_assigned_identity.this.id
  }

  secret {
    name                = "ssl-key"
    key_vault_secret_id = azurerm_key_vault_secret.ssl_key.versionless_id
    identity            = azurerm_user_assigned_identity.this.id
  }

  secret {
    name  = "socket-yml"
    value = local.socket_yml
  }

  # ── Ingress (internal only) ─────────────────────────────────────────────

  ingress {
    external_enabled = false
    target_port      = 8443
    transport        = "http"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  # ── Template ────────────────────────────────────────────────────────────

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    # Volume: secrets projected as files
    volume {
      name         = "config"
      storage_type = "Secret"
    }

    container {
      name   = "socket-registry-firewall"
      image  = var.firewall_image
      cpu    = var.cpu
      memory = var.memory

      # ── Environment variables ──────────────────────────────────────────

      env {
        name        = "SOCKET_SECURITY_API_TOKEN"
        secret_name = "socket-api-token"
      }

      env {
        name  = "CONFIG_FILE"
        value = "/mnt/config/socket-yml"
      }

      env {
        name  = "REDIS_ENABLED"
        value = tostring(var.redis_enabled)
      }

      env {
        name  = "REDIS_HOST"
        value = var.redis_host
      }

      env {
        name  = "REDIS_PORT"
        value = tostring(var.redis_port)
      }

      # ── Volume mounts ─────────────────────────────────────────────────
      # Secret volumes project each secret as a file named after the secret.
      # The container's entrypoint or an init script should copy/symlink:
      #   /mnt/config/socket-yml       -> /app/socket.yml
      #   /mnt/config/ssl-cert         -> /etc/nginx/ssl/server-cert.pem
      #   /mnt/config/ssl-key          -> /etc/nginx/ssl/server-key.pem

      volume_mounts {
        name = "config"
        path = "/mnt/config"
      }

      # ── Liveness probe ────────────────────────────────────────────────

      liveness_probe {
        transport        = "HTTPS"
        port             = 8443
        path             = "/health"
        initial_delay    = 15
        interval_seconds = 30
        timeout          = 5
        failure_count_threshold = 3
      }

      # ── Readiness probe ───────────────────────────────────────────────

      readiness_probe {
        transport        = "HTTPS"
        port             = 8443
        path             = "/health"
        interval_seconds = 10
        timeout          = 3
        failure_count_threshold = 3
        success_count_threshold = 1
      }

      # ── Startup probe ─────────────────────────────────────────────────

      startup_probe {
        transport        = "HTTPS"
        port             = 8443
        path             = "/health"
        interval_seconds = 5
        timeout          = 3
        failure_count_threshold = 10
      }
    }

    # ── Scaling rule (CPU-based) ──────────────────────────────────────────

    custom_scale_rule {
      name             = "cpu-scaling"
      custom_rule_type = "cpu"
      metadata = {
        type  = "Utilization"
        value = "70"
      }
    }
  }
}
