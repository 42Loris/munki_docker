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

for var in MUNKI_DOMAIN MANAGE_DOMAIN ACME_EMAIL MUNKI_REPO_PATH WEBDAV_USER WEBDAV_PASS; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var is not set in .env"
        exit 1
    fi
done

if [ "${ENABLE_DDNS:-false}" = "true" ] && [ -z "${CF_API_TOKEN:-}" ]; then
    echo "ERROR: CF_API_TOKEN is required when ENABLE_DDNS=true"
    exit 1
fi

echo "Client domain: $MUNKI_DOMAIN"
echo "Manage domain: $MANAGE_DOMAIN"
echo "Repo path    : $MUNKI_REPO_PATH"
echo "WebDAV user  : $WEBDAV_USER"
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
if [ -f "$SCRIPT_DIR/certs/munki-client.pem" ]; then
    echo "Client cert already exists — skipping. Delete certs/munki-client.* to regenerate."
else
    bash "$SCRIPT_DIR/scripts/gen-client.sh"
fi
echo ""

# 6. Generate WebDAV password hash
echo "--- WebDAV credentials ---"
if [ -z "${WEBDAV_PASS_HASH:-}" ]; then
    echo "Generating bcrypt hash for WebDAV password..."
    WEBDAV_PASS_HASH=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$WEBDAV_PASS")
    # Escape $ signs so Docker Compose doesn't interpret them as variable references
    WEBDAV_PASS_HASH_ESCAPED="${WEBDAV_PASS_HASH//\$/\$\$}"
    if grep -q "^WEBDAV_PASS_HASH=" "$SCRIPT_DIR/.env"; then
        sed -i "s|^WEBDAV_PASS_HASH=.*|WEBDAV_PASS_HASH=$WEBDAV_PASS_HASH_ESCAPED|" "$SCRIPT_DIR/.env"
    else
        echo "WEBDAV_PASS_HASH=$WEBDAV_PASS_HASH_ESCAPED" >> "$SCRIPT_DIR/.env"
    fi
    echo "  Hash written to .env"
else
    echo "  Password hash already set — skipping."
fi
echo ""

# 7. Start containers
echo "--- Starting containers ---"
COMPOSE_PROFILES=""
if [ "${ENABLE_DDNS:-false}" = "true" ]; then
    COMPOSE_PROFILES="--profile ddns"
    echo "  DDNS enabled — starting cloudflare-ddns container"
fi
# shellcheck disable=SC2086
docker compose -f "$SCRIPT_DIR/docker-compose.yml" $COMPOSE_PROFILES up -d

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo ""
echo "  Mac clients (Intune — all managed Macs):"
echo "    1. Devices > macOS > Shell scripts > Add"
echo "       Upload certs/mdm_upload/munki-client-deploy.sh  (run as root)"
echo "    2. Devices > macOS > Configuration profiles > Create > Custom"
echo "       Upload certs/mdm_upload/munki-prefs.mobileconfig"
echo ""
echo "  Admin access:"
echo "    Finder > Go > Connect to Server > https://$MANAGE_DOMAIN"
echo "    Username: $WEBDAV_USER"
echo "    Password: $WEBDAV_PASS"
echo ""
echo "  GitHub Actions — add these secrets to your AutoPKG repo:"
echo "    MANAGE_DOMAIN  = $MANAGE_DOMAIN"
echo "    WEBDAV_USER    = $WEBDAV_USER"
echo "    WEBDAV_PASS    = $WEBDAV_PASS"
echo ""
echo "    curl usage:"
echo "      curl -u \"\$WEBDAV_USER:\$WEBDAV_PASS\" \\"
echo "           -T App.pkg \"https://\$MANAGE_DOMAIN/pkgs/apps/App.pkg\""
echo ""
echo "  Packages:"
echo "    Add packages via WebDAV mount and run makecatalogs"
echo ""
echo "Logs: docker compose logs -f"
