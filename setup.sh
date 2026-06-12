#!/usr/bin/env bash
# Interactive pre-flight for the Socket Firewall Azure Container Apps template.
#
# Walks through every value terraform.tfvars needs, explains what each setting
# does, and tells you where to find the answer. Writes terraform.tfvars when
# done (backing up any existing one) and prints the secret-export commands and
# deploy steps. Safe to re-run; existing values become the defaults.
#
# Run from the repo root:  ./setup.sh
# Works in bash on Linux, macOS, WSL, and Git Bash.

set -euo pipefail

TFVARS="terraform.tfvars"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }

if [ ! -t 0 ] && [ -z "${SETUP_NONINTERACTIVE_OK:-}" ]; then
  echo "setup.sh is interactive; run it from a terminal." >&2
  exit 1
fi

# ── helpers ──────────────────────────────────────────────────────────────────

# Read an existing simple `key = "value"` assignment from terraform.tfvars
existing() {
  [ -f "$TFVARS" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" "$TFVARS" | head -1
}

# ask <var-name> <prompt> <default> <hint lines...>
ask() {
  local var="$1" prompt="$2" default="$3"; shift 3
  echo ""
  bold "$prompt"
  local line
  for line in "$@"; do dim "  $line"; done
  local suffix=""
  [ -n "$default" ] && suffix=" [$default]"
  printf '> %s%s: ' "$var" "$suffix"
  local answer
  IFS= read -r answer
  [ -z "$answer" ] && answer="$default"
  REPLY="$answer"
}

# ask_yn <prompt> <default y|n> <hint lines...>
ask_yn() {
  local prompt="$1" default="$2"; shift 2
  echo ""
  bold "$prompt"
  local line
  for line in "$@"; do dim "  $line"; done
  local suffix="[y/N]"
  [ "$default" = "y" ] && suffix="[Y/n]"
  printf '> %s: ' "$suffix"
  local answer
  IFS= read -r answer
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|Yes) REPLY="y" ;;
    *)           REPLY="n" ;;
  esac
}

# ── az CLI detection (optional, used for pickers and validation) ─────────────

AZ_OK=0
if command -v az >/dev/null 2>&1 && az account show >/dev/null 2>&1; then
  AZ_OK=1
fi

echo ""
bold "Socket Firewall - Azure Container Apps setup"
dim "Answers are written to $TFVARS. Press Enter to accept a [default]."
if [ "$AZ_OK" = "1" ]; then
  dim "Azure CLI detected and logged in: subscription $(az account show --query name -o tsv 2>/dev/null)"
else
  dim "Azure CLI not available or not logged in; you'll paste resource IDs manually."
fi

# ── basics ───────────────────────────────────────────────────────────────────

ask "location" "Azure region" "$(existing location)" \
  "Region for every resource the template creates." \
  "Match the region of the VNet you plan to use."
LOCATION="$REPLY"
[ -z "$LOCATION" ] && LOCATION="eastus"

ask "resource_group_name" "Resource group name" "$(existing resource_group_name)" \
  "The template CREATES this resource group. If it already exists in your" \
  "subscription, import it first: terraform import azurerm_resource_group.this <id>"
RG="$REPLY"
[ -z "$RG" ] && RG="rg-socket-firewall"

while :; do
  ask "environment_name" "Environment name suffix" "$(existing environment_name)" \
    "Names every resource (cae-<name>, ca-<name>, kv-<name>)." \
    "The Key Vault name kv-<name> must be GLOBALLY unique across Azure and at" \
    "most 24 characters, so keep this 21 chars or fewer and org-specific." \
    "Example: socket-acme-prod"
  ENV_NAME="$REPLY"
  [ -z "$ENV_NAME" ] && ENV_NAME="socket-fw"
  if [ "${#ENV_NAME}" -le 21 ]; then break; fi
  warn "  '$ENV_NAME' is ${#ENV_NAME} chars; the Key Vault name would exceed 24. Try shorter."
done

ask "firewall_image" "Firewall container image" "$(existing firewall_image)" \
  "Pin a version tag rather than :latest, so you always know what you're" \
  "running. Tags: https://hub.docker.com/r/socketdev/socket-registry-firewall/tags"
IMAGE="$REPLY"
[ -z "$IMAGE" ] && IMAGE="socketdev/socket-registry-firewall:latest"
case "$IMAGE" in *:latest) warn "  Heads up: :latest only resolves at deploy time. Pinning a version is recommended." ;; esac

ask "domain" "Firewall hostname (the name developers will use)" "$(existing domain)" \
  "Used for routing, the custom-domain binding, and cert SANs." \
  "Pick the internal DNS name you plan to create, e.g. sfw.yourcompany.com." \
  "After the first apply you can append the Azure FQDN, space-separated."
