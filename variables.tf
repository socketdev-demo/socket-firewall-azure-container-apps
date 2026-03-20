variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-socket-firewall"
}

variable "environment_name" {
  description = "Name suffix for the Container Apps Environment and related resources"
  type        = string
  default     = "socket-fw"
}

# ── Socket Firewall ──────────────────────────────────────────────────────────

variable "firewall_image" {
  description = "Docker image for the Socket Registry Firewall"
  type        = string
  default     = "socketdev/socket-registry-firewall:latest"
}

variable "socket_api_token" {
  description = "Socket Security API token"
  type        = string
  sensitive   = true
}

variable "socket_fail_open" {
  description = "Whether the firewall fails open when Socket API is unreachable"
  type        = bool
  default     = true
}

variable "socket_yml_content" {
  description = "Contents of socket.yml config file (base64-encoded)"
  type        = string
}

# ── SSL ──────────────────────────────────────────────────────────────────────

variable "ssl_cert" {
  description = "PEM-encoded SSL certificate for the firewall (base64-encoded)"
  type        = string
  sensitive   = true
}

variable "ssl_key" {
  description = "PEM-encoded SSL private key for the firewall (base64-encoded)"
  type        = string
  sensitive   = true
}

# ── Redis (optional) ────────────────────────────────────────────────────────

variable "redis_enabled" {
  description = "Enable Redis caching"
  type        = bool
  default     = false
}

variable "redis_host" {
  description = "Redis hostname"
  type        = string
  default     = ""
}

variable "redis_port" {
  description = "Redis port"
  type        = number
  default     = 6379
}

# ── Scaling ──────────────────────────────────────────────────────────────────

variable "min_replicas" {
  description = "Minimum number of container replicas"
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum number of container replicas"
  type        = number
  default     = 5
}

variable "cpu" {
  description = "CPU cores allocated to the container (e.g. 0.5, 1.0, 2.0)"
  type        = number
  default     = 1.0
}

variable "memory" {
  description = "Memory allocated to the container in Gi (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "2Gi"
}

# ── Networking ───────────────────────────────────────────────────────────────

variable "vnet_id" {
  description = "Resource ID of the VNet for internal networking"
  type        = string
}

variable "subnet_id" {
  description = "Resource ID of the subnet delegated to Container Apps Environment"
  type        = string
}

# ── Tags ─────────────────────────────────────────────────────────────────────

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    managed-by = "terraform"
    service    = "socket-registry-firewall"
  }
}
