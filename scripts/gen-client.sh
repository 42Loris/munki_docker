#!/bin/bash
# Generates a shared client certificate signed by the local CA.
# Outputs: munki-client.p12 and munki-client.mobileconfig for Intune deployment.
set -euo pipefail

CERTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/certs"
CLIENT_NAME="munki-client"

if [ ! -f "$CERTS_DIR/ca.crt" ] || [ ! -f "$CERTS_DIR/ca.key" ]; then
    echo "ERROR: CA not found. Run scripts/gen-ca.sh first."
    exit 1
fi

echo "Generating client private key..."
openssl genrsa -out "$CERTS_DIR/$CLIENT_NAME.key" 2048

echo "Generating certificate signing request..."
openssl req -new \
    -key "$CERTS_DIR/$CLIENT_NAME.key" \
    -out "$CERTS_DIR/$CLIENT_NAME.csr" \
    -subj "/CN=Munki Mac Client/O=Internal"

echo "Signing client certificate with CA (10 year validity)..."
openssl x509 -req -days 3650 \
    -in "$CERTS_DIR/$CLIENT_NAME.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/$CLIENT_NAME.crt"

echo "Packaging as PKCS#12..."
openssl pkcs12 -export \
    -in "$CERTS_DIR/$CLIENT_NAME.crt" \
    -inkey "$CERTS_DIR/$CLIENT_NAME.key" \
    -out "$CERTS_DIR/$CLIENT_NAME.p12" \
    -passout pass:

rm "$CERTS_DIR/$CLIENT_NAME.csr"
chmod 600 "$CERTS_DIR/$CLIENT_NAME.key" "$CERTS_DIR/$CLIENT_NAME.p12"

echo "Generating Intune mobileconfig..."
P12_B64=$(base64 < "$CERTS_DIR/$CLIENT_NAME.p12")
PROFILE_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")
PAYLOAD_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")

cat > "$CERTS_DIR/$CLIENT_NAME.mobileconfig" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadCertificateFileName</key>
            <string>$CLIENT_NAME.p12</string>
            <key>PayloadContent</key>
            <data>$P12_B64</data>
            <key>PayloadDescription</key>
            <string>Munki client certificate for mTLS authentication</string>
            <key>PayloadDisplayName</key>
            <string>Munki Client Certificate</string>
            <key>PayloadIdentifier</key>
            <string>systems.zoppi.munki.client-cert</string>
            <key>PayloadType</key>
            <string>com.apple.security.pkcs12</string>
            <key>PayloadUUID</key>
            <string>$PAYLOAD_UUID</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>Password</key>
            <string></string>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Installs the Munki client certificate for mTLS authentication</string>
    <key>PayloadDisplayName</key>
    <string>Munki Client Certificate</string>
    <key>PayloadIdentifier</key>
    <string>systems.zoppi.munki.profile</string>
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
echo "Client cert generated:"
echo "  PKCS#12      : $CERTS_DIR/$CLIENT_NAME.p12"
echo "  Intune profile: $CERTS_DIR/$CLIENT_NAME.mobileconfig"
echo ""
echo "Upload $CLIENT_NAME.mobileconfig to Intune as a custom macOS configuration profile."