DOMAIN="$REPLY"
while [ -z "$DOMAIN" ]; do
  warn "  domain is required."
  ask "domain" "Firewall hostname" "" ""
  DOMAIN="$REPLY"
done

# ── networking ───────────────────────────────────────────────────────────────

VNET_ID="$(existing vnet_id)"
SUBNET_ID="$(existing subnet_id)"

echo ""
bold "Networking"
dim "  The firewall needs your VNet's resource ID and a DEDICATED subnet:"
dim "  empty, delegated to Microsoft.App/environments, and at least /23."
dim "  A shared or undersized subnet fails mid-apply with"
dim "  ManagedEnvironmentInvalidNetworkConfiguration."

if [ "$AZ_OK" = "1" ]; then
  echo ""
  dim "  VNets in this subscription:"
  az network vnet list --query '[].{Name:name, RG:resourceGroup, Space:join(`,`, addressSpace.addressPrefixes)}' -o table 2>/dev/null | sed 's/^/  /' || true
fi

ask "vnet_id" "VNet resource ID" "$VNET_ID" \
  "Get it with: az network vnet show -g <rg> -n <vnet> --query id -o tsv"
VNET_ID="$REPLY"
while [ -z "$VNET_ID" ]; do
  warn "  vnet_id is required."
  ask "vnet_id" "VNet resource ID" "" ""
  VNET_ID="$REPLY"
done

if [ "$AZ_OK" = "1" ] && [[ "$VNET_ID" == */virtualNetworks/* ]]; then
  VNET_RG="$(printf '%s' "$VNET_ID" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')"
  VNET_NAME="${VNET_ID##*/}"
  echo ""
  dim "  Subnets in $VNET_NAME (look for delegation Microsoft.App/environments and a /23 or larger):"
  az network vnet subnet list -g "$VNET_RG" --vnet-name "$VNET_NAME" \
    --query '[].{Name:name, Prefix:addressPrefix, Delegation:join(`,`, delegations[].serviceName)}' -o table 2>/dev/null | sed 's/^/  /' || true
  dim "  Create one if needed:"
  dim "  az network vnet subnet create -g $VNET_RG --vnet-name $VNET_NAME -n snet-socket-firewall \\"
  dim "    --address-prefixes <free /23> --delegations Microsoft.App/environments"
fi

ask "subnet_id" "Dedicated subnet resource ID" "$SUBNET_ID" \
  "Get it with: az network vnet subnet show -g <rg> --vnet-name <vnet> -n <subnet> --query id -o tsv"
SUBNET_ID="$REPLY"
while [ -z "$SUBNET_ID" ]; do
  warn "  subnet_id is required."
  ask "subnet_id" "Dedicated subnet resource ID" "" ""
  SUBNET_ID="$REPLY"
done

# Validate the subnet when az is available
if [ "$AZ_OK" = "1" ] && [[ "$SUBNET_ID" == */subnets/* ]]; then
  SUB_JSON="$(az network vnet subnet show --ids "$SUBNET_ID" -o json 2>/dev/null || true)"
  if [ -n "$SUB_JSON" ]; then
    PREFIX="$(printf '%s' "$SUB_JSON" | sed -n 's/.*"addressPrefix": "\([^"]*\)".*/\1/p' | head -1)"
    MASK="${PREFIX##*/}"
    if [ -n "$MASK" ] && [ "$MASK" -gt 23 ] 2>/dev/null; then
      warn "  Subnet is $PREFIX. Container Apps requires /23 or larger; the apply WILL fail."
    fi
    if ! printf '%s' "$SUB_JSON" | grep -q 'Microsoft.App/environments'; then
      warn "  Subnet has no Microsoft.App/environments delegation. Add it:"
      warn "  az network vnet subnet update --ids $SUBNET_ID --delegations Microsoft.App/environments"
    fi
  fi
fi

# ── registries ───────────────────────────────────────────────────────────────

ALL_ECOSYSTEMS="npm pypi maven plugins-gradle rubygems go cargo nuget nuget-v2 conda openvsx"

echo ""
bold "Package ecosystems"
dim "  Each one becomes a route on the firewall (/npm, /pypi, ...)."
dim "  Available: $ALL_ECOSYSTEMS"
ask "registries" "Ecosystems to proxy (comma- or space-separated, or 'all')" "all" \
  "Pick what your teams actually use; more can be added later with one apply."
ECO_INPUT="$(printf '%s' "$REPLY" | tr ',' ' ' | tr -s ' ')"
[ "$ECO_INPUT" = "all" ] && ECO_INPUT="$ALL_ECOSYSTEMS"

ECOSYSTEMS=""
for e in $ECO_INPUT; do
  case " $ALL_ECOSYSTEMS " in
    *" $e "*) ECOSYSTEMS="$ECOSYSTEMS $e" ;;
    *) warn "  Skipping unknown ecosystem '$e'" ;;
  esac
done
ECOSYSTEMS="${ECOSYSTEMS# }"
[ -z "$ECOSYSTEMS" ] && ECOSYSTEMS="npm"

upstream_for() {
  case "$1" in
    npm)            echo "https://registry.npmjs.org" ;;
    pypi)           echo "https://pypi.org" ;;
    maven)          echo "https://repo1.maven.org/maven2" ;;
    plugins-gradle) echo "https://plugins.gradle.org/m2" ;;
    rubygems)       echo "https://rubygems.org" ;;
    go)             echo "https://proxy.golang.org" ;;
    cargo)          echo "https://index.crates.io" ;;
    nuget)          echo "https://api.nuget.org" ;;
    nuget-v2)       echo "https://www.nuget.org/api/v2" ;;
    conda)          echo "https://repo.anaconda.com/pkgs/main" ;;
    openvsx)        echo "https://open-vsx.org" ;;
  esac
}

