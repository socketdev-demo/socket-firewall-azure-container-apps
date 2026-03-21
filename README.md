# Socket Firewall - Azure Container Apps (Terraform)

Terraform template for deploying the [Socket Registry Firewall](https://github.com/SocketDev/socket-nginx-firewall) on Azure Container Apps.

## What it provisions

- Resource Group
- Container Apps Environment with VNet integration and internal load balancer
- Container App with health probes and CPU-based scaling
- Key Vault for credentials (API token, SSL cert/key)
- User-assigned Managed Identity (for Key Vault access)
- Log Analytics workspace

## Prerequisites

- Terraform >= 1.5
- Azure CLI configured (`az login`)
- A VNet with a subnet delegated to Container Apps (minimum /23 CIDR)
- A Socket.dev API token ([create one here](https://socket.dev/dashboard/org/settings/api-tokens)) with `packages` and `entitlements:list` scopes
- SSL certificate and private key files

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan
terraform apply
```

## Inputs

See `variables.tf` for all configurable inputs with descriptions and defaults.

Key variables:
- `socket_api_token` - Socket.dev API token (required, sensitive)
- `domain` - Hostname clients use to reach the firewall (required). Set to the FQDN from terraform output or your custom DNS name.
- `registries` - Map of registry name to upstream URL (default: npm only)
- `ssl_cert` / `ssl_key` - SSL certificate PEM content (required, sensitive)
- `subnet_id` / `vnet_id` - Network configuration (required)
- `min_replicas` / `max_replicas` - Scaling bounds (default: 1 / 5)
- `cpu` / `memory` - Container resources (default: 1.0 / 2Gi)

## Registries

The `registries` variable controls path-based routing. Each entry creates a route at `/<name>` that proxies to the upstream URL.

```hcl
registries = {
  npm   = "https://registry.npmjs.org"
  pypi  = "https://pypi.org"
  maven = "https://repo1.maven.org/maven2"
}
```

Configure npm to use the firewall:

```bash
npm config set registry https://registry.company.com/npm
```

Configure pip:

```bash
pip install --index-url https://registry.company.com/pypi/simple <package>
```

## Outputs

- `fqdn` - Internal FQDN of the Container App
- `resource_group_name` - Resource group name
- `container_app_name` - Container App name
- `container_app_environment_name` - Container Apps Environment name
- `key_vault_name` - Key Vault name
- `managed_identity_client_id` - Managed Identity client ID

## Verify the deployment

The firewall runs on an internal load balancer, so test from a VM or resource within the VNet.

```bash
# Health check — should include "path-routing" in the response
curl -k https://<FQDN>/health
# Expected: SocketFirewall/x.x.x - Health OK - path-routing (...)

# Test a safe package
npm install lodash --registry https://<FQDN>/npm

# Test a blocked package
# IMPORTANT: clear npm cache first, or cached tarballs bypass the firewall
npm cache clean --force
npm install peacenotwar@9.1.3 --registry https://<FQDN>/npm --prefer-online
# Expected: E403 "Blocked by Security Policy"
```

## Troubleshooting

**Containers keep restarting**
Check logs in Log Analytics. The most common cause is an invalid or missing SSL certificate. Verify your `ssl_cert` and `ssl_key` values are base64-encoded PEM files.

**404 errors on package requests**
The `domain` variable must match the Host header that clients send. If you are using the Container App FQDN directly, set `domain` to that FQDN. Run `terraform output fqdn` to get the value.

**Packages install but are not scanned**
Verify your API token has the `packages` and `entitlements:list` scopes. With `socket_fail_open = true` (the default), invalid or missing tokens silently pass all packages through without scanning. Check container logs for `Firewall access validation failed` or `401` errors.

**Key Vault soft-delete conflict**
If you destroy and recreate the stack, Azure retains the Key Vault in a soft-deleted state for 7 days. Either purge it manually (`az keyvault purge --name <vault-name>`) or use a different `environment_name`.

## Notes

Azure Container Apps mounts secrets as files in a shared volume at `/mnt/config/`. The template sets the `CONFIG_FILE` env var so the firewall reads socket.yml from the correct path. SSL certificate paths in the generated `socket.yml` reference `/mnt/config/ssl-cert` and `/mnt/config/ssl-key`.

The `socket.yml` config is auto-generated from the `registries` and `domain` variables. You do not need to write or encode it manually.

## Other deployment options

- **Already on Kubernetes?** Use the [Helm chart](https://github.com/socketdev-demo/socket-firewall-helm)
- **On AWS?** See [socket-firewall-aws-ecs-fargate](https://github.com/socketdev-demo/socket-firewall-aws-ecs-fargate)
- **On GCP?** See [socket-firewall-gcp-cloud-run](https://github.com/socketdev-demo/socket-firewall-gcp-cloud-run)
