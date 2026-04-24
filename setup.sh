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

for var in MUNKI_DOMAIN ACME_EMAIL MUNKI_REPO_PATH CF_API_TOKEN SAMBA_USER SAMBA_PASS; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var is not set in .env"
        exit 1
    fi
done

echo "Domain       : $MUNKI_DOMAIN"
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

# 5. Generate client cert + mobileconfig
echo "--- Client Certificate ---"
if [ -f "$SCRIPT_DIR/certs/munki-client.mobileconfig" ]; then
    echo "Client cert already exists — skipping. Run scripts/gen-client.sh to regenerate."
else
    bash "$SCRIPT_DIR/scripts/gen-client.sh"
fi
echo ""

# 6. Start containers
echo "--- Starting containers ---"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Upload certs/munki-client.mobileconfig to Intune as a custom macOS profile"
echo "     (contains client cert + SoftwareRepoURL — one upload, done)"
echo "  2. Add packages to $MUNKI_REPO_PATH/pkgs/ and run makecatalogs"
echo ""
echo "Logs: docker compose logs -f"