override_for() {
  case "$1" in
    plugins-gradle) echo "maven" ;;
    nuget-v2)       echo "nuget" ;;
    *)              echo "" ;;
  esac
}

# ── transparent DNS interception ─────────────────────────────────────────────

ask_yn "Enable transparent DNS interception (host-based routing)?" "n" \
  "For rollouts where internal DNS points the REAL registry hostnames" \
  "(registry.npmjs.org, pypi.org, ...) at the firewall so developers need" \
  "zero configuration. Generates the registry_domains block. Pair it with a" \
  "certificate developers trust that carries those hostnames as SANs," \
  "usually one from your internal CA."
TRANSPARENT="$REPLY"

# entry: <key> <hostname> <upstream> <registry-override>
transparent_entries() {
  for e in $ECOSYSTEMS; do
    case "$e" in
      npm)            echo "npm registry.npmjs.org https://registry.npmjs.org -" ;;
      pypi)           echo "pypi pypi.org https://pypi.org -"
                      echo "pypi-files files.pythonhosted.org https://files.pythonhosted.org pypi" ;;
      maven)          echo "maven repo1.maven.org https://repo1.maven.org/maven2 -" ;;
      plugins-gradle) echo "plugins-gradle plugins.gradle.org https://plugins.gradle.org maven" ;;
      rubygems)       echo "rubygems rubygems.org https://rubygems.org -" ;;
      go)             echo "go proxy.golang.org https://proxy.golang.org -" ;;
      cargo)          echo "cargo index.crates.io https://index.crates.io -"
                      echo "cargo-dl static.crates.io https://static.crates.io cargo" ;;
      nuget)          echo "nuget api.nuget.org https://api.nuget.org -" ;;
      nuget-v2)       echo "nuget-v2 www.nuget.org https://www.nuget.org nuget" ;;
      conda)          echo "conda repo.anaconda.com https://repo.anaconda.com -" ;;
      openvsx)        echo "openvsx open-vsx.org https://open-vsx.org -" ;;
    esac
  done
}

# ── certificate ──────────────────────────────────────────────────────────────

ask_yn "Generate a self-signed certificate?" "y" \
  "y = the template generates a 10-year cert with SANs from your hostnames." \
  "    Fine for pilots; clients must trust it (curl -k, NODE_EXTRA_CA_CERTS)." \
  "n = bring a certificate from your internal CA (the production setup," \
  "    since endpoints already trust your root). You'll export the PEMs as" \
  "    environment variables before terraform apply; the file must contain" \
  "    the FULL chain, leaf plus intermediates. Check with:" \
  "    grep -c 'BEGIN CERT' your-chain.pem   (expect 2 or more)"
SELF_SIGNED_BOOL="true"
[ "$REPLY" = "n" ] && SELF_SIGNED_BOOL="false"

# ── redis ────────────────────────────────────────────────────────────────────

ask_yn "Enable Redis (shared decision cache across replicas)?" "n" \
  "Recommended when min_replicas > 1 and required for metadata filtering." \
  "Use Azure Cache for Redis with CLUSTER MODE DISABLED (Basic/Standard," \
  "or Premium with clustering off), same region as the firewall." \
  "Provision takes ~20 min: az redis create -g <rg> -n <name> -l $LOCATION --sku Standard --vm-size c1"
