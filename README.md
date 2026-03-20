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
- `socket_api_token` - Socket.dev API token (required)
- `socket_yml_content` - Contents of your socket.yml config (required)
- `ssl_cert` / `ssl_key` - SSL certificate PEM content (required)
- `subnet_id` - Delegated subnet for the Container Apps Environment (required)
- `min_replicas` / `max_replicas` - Scaling bounds (default: 1 / 4)
- `cpu` / `memory` - Container resources (default: 2.0 / 4Gi)

## Notes

Azure Container Apps mounts secrets as files in a shared volume at `/mnt/config/`. The template sets the `CONFIG_FILE` env var so the firewall reads socket.yml from the correct path. SSL certificate paths in your `socket.yml` should reference `/mnt/config/ssl-cert` and `/mnt/config/ssl-key`.

## Other deployment options

- **Already on Kubernetes?** Use the [Helm chart](https://github.com/socketdev-demo/socket-firewall-helm)
- **On AWS?** See [socket-firewall-aws-ecs-fargate](https://github.com/socketdev-demo/socket-firewall-aws-ecs-fargate)
- **On GCP?** See [socket-firewall-gcp-cloud-run](https://github.com/socketdev-demo/socket-firewall-gcp-cloud-run)
