#!/bin/bash
# One-shot setup: creates the repo structure, generates certs, and starts the container.
# Safe to re-run — skips steps that are already done.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Munki Docker Setup ==="
echo ""

# 1. Validate .env
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "No .env file found."
    echo "Copy env.example to .env and fill in the values, then re-run this script."
    echo ""
    echo "  cp env.example .env && nano .env"
    exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/.env"

for var in MUNKI_DOMAIN MANAGE_DOMAIN ACME_EMAIL MUNKI_REPO_PATH CF_API_TOKEN; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var is not set in .env"
        exit 1
    fi
done

echo "Client domain: $MUNKI_DOMAIN"
echo "Manage domain: $MANAGE_DOMAIN"
echo "Repo path    : $MUNKI_REPO_PATH"
echo ""

# 2. Check prerequisites
for cmd in docker openssl python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is required but not installed."
        exit 1
    fi
done

if ! docker compose version &>/dev/null; then
    echo "ERROR: docker compose plugin is required."
    exit 1
fi

# 3. Create munki repo directory structure
echo "Creating repo directories..."
mkdir -p \
    "$MUNKI_REPO_PATH/catalogs" \
    "$MUNKI_REPO_PATH/icons" \
    "$MUNKI_REPO_PATH/manifests" \
    "$MUNKI_REPO_PATH/pkgs" \
    "$MUNKI_REPO_PATH/pkgsinfo"
chmod -R 777 "$MUNKI_REPO_PATH"
echo "  $MUNKI_REPO_PATH/{catalogs,icons,manifests,pkgs,pkgsinfo}"
echo ""

# 4. Generate CA
echo "--- Certificate Authority ---"
bash "$SCRIPT_DIR/scripts/gen-ca.sh"
echo ""

# 5. Generate client cert + mobileconfig (Mac clients)
echo "--- Client Certificate (Mac clients) ---"
if [ -f "$SCRIPT_DIR/certs/munki-client-deploy.sh" ]; then
    echo "Client cert already exists — skipping. Run scripts/gen-client.sh to regenerate."
else
    bash "$SCRIPT_DIR/scripts/gen-client.sh"
fi
echo ""

# 6. Generate admin cert (WebDAV admin access)
echo "--- Admin Certificate (WebDAV) ---"
bash "$SCRIPT_DIR/scripts/gen-admin.sh"
echo ""

# 7. Generate GitHub Actions cert
echo "--- GitHub Actions Certificate ---"
bash "$SCRIPT_DIR/scripts/gen-actions.sh"
echo ""

# 8. Start containers
echo "--- Starting containers ---"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo ""
echo "  Mac clients (Intune — all managed Macs):"
echo "    1. Devices > macOS > Shell scripts > Add"
echo "       Upload certs/munki-client-deploy.sh  (run as root)"
echo "    2. Devices > macOS > Configuration profiles > Create > Custom"
echo "       Upload certs/munki-prefs.mobileconfig"
echo ""
echo "  Admin access (Intune — Admins group only):"
echo "    3. Devices > macOS > Configuration profiles > Create > Custom"
echo "       Upload certs/munki-admin.mobileconfig"
echo "       Scope to Admins device/user group"
echo "    Then: Finder > Go > Connect to Server > https://$MANAGE_DOMAIN"
echo ""
echo "  GitHub Actions:"
echo "    4. Add MUNKI_CLIENT_CERT and MUNKI_CLIENT_KEY secrets to your AutoPKG repo"
echo "       (values printed above by gen-actions.sh)"
echo "       Also add MANAGE_DOMAIN=$MANAGE_DOMAIN as a secret"
echo ""
echo "  Packages:"
echo "    5. Add packages via WebDAV mount and run makecatalogs"
echo ""
echo "Logs: docker compose logs -f"
