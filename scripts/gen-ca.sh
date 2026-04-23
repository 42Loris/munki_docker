#!/bin/bash
set -euo pipefail

CERTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/certs"
mkdir -p "$CERTS_DIR"

if [ -f "$CERTS_DIR/ca.crt" ]; then
    echo "CA already exists at $CERTS_DIR/ca.crt — skipping. Delete certs/ to regenerate."
    exit 0
fi

echo "Generating CA private key..."
openssl genrsa -out "$CERTS_DIR/ca.key" 4096

echo "Generating CA certificate (10 year validity)..."
openssl req -new -x509 -days 3650 \
    -key "$CERTS_DIR/ca.key" \
    -out "$CERTS_DIR/ca.crt" \
    -subj "/CN=Munki Client CA/O=Internal"

chmod 600 "$CERTS_DIR/ca.key"

echo ""
echo "CA generated:"
echo "  Certificate : $CERTS_DIR/ca.crt  (used by Caddy)"
echo "  Private key : $CERTS_DIR/ca.key  (keep secret — never share)"
