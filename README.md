# Socket Firewall - Azure Container Apps (Terraform)

Terraform template for deploying the [Socket Registry Firewall](https://github.com/SocketDev/socket-nginx-firewall) on Azure Container Apps.

## What it provisions

- Resource Group
- Container Apps Environment with VNet integration and internal load balancer
- Container App with health probes and CPU-based scaling
- Key Vault for credentials (API token, SSL cert/key, Redis password)
- User-assigned Managed Identity (for Key Vault access)
- Log Analytics workspace

It does not provision Redis. Bring an Azure Cache for Redis instance if you want a shared cache across replicas (see Inputs).

## Prerequisites

- Terraform >= 1.5
- Azure CLI configured (`az login`)
- **Permissions**: the deploying principal needs Owner, or Contributor plus User Access Administrator, on the target scope. The template creates Key Vault role assignments; plain Contributor fails mid-apply.
- **A dedicated subnet** in your VNet: empty, delegated to `Microsoft.App/environments`, and at least **/23**. This is an Azure Container Apps platform requirement (consumption architecture), not a Socket one. A shared subnet fails at apply time with `ManagedEnvironmentInvalidNetworkConfiguration`. To create one:

  ```bash
  # find free address space
  az network vnet subnet list -g <rg> --vnet-name <vnet> --query "[].{name:name,prefix:addressPrefix}" -o table

  az network vnet subnet create -g <rg> --vnet-name <vnet> -n snet-socket-firewall \
    --address-prefixes <free /23> --delegations Microsoft.App/environments
  ```

- A Socket.dev API token ([create one here](https://socket.dev/dashboard/org/settings/api-tokens)) with `packages` and `entitlements:list` scopes. Your org also needs the `firewall` entitlement provisioned; without it (or with missing token scopes), the firewall fails open and passes everything through unscanned. Confirm with your Socket contact before go-live.

## Quick start

```bash
git clone https://github.com/socketdev-demo/socket-firewall-azure-container-apps.git
cd socket-firewall-azure-container-apps
./setup.sh
```

`setup.sh` walks you through every value interactively: one question per setting, a hint about what it controls and where to find the answer, and validation where it matters (Key Vault name length, subnet size and delegation when you're logged into the Azure CLI). It writes `terraform.tfvars`, backs up any existing one, and prints the secret-export commands. Re-running it picks up your previous answers as defaults.

Prefer to edit by hand? `cp terraform.tfvars.example terraform.tfvars` and use the table below.

### What to set in terraform.tfvars

| Variable | Set it to | How to get the value |
|---|---|---|
| `location` | Azure region | match your VNet's region |
| `resource_group_name` | a new RG name | the template **creates** this RG. If it already exists, `terraform import azurerm_resource_group.this <id>` first |
| `environment_name` | a short org-unique suffix, max 21 chars | it becomes the Key Vault name (`kv-<name>`), which must be **globally unique across Azure** and at most 24 chars. Generic names collide |
| `firewall_image` | a pinned version tag | check [Docker Hub tags](https://hub.docker.com/r/socketdev/socket-registry-firewall/tags). Pin a version; `latest` only resolves at revision creation and makes "what version are you running" unanswerable later |
| `domain` | the hostname developers will use | e.g. `sfw.yourcompany.com`. After the first apply, append the FQDN from `terraform output fqdn` (space-separated) and apply again if clients will also use it |
| `vnet_id` | VNet resource ID | `az network vnet show -g <rg> -n <vnet> --query id -o tsv` |
| `subnet_id` | the dedicated subnet's resource ID | `az network vnet subnet show -g <rg> --vnet-name <vnet> -n snet-socket-firewall --query id -o tsv` |
| `registries` | ecosystems to proxy | see the Registries section below |
| `redis_*` | optional shared cache | `az redis create -g <rg> -n <name> -l <region> --sku Standard --vm-size c1` (~20 min). Host `<name>.redis.cache.windows.net`, port `6380` |

Secrets stay out of the file. Set them in the shell you run Terraform from (re-set in every new terminal):

```bash
# bash/zsh — read -rs keeps the token out of shell history
read -rs TF_VAR_socket_api_token && export TF_VAR_socket_api_token
export TF_VAR_redis_password="$(az redis list-keys -g <rg> -n <name> --query primaryKey -o tsv)"
```

```powershell
# PowerShell
$env:TF_VAR_socket_api_token = Read-Host -MaskInput "Socket API token"
$env:TF_VAR_redis_password = (az redis list-keys -g <rg> -n <name> --query primaryKey -o tsv)
```

To keep secrets out of Terraform state entirely, use the `*_key_vault_secret_id` variables instead (see Inputs).

### Deploy

```bash
terraform init
terraform plan
terraform apply   # 20-30 minutes; the Container Apps Environment is the slow part
```

### After the first apply

```bash
terraform output fqdn        # internal FQDN of the firewall
terraform output static_ip   # DNS A-record target
```

Create internal DNS records pointing at `static_ip`: one for your `domain` hostname, plus (for transparent enterprise routing) one per registry hostname you proxy (`registry.npmjs.org`, `pypi.org`, `api.nuget.org`, ...). Only the exact registry hostnames, never the root domains.

## Network access model

The Container Apps Environment uses an **internal load balancer**: nothing is exposed to the internet. The app's ingress is set to `external_enabled = true`, which on an internal environment means **VNet-visible** (the portal calls this "Limited to VNet"), not internet-facing. Clients reach the firewall only from the VNet, peered networks, VPN, or a fronting layer such as Azure Front Door with private link.

Inbound TLS terminates at the Container Apps ingress using the certificate this template registers (self-signed by default, SANs from `domain`); the ingress then forwards plain HTTP to the firewall's port 8080 internally.

**Bypass prevention** (recommended): at your corporate firewall, block outbound traffic to the public registry hostnames except from the firewall's subnet. Scope the exception to the **subnet CIDR** (e.g. `10.x.x.0/23`), not the `static_ip` — that IP is the inbound load balancer; the firewall's own upstream fetches egress from replica IPs within the subnet. An exception scoped to the ingress IP blocks the firewall's own downloads and fails the org closed.

## Inputs

See `variables.tf` for all configurable inputs with descriptions and defaults.

Key variables:
- `socket_api_token` - Socket.dev API token (required, sensitive)
- `domain` - Hostname clients use to reach the firewall (required). Set to the FQDN from terraform output or your custom DNS name.
- `registries` - Map of registry name to upstream URL (default: npm only)
- `registry_overrides` - Map a route name to its firewall ecosystem type when they differ (e.g. `"plugins-gradle" = "maven"`, `"repository/npm-remote" = "npm"`)
- `registry_domains` - Host-based routing for transparent DNS interception (see the Transparent DNS interception section). Each entry's hostnames are routed by Host header, bound as Container App custom domains, and added to the generated cert's SANs.
- `ssl_cert` / `ssl_key` - SSL certificate PEM content (ignored when `generate_self_signed_cert = true`, the default)
- `subnet_id` / `vnet_id` - Network configuration (required)
- `min_replicas` / `max_replicas` - Scaling bounds (default: 1 / 5)
- `cpu` / `memory` - Container resources (default: 1.0 / 2Gi)
- `debug_logging_enabled` - Enable debug logging for HTTP requests/responses (default: false)
- `debug_user_agent_filter` - Glob pattern to filter debug logs by user-agent (default: "")
- `recently_published_enabled_ecosystems` - Ecosystems to enforce recently-published blocking (default: [])
- `redis_enabled` / `redis_host` / `redis_port` / `redis_password` / `redis_ssl` - Optional shared cache across replicas (default: disabled). For Azure Cache for Redis: use cluster mode disabled (Basic/Standard, or Premium with clustering off), port 6380, `redis_ssl = true`, and set `redis_password` to an access key. Redis failures fail safe to each replica's local cache.
- `socket_api_token_key_vault_secret_id` / `ssl_cert_key_vault_secret_id` / `ssl_key_key_vault_secret_id` / `redis_password_key_vault_secret_id` - Reference existing Key Vault secrets created out-of-band instead of passing values through Terraform. Secret values passed directly (`socket_api_token`, `ssl_cert`/`ssl_key`, `redis_password`) are persisted in Terraform state even though they are marked sensitive; the `*_key_vault_secret_id` variants keep them out of Terraform entirely. The Container App managed identity needs the Key Vault Secrets User role on the vault holding referenced secrets. Note: with `generate_self_signed_cert = true` (the default), the private key is generated by Terraform and stored in state regardless; bring your own certificate via the KV references if state must stay free of key material. Either way, protect the state file itself (remote backend with access control).

## Registries

The `registries` variable controls path-based routing. Each entry creates a route at `/<name>` that proxies to the upstream URL.

### Direct routes (firewall in front of public registries)

All supported ecosystems:

```hcl
registries = {
  npm              = "https://registry.npmjs.org"
  pypi             = "https://pypi.org"
  maven            = "https://repo1.maven.org/maven2"
  "plugins-gradle" = "https://plugins.gradle.org/m2"
  rubygems         = "https://rubygems.org"
  go               = "https://proxy.golang.org"
  cargo            = "https://index.crates.io"
  nuget            = "https://api.nuget.org"
  "nuget-v2"       = "https://www.nuget.org/api/v2"
  conda            = "https://repo.anaconda.com/pkgs/main"
  openvsx          = "https://open-vsx.org"
}

registry_overrides = {
  "plugins-gradle" = "maven" # route name differs from the ecosystem type
  "nuget-v2"       = "nuget"
}
```

Client configuration:

```bash
npm config set registry https://registry.company.com/npm
pip install --index-url https://registry.company.com/pypi/simple <package>
gem sources --add https://registry.company.com/rubygems/
go env -w GOPROXY=https://registry.company.com/go
dotnet nuget add source https://registry.company.com/nuget/v3/index.json -n socket-firewall
conda config --add channels https://registry.company.com/conda
```

```toml
# ~/.cargo/config.toml
[source.crates-io]
replace-with = "socket-firewall"
[source.socket-firewall]
registry = "sparse+https://registry.company.com/cargo/"
```

Maven/Gradle: point your `<mirror>` (settings.xml) or `repositories`/`pluginManagement` blocks (Gradle) at `https://registry.company.com/maven` and `https://registry.company.com/plugins-gradle`. VS Code-compatible editors using Open VSX: set the extension gallery service URL to `https://registry.company.com/openvsx`.

### Upstream mode (firewall in front of Artifactory)

If you use Artifactory (or another artifact repository manager), use `/repository/<repo-name>` paths to match Artifactory's URL convention, and map each route to its ecosystem with `registry_overrides` (the firewall selects its parser by ecosystem; without the override the route has no parser and traffic passes through unscanned):

```hcl
registries = {
  "repository/npm-remote"  = "https://company.jfrog.io/artifactory/api/npm/npm-remote"
  "repository/pypi-remote" = "https://company.jfrog.io/artifactory/api/pypi/pypi-remote"
}

registry_overrides = {
  "repository/npm-remote"  = "npm"
  "repository/pypi-remote" = "pypi"
}
```

```bash
npm config set registry https://registry.company.com/repository/npm-remote
pip install --index-url https://registry.company.com/repository/pypi-remote/simple <package>
```

### Transparent DNS interception (zero developer configuration)

The enterprise rollout pattern: internal DNS points the real registry hostnames (`registry.npmjs.org`, `pypi.org`, ...) at the firewall, so every developer and CI machine routes through it with nothing configured on the endpoint, and nothing an AI coding agent can edit its way around. Requests arrive carrying the original hostname and full path, which path routing alone returns 404 for — `registry_domains` adds the host-based routing that matches them:

```hcl
registry_domains = {
  npm          = { domains = ["registry.npmjs.org"], upstream = "https://registry.npmjs.org" }
  pypi         = { domains = ["pypi.org"], upstream = "https://pypi.org" }
  "pypi-files" = { domains = ["files.pythonhosted.org"], upstream = "https://files.pythonhosted.org", registry = "pypi" }
}
```

`setup.sh` generates the full map for your chosen ecosystems, including the companion hosts people forget (`files.pythonhosted.org` for pip downloads, `static.crates.io` for cargo). Upstreams are host roots because transparent requests keep their full path. The template binds every listed hostname as a Container App custom domain (internal environments accept third-party hostnames without ownership validation) and, with the generated cert, adds them as SANs.

Three things must stay in lockstep, same hostname list in each: this map, the internal DNS records (A records to `terraform output static_ip`), and the certificate SANs.

Prove it works before touching DNS, from any machine in the VNet:

```bash
# simulate the DNS record with --resolve
curl -s --resolve registry.npmjs.org:443:$(terraform output -raw static_ip) https://registry.npmjs.org/lodash/4.17.21
# expect package JSON; then a policy block through the same path, expect 403
curl -s --resolve registry.npmjs.org:443:$(terraform output -raw static_ip) -o /dev/null -w '%{http_code}\n' https://registry.npmjs.org/lodash/-/lodash-3.0.0.tgz
```

After changing `registry_domains` (or `registries`) on a running deployment, restart the revision: the firewall renders its nginx config from socket.yml at startup, and Azure updates the mounted config in place without restarting anything. See Troubleshooting.

## Outputs

- `fqdn` - Internal FQDN of the Container App
- `static_ip` - Static IP of the internal load balancer (DNS A-record target)
- `resource_group_name` - Resource group name
- `container_app_name` - Container App name
- `container_app_environment_name` - Container Apps Environment name
- `key_vault_name` - Key Vault name
- `managed_identity_client_id` - Managed Identity client ID
- `troubleshooting` - Pre-filled debugging commands for this deployment

## Verify the deployment

One concept first: the firewall blocks a package only when one of its alerts is set to **Block** in your org's Socket security policy. Policy changes take ~10 minutes to reach a running firewall.

### Stage 1: from inside the container (works immediately, no network setup)

```bash
az containerapp exec -n <app-name> -g <rg>
```

In the container console:

```bash
# health — expect: SocketFirewall/x.x.x - Health OK - path-routing (...)
curl -sk https://localhost:8443/health

# package metadata proxied — expect lodash packument JSON
curl -sk https://localhost:8443/npm/lodash | head -c 200

# tarball URLs rewritten to your domain, not the FQDN
curl -sk https://localhost:8443/npm/lodash | grep -o '"tarball":"[^"]*"' | head -3

# allowed download — expect 200
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8443/npm/lodash/-/lodash-4.18.1.tgz

# blocked download, known malware (blocks under the default policy) — expect 403
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8443/npm/crossenv/-/crossenv-0.0.2-security.tgz

# blocked download, critical CVE (blocks when Critical CVE policy = Block) — expect 403
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8443/npm/lodash/-/lodash-3.0.0.tgz
```

`crossenv@0.0.2-security` is an npm security-holder placeholder (harmless, flagged as malware). `lodash@3.0.0` is harmless but carries critical CVE-2019-10744.

### Stage 2: from a machine in the VNet (simulates the DNS rollout)

Outside the container, traffic goes through the ingress on standard **443**, not 8443. Before DNS records exist, use a hosts entry:

```bash
echo "$(terraform output -raw static_ip) sfw.yourcompany.com" | sudo tee -a /etc/hosts

curl -sk https://sfw.yourcompany.com/health

# trust the self-signed cert properly for npm
az keyvault secret show --vault-name "$(terraform output -raw key_vault_name)" \
  --name ssl-cert --query value -o tsv > /tmp/sfw-ca.pem
export NODE_EXTRA_CA_CERTS=/tmp/sfw-ca.pem

mkdir /tmp/sfw-test && cd /tmp/sfw-test && npm init -y
npm install lodash --registry https://sfw.yourcompany.com/npm     # expect success

# IMPORTANT: clear the cache first, or cached tarballs bypass the firewall
npm cache clean --force
npm install lodash@3.0.0 --registry https://sfw.yourcompany.com/npm --prefer-online
# Expected: E403 "Blocked by Security Policy"
```

### Reading firewall decisions

Every checked request logs a `SOCKET_DECISION` entry showing the alerts found, the policy action applied, and the upstream status. This is the source of truth when a result surprises you:

```bash
az containerapp logs show -n <app-name> -g <rg> --type console --tail 300 > /tmp/sfw.log
grep SOCKET_DECISION /tmp/sfw.log
grep -i redis /tmp/sfw.log    # confirm Redis connected; a bad key fails silently to local cache
```

## Certificates and client trust

**Default (pilots):** `generate_self_signed_cert = true` creates a 10-year cert with SANs covering `domain` plus all `registry_domains` hostnames. Test clients need `-k`/`NODE_EXTRA_CA_CERTS`-style trust since nothing signs it.

**Production:** bring a cert from your internal CA — endpoints already trust the corporate root, so developers see valid TLS with zero prompts. Set `generate_self_signed_cert = false` and export the PEMs before apply:

```bash
export TF_VAR_ssl_cert="$(cat /path/to/cert-chain.pem)"
export TF_VAR_ssl_key="$(cat /path/to/private-key.pem)"
```

The cert file must contain the **full chain** (leaf plus intermediates) and a SAN for every hostname clients will use — the `domain` value plus every `registry_domains` hostname. Verify both before applying:

```bash
grep -c "BEGIN CERT" cert-chain.pem    # expect 2 or more
openssl x509 -in cert-chain.pem -noout -ext subjectAltName
```

A leaf-only file is the classic silent failure: browsers and `curl.exe` still validate (Windows fetches missing intermediates on its own), while npm fails with `UNABLE_TO_VERIFY_LEAF_SIGNATURE` because Node never does.

**Client runtime trust (Windows fleets):** the OS trust store only covers some package managers. Tools that read the Windows cert store work as soon as your GPO root is present: NuGet/dotnet/Visual Studio, Go, Cargo (standard toolchain), and VS Code-family editors. Tools that ship their own trust bundles need pointing — all at one combined PEM (public roots plus your root and intermediate appended):

| Runtime | Mechanism |
|---|---|
| npm and all Node tools (including AI coding agents) | `NODE_EXTRA_CA_CERTS=<bundle>` (additive) |
| pip | `PIP_CERT=<bundle>` (replaces the default bundle — must be the combined file) |
| Python requests-based tools, conda | `REQUESTS_CA_BUNDLE=<bundle>` |
| RubyGems and other OpenSSL-linked tools | `SSL_CERT_FILE=<bundle>` (also replaces — combined file only) |
| Java / Maven / Gradle | `keytool -importcert -cacerts -alias corp-root -file root.pem -storepass changeit -noprompt`, once per JDK install |

Push the bundle and the four machine environment variables via your MDM. One more if anyone uses `uv`: `UV_NATIVE_TLS=true` makes it read the OS store.

**Testing tip:** WSL's Ubuntu has its own CA bundle and does not inherit the Windows cert store. To test the trust path developers will actually use, run `curl.exe` (the Windows curl, callable from WSL bash) rather than WSL's `curl`.

## Troubleshooting

After `terraform apply`, run `terraform output troubleshooting` to see useful debugging commands for your deployment.

To enable verbose logging, set `log_level = "debug"` in your tfvars and redeploy. This sets nginx error_log to debug level, showing TLS handshake details, upstream connections, and request routing decisions.

**Apply fails: `ManagedEnvironmentInvalidNetworkConfiguration: The delegated subnet cannot be used by any other Azure resources`**
The subnet has other resources in it, is missing the `Microsoft.App/environments` delegation, or is smaller than /23. Container Apps requires sole ownership of a dedicated /23+ subnet (see Prerequisites). Create the subnet, update `subnet_id`, and re-run apply; Terraform resumes where it stopped.

**Apply fails on a role assignment (AuthorizationFailed)**
The deploying principal lacks User Access Administrator/Owner. See Prerequisites.

**"Azure Container App - Unavailable" page from a VNet client**
The ingress is scoped to the Container Apps environment instead of the VNet, or is pointed at the wrong port. Check:

```bash
az containerapp ingress show -n <app-name> -g <rg> --query '{external:external, targetPort:targetPort, transport:transport}'
```

Expected: `external: true`, `targetPort: 8080`. If you fix these in the Azure portal, mirror the change in this template's ingress block too — the next `terraform apply` reverts portal-only changes.

**curl returns `000`**
The connection never happened. Most often: running a `localhost:8443` command outside the container (use `az containerapp exec` first), or hitting `:8443` from outside (external traffic uses 443 through the ingress).

**Blocked package returns 200**
- Clear the package manager cache (`npm cache clean --force`); cached artifacts never reach the firewall.
- Check the alert's action in your Socket security policy. The firewall blocks only alerts set to **Block** — a package whose alerts sit at Warn or Monitor passes through and is logged. (Example: protestware like `peacenotwar` is at Warn by default.)
- Policy changes take ~10 minutes to propagate; per-package decisions are also cached briefly.
- Read the `SOCKET_DECISION` log line for the package; it shows exactly which alerts fired and which action applied.

**Containers keep restarting**
Check logs in Log Analytics or with `az containerapp logs show`. The most common cause is an invalid or missing SSL certificate. If using the default self-signed cert (`generate_self_signed_cert = true`), verify the SANs with `terraform output ssl_cert_sans`.

**404 errors on package requests**
The `domain` variable must match the Host header that clients send. If you are using the Container App FQDN directly, set `domain` to that FQDN. Run `terraform output fqdn` to get the value.

**Azure Front Door: 421 SSLMismatchedSNI**
Front Door validates that the Host header matches a custom domain configured on the Front Door profile. This error means either:
1. The custom domain is not associated with the Front Door endpoint/route, or
2. The origin host header does not match the cert's SANs.

The `domain` variable controls the cert SANs (when using the self-signed cert). Include all hostnames that Front Door might send, separated by spaces:
```hcl
domain = "registry.company.com ca-socket-fw.xxxxx.eastus.azurecontainerapps.io"
```

**Tarball URLs point to the Container App FQDN instead of the customer-facing domain**
The firewall rewrites tarball URLs using the `Host` header it receives. If Front Door's origin host header is set to the Container App FQDN, tarball URLs will use that FQDN, and npm clients will try to download tarballs directly (bypassing Front Door), which fails with ECONNRESET.

Fix: Set the Front Door origin host header to the customer-facing domain (e.g., `registry.company.com`), and make sure that domain is included in the `domain` variable so the cert's SANs match.

**Packages install but are not scanned**
Verify your API token has the `packages` and `entitlements:list` scopes, and that the org has the `firewall` entitlement. With `socket_fail_open = true` (the default), invalid tokens or a missing entitlement silently pass all packages through without scanning. Check container logs for `Firewall access validation failed` or `401` errors; a healthy deployment shows `SOCKET_DECISION` entries with `socket_api_response_code: 200`.

**Config changes applied but the firewall behaves like the old config (e.g. transparent registry hostnames return the firewall's branded 404)**
The firewall renders its nginx config from socket.yml once at startup, and Azure updates a changed secret volume in place without restarting the replica. The tell: `cat /mnt/config/socket-yml` in the container shows the new config while the firewall serves old routes, and `ls /app/sites-enabled/` is missing the per-registry conf files. Restart the revision so the entrypoint re-reads the mounted config:
```bash
az containerapp revision restart -n <app-name> -g <rg> --revision <name>
```
Then confirm: `ls /app/sites-enabled/` shows one conf per `registry_domains` entry.

**npm fails with UNABLE_TO_VERIFY_LEAF_SIGNATURE while curl.exe and browsers work**
Two causes, usually both. The served cert is missing its intermediate (Windows silently fetches missing intermediates, Node doesn't — re-export the full chain into `TF_VAR_ssl_cert` and re-apply), and Node doesn't read the Windows cert store at all (set `NODE_EXTRA_CA_CERTS` — see Certificates and client trust). Never leave `strict-ssl false` on a developer machine as the workaround.

**Secret changes not taking effect after terraform apply**
Running replicas keep the secret values they started with. Restart the revision (re-reads updated secret volumes and env secrets) or force a new one:
```bash
az containerapp revision restart -n <app-name> -g <rg> --revision <name>
# or
az containerapp update -n <app-name> -g <rg>
```

## Notes

**Custom domain binding**: When `generate_self_signed_cert = true`, the template automatically registers each hostname in the `domain` variable as a custom domain on the Container App. This is required so the Container Apps ingress accepts requests with those Host headers. Without it, requests from Front Door (or any client using a custom hostname) get a 404 from the ingress layer before reaching nginx.

The `socket.yml` config is auto-generated from the `registries` and `domain` variables. You do not need to write or encode it manually.

## Other deployment options

- **Already on Kubernetes?** Use the [Helm chart](https://github.com/socketdev-demo/socket-firewall-helm)
- **On AWS?** See [socket-firewall-aws-ecs-fargate](https://github.com/socketdev-demo/socket-firewall-aws-ecs-fargate)
- **On GCP?** See [socket-firewall-gcp-cloud-run](https://github.com/socketdev-demo/socket-firewall-gcp-cloud-run)
