#!/bin/bash
# Generates an admin client certificate for WebDAV access.
# Outputs:
#   certs/munki-admin.p12        — cert+key bundle for manual keychain install
#   certs/munki-admin.mobileconfig — Intune config profile: installs cert into keychain
set -euo pipefail

CERTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/certs"
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

# Generate random p12 export password
P12_PASS=$(openssl rand -base64 24)

echo "Exporting .p12 bundle..."
openssl pkcs12 -export \
    -in "$CERTS_DIR/$ADMIN_NAME.crt" \
    -inkey "$CERTS_DIR/$ADMIN_NAME.key" \
    -certfile "$CERTS_DIR/ca.crt" \
    -out "$CERTS_DIR/$ADMIN_NAME.p12" \
    -passout "pass:$P12_PASS"

chmod 600 "$CERTS_DIR/$ADMIN_NAME.p12"

echo "Generating Intune mobileconfig..."
PROFILE_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")
PAYLOAD_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")
P12_B64=$(base64 < "$CERTS_DIR/$ADMIN_NAME.p12")

cat > "$CERTS_DIR/$ADMIN_NAME.mobileconfig" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.security.pkcs12</string>
            <key>PayloadUUID</key>
            <string>$PAYLOAD_UUID</string>
            <key>PayloadIdentifier</key>
            <string>systems.zoppi.munki.admin-cert</string>
            <key>PayloadDisplayName</key>
            <string>Munki Admin Certificate</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>Password</key>
            <string>$P12_PASS</string>
            <key>PayloadContent</key>
            <data>
$P12_B64
            </data>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Installs the Munki admin client certificate for WebDAV access.</string>
    <key>PayloadDisplayName</key>
    <string>Munki Admin Certificate</string>
    <key>PayloadIdentifier</key>
    <string>systems.zoppi.munki.admin-cert.profile</string>
    <key>PayloadOrganization</key>
    <string>Internal</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>$PROFILE_UUID</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

echo ""
echo "Admin cert generated:"
echo "  .p12             : $CERTS_DIR/$ADMIN_NAME.p12"
echo "  mobileconfig     : $CERTS_DIR/$ADMIN_NAME.mobileconfig"
echo "  .p12 password    : $P12_PASS  (embedded in mobileconfig — keep both files secret)"
echo ""
echo "Intune deployment (scope to Admins group only):"
echo "  Devices > macOS > Configuration profiles > Create profile"
echo "  Platform: macOS — Profile type: Templates > Custom"
echo "  Upload: $ADMIN_NAME.mobileconfig"
echo ""
echo "  macOS will install the cert into the Login keychain."
echo "  Finder and MunkiAdmin will present it automatically for mTLS."
echo ""
echo "Manual install (alternative to Intune):"
echo "  Double-click $ADMIN_NAME.p12 and enter the password above."
