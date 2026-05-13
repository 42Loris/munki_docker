#!/bin/bash
# Generates an admin client certificate for WebDAV access.
# Outputs:
#   certs/munki-admin.p12                    — cert+key bundle (for manual install if needed)
#   certs/mdm_upload/munki-admin-deploy.sh   — MDM shell script: imports cert into System keychain
set -euo pipefail

CERTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/certs"
MDM_DIR="$CERTS_DIR/mdm_upload"
ADMIN_NAME="munki-admin"

if [ ! -f "$CERTS_DIR/ca.crt" ] || [ ! -f "$CERTS_DIR/ca.key" ]; then
    echo "ERROR: CA not found. Run scripts/gen-ca.sh first."
    exit 1
fi

if [ -f "$CERTS_DIR/$ADMIN_NAME.p12" ]; then
    echo "Admin cert already exists at $CERTS_DIR/$ADMIN_NAME.p12 — skipping."
    echo "Delete certs/munki-admin.* to regenerate."
    exit 0
fi

echo "Generating admin client private key..."
openssl genrsa -out "$CERTS_DIR/$ADMIN_NAME.key" 2048

echo "Generating certificate signing request..."
openssl req -new \
    -key "$CERTS_DIR/$ADMIN_NAME.key" \
    -out "$CERTS_DIR/$ADMIN_NAME.csr" \
    -subj "/CN=munki-admin/O=Internal"

echo "Signing admin certificate with CA (10 year validity)..."
openssl x509 -req -days 3650 \
    -in "$CERTS_DIR/$ADMIN_NAME.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/$ADMIN_NAME.crt"

rm "$CERTS_DIR/$ADMIN_NAME.csr"
chmod 600 "$CERTS_DIR/$ADMIN_NAME.key"

P12_PASS=$(openssl rand -base64 24)

echo "Exporting .p12 bundle..."
openssl pkcs12 -export \
    -in "$CERTS_DIR/$ADMIN_NAME.crt" \
    -inkey "$CERTS_DIR/$ADMIN_NAME.key" \
    -certfile "$CERTS_DIR/ca.crt" \
    -out "$CERTS_DIR/$ADMIN_NAME.p12" \
    -passout "pass:$P12_PASS" \
    -legacy

chmod 600 "$CERTS_DIR/$ADMIN_NAME.p12"

echo "Generating MDM deploy script..."
P12_B64=$(base64 < "$CERTS_DIR/$ADMIN_NAME.p12")

mkdir -p "$MDM_DIR"

cat > "$MDM_DIR/$ADMIN_NAME-deploy.sh" <<DEPLOY
#!/bin/bash
# MDM shell script: imports Munki admin certificate into System keychain.
# Upload to your MDM as a macOS shell script, run as: root
# Scope to Admins group only.
set -euo pipefail

P12_PASS="$P12_PASS"

P12_TMP=\$(mktemp /tmp/munki-admin.XXXXXX)

base64 --decode > "\$P12_TMP" <<'PKCS12EOF'
$P12_B64
PKCS12EOF

security import "\$P12_TMP" \\
    -k /Library/Keychains/System.keychain \\
    -P "\$P12_PASS" \\
    -T /System/Library/CoreServices/Finder.app \\
    -T /usr/bin/curl \\
    -A

rm "\$P12_TMP"
echo "Munki admin cert imported into System keychain."
DEPLOY

chmod 600 "$MDM_DIR/$ADMIN_NAME-deploy.sh"

echo ""
echo "Admin cert generated:"
echo "  .p12          : $CERTS_DIR/$ADMIN_NAME.p12"
echo "  .p12 password : $P12_PASS  (embedded in deploy script — keep files secret)"
echo "  deploy script : $MDM_DIR/$ADMIN_NAME-deploy.sh"
echo ""
echo "MDM deployment (scope to Admins group only):"
echo "  Devices > macOS > Shell scripts > Add"
echo "  Upload: certs/mdm_upload/$ADMIN_NAME-deploy.sh  (run as root)"
echo ""
echo "  macOS imports the cert into the System keychain."
echo "  Finder and MunkiAdmin will present it automatically for mTLS."
echo ""
echo "Manual install (alternative):"
echo "  Double-click $ADMIN_NAME.p12 and enter the password above."
