#!/bin/bash
# Generates a GitHub Actions client certificate for WebDAV access.
# Outputs:
#   certs/github-actions.crt   — certificate
#   certs/github-actions.key   — private key
# Prints base64-encoded values for use as GitHub secrets.
set -euo pipefail

CERTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/certs"
ACTIONS_NAME="github-actions"

if [ ! -f "$CERTS_DIR/ca.crt" ] || [ ! -f "$CERTS_DIR/ca.key" ]; then
    echo "ERROR: CA not found. Run scripts/gen-ca.sh first."
    exit 1
fi

if [ -f "$CERTS_DIR/$ACTIONS_NAME.crt" ]; then
    echo "GitHub Actions cert already exists at $CERTS_DIR/$ACTIONS_NAME.crt — skipping."
    echo "Delete certs/github-actions.* to regenerate."
    exit 0
fi

echo "Generating GitHub Actions client private key..."
openssl genrsa -out "$CERTS_DIR/$ACTIONS_NAME.key" 2048

echo "Generating certificate signing request..."
openssl req -new \
    -key "$CERTS_DIR/$ACTIONS_NAME.key" \
    -out "$CERTS_DIR/$ACTIONS_NAME.csr" \
    -subj "/CN=github-actions/O=Internal"

echo "Signing GitHub Actions certificate with CA (10 year validity)..."
openssl x509 -req -days 3650 \
    -in "$CERTS_DIR/$ACTIONS_NAME.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/$ACTIONS_NAME.crt"

rm "$CERTS_DIR/$ACTIONS_NAME.csr"
chmod 600 "$CERTS_DIR/$ACTIONS_NAME.key"

CERT_B64=$(base64 < "$CERTS_DIR/$ACTIONS_NAME.crt")
KEY_B64=$(base64 < "$CERTS_DIR/$ACTIONS_NAME.key")

echo ""
echo "GitHub Actions cert generated:"
echo "  Certificate : $CERTS_DIR/$ACTIONS_NAME.crt"
echo "  Private key : $CERTS_DIR/$ACTIONS_NAME.key"
echo ""
echo "Add these as GitHub repository secrets:"
echo "  Settings > Secrets and variables > Actions > New repository secret"
echo ""
echo "Secret name : MUNKI_CLIENT_CERT"
echo "Secret value:"
echo "$CERT_B64"
echo ""
echo "Secret name : MUNKI_CLIENT_KEY"
echo "Secret value:"
echo "$KEY_B64"
echo ""
echo "Usage in GitHub Actions workflow:"
echo '  - name: Upload to Munki repo'
echo '    env:'
echo '      MUNKI_CLIENT_CERT: ${{ secrets.MUNKI_CLIENT_CERT }}'
echo '      MUNKI_CLIENT_KEY: ${{ secrets.MUNKI_CLIENT_KEY }}'
echo '      MANAGE_DOMAIN: ${{ secrets.MANAGE_DOMAIN }}'
echo '    run: |'
echo '      echo "$MUNKI_CLIENT_CERT" | base64 --decode > /tmp/munki.crt'
echo '      echo "$MUNKI_CLIENT_KEY"  | base64 --decode > /tmp/munki.key'
echo '      curl --cert /tmp/munki.crt --key /tmp/munki.key \'
echo '           -T App.pkg "https://$MANAGE_DOMAIN/pkgs/apps/App.pkg"'
echo '      rm /tmp/munki.crt /tmp/munki.key'