REDIS_ENABLED="$REPLY"
REDIS_HOST=""
REDIS_PORT="6380"
if [ "$REDIS_ENABLED" = "y" ]; then
  ask "redis_host" "Redis hostname" "$(existing redis_host)" \
    "For Azure Cache: <name>.redis.cache.windows.net"
  REDIS_HOST="$REPLY"
  ask "redis_port" "Redis port" "${REDIS_PORT}" \
    "Azure Cache serves TLS on 6380. The template connects with TLS by default."
  REDIS_PORT="${REPLY:-6380}"
fi

# ── write terraform.tfvars ───────────────────────────────────────────────────

if [ -f "$TFVARS" ]; then
  BACKUP="$TFVARS.bak.$(date +%Y%m%d%H%M%S)"
  cp "$TFVARS" "$BACKUP"
  echo ""
  dim "Existing $TFVARS backed up to $BACKUP"
fi

{
  echo "# Generated by setup.sh on $(date '+%Y-%m-%d %H:%M'). Safe to edit by hand."
  echo ""
  echo "location            = \"$LOCATION\""
  echo "resource_group_name = \"$RG\""
  echo "environment_name    = \"$ENV_NAME\""
  echo ""
  echo "firewall_image = \"$IMAGE\""
  echo ""
  echo "domain = \"$DOMAIN\""
  echo ""
  echo "vnet_id   = \"$VNET_ID\""
  echo "subnet_id = \"$SUBNET_ID\""
  echo ""
  echo "registries = {"
  for e in $ECOSYSTEMS; do
    printf '  %-16s = "%s"\n' "\"$e\"" "$(upstream_for "$e")"
  done
  echo "}"
  OVERRIDES=""
  for e in $ECOSYSTEMS; do
    o="$(override_for "$e")"
    [ -n "$o" ] && OVERRIDES="$OVERRIDES  \"$e\" = \"$o\"\n"
  done
  if [ -n "$OVERRIDES" ]; then
    echo ""
    echo "registry_overrides = {"
    printf '%b' "$OVERRIDES"
    echo "}"
  fi
  if [ "$TRANSPARENT" = "y" ]; then
    echo ""
    echo "# Transparent DNS interception: create internal DNS records for each"
    echo "# hostname below pointing at terraform output static_ip, and make sure"
    echo "# the certificate carries them as SANs."
    echo "registry_domains = {"
    transparent_entries | while read -r key host upstream override; do
      if [ "$override" = "-" ]; then
        printf '  %-16s = { domains = ["%s"], upstream = "%s" }\n' "\"$key\"" "$host" "$upstream"
      else
        printf '  %-16s = { domains = ["%s"], upstream = "%s", registry = "%s" }\n' "\"$key\"" "$host" "$upstream" "$override"
      fi
    done
    echo "}"
  fi
  echo ""
  echo "generate_self_signed_cert = $SELF_SIGNED_BOOL"
  if [ "$REDIS_ENABLED" = "y" ]; then
    echo ""
    echo "redis_enabled = true"
    echo "redis_host    = \"$REDIS_HOST\""
    echo "redis_port    = $REDIS_PORT"
  fi
} > "$TFVARS"

# ── next steps ───────────────────────────────────────────────────────────────

echo ""
bold "Wrote $TFVARS"
echo ""
bold "Before terraform apply, set the secrets in this shell (never in the file):"
echo ""
echo "  # Socket API token (scopes: packages, entitlements:list). read -rs keeps it out of history."
echo "  read -rs TF_VAR_socket_api_token && export TF_VAR_socket_api_token"
if [ "$REDIS_ENABLED" = "y" ]; then
  echo ""
  echo "  export TF_VAR_redis_password=\"\$(az redis list-keys -g $RG -n <cache-name> --query primaryKey -o tsv)\""
fi
if [ "$SELF_SIGNED_BOOL" = "false" ]; then
  echo ""
  echo "  # Full-chain PEM (leaf + intermediates) and the unencrypted private key:"
  echo "  export TF_VAR_ssl_cert=\"\$(cat /path/to/cert-chain.pem)\""
  echo "  export TF_VAR_ssl_key=\"\$(cat /path/to/private-key.pem)\""
fi
echo ""
bold "Then deploy:"
echo ""
echo "  terraform init"
echo "  terraform plan"
echo "  terraform apply    # 20-30 minutes; the Container Apps Environment is the slow part"
echo ""
dim "Re-run any time with these exports set again; the apply needs them every run."
dim "After config-only changes (registries, registry_domains), the firewall reads"
dim "its config at startup; roll the revision to pick changes up:"
dim "  az containerapp revision restart -n ca-$ENV_NAME -g $RG --revision <name>"
