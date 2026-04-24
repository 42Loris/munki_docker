#!/bin/bash
# Generates a shared client certificate signed by the local CA.
# Outputs:
#   munki-client.mobileconfig — Intune profile: installs cert into System keychain
#                               + sets SoftwareRepoURL (and optional ClientIdentifier)
set -euo pipefail

CERTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/certs"
CLIENT_NAME="munki-client"

if [ ! -f "$CERTS_DIR/ca.crt" ] || [ ! -f "$CERTS_DIR/ca.key" ]; then
    echo "ERROR: CA not found. Run scripts/gen-ca.sh first."
    exit 1
fi

if [ -z "${MUNKI_DOMAIN:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    if [ -f "$SCRIPT_DIR/.env" ]; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/.env"
    fi
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

rm "$CERTS_DIR/$CLIENT_NAME.csr"
chmod 600 "$CERTS_DIR/$CLIENT_NAME.key"

echo "Packaging as PKCS#12..."
P12_PASS=$(openssl rand -hex 16)
openssl pkcs12 -export \
    -inkey "$CERTS_DIR/$CLIENT_NAME.key" \
    -in "$CERTS_DIR/$CLIENT_NAME.crt" \
    -certfile "$CERTS_DIR/ca.crt" \
    -passout "pass:$P12_PASS" \
    -out "$CERTS_DIR/$CLIENT_NAME.p12"
chmod 600 "$CERTS_DIR/$CLIENT_NAME.p12"

P12_B64=$(base64 < "$CERTS_DIR/$CLIENT_NAME.p12")

echo "Generating combined mobileconfig (cert + Munki preferences)..."
PROFILE_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")
CERT_PAYLOAD_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")
PREFS_PAYLOAD_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")
MUNKI_DOMAIN="${MUNKI_DOMAIN:-munki.example.com}"

# Build optional ClientIdentifier XML snippet
CLIENT_IDENTIFIER_XML=""
if [ -n "${MUNKI_CLIENT_IDENTIFIER:-}" ]; then
    CLIENT_IDENTIFIER_XML="
                                <key>ClientIdentifier</key>
                                <string>${MUNKI_CLIENT_IDENTIFIER}</string>"
fi

cat > "$CERTS_DIR/$CLIENT_NAME.mobileconfig" <<EOF
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
            <string>$CERT_PAYLOAD_UUID</string>
            <key>PayloadIdentifier</key>
            <string>systems.zoppi.munki.client-cert</string>
            <key>PayloadDisplayName</key>
            <string>Munki Client Certificate</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadEnabled</key>
            <true/>
            <key>PayloadContent</key>
            <data>
$P12_B64
            </data>
            <key>Password</key>
            <string>$P12_PASS</string>
        </dict>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.ManagedClient.preferences</string>
            <key>PayloadUUID</key>
            <string>$PREFS_PAYLOAD_UUID</string>
            <key>PayloadIdentifier</key>
            <string>systems.zoppi.munki.prefs</string>
            <key>PayloadDisplayName</key>
            <string>Munki Preferences</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadEnabled</key>
            <true/>
            <key>PayloadContent</key>
            <dict>
                <key>ManagedInstalls</key>
                <dict>
                    <key>Forced</key>
                    <array>
                        <dict>
                            <key>mcx_preference_settings</key>
                            <dict>
                                <key>SoftwareRepoURL</key>
                                <string>https://$MUNKI_DOMAIN</string>$CLIENT_IDENTIFIER_XML
                            </dict>
                        </dict>
                    </array>
                </dict>
            </dict>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Munki client certificate and repository configuration</string>
    <key>PayloadDisplayName</key>
    <string>Munki</string>
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
echo "  Mobileconfig   : $CERTS_DIR/$CLIENT_NAME.mobileconfig"
echo ""
echo "Intune deployment:"
echo "  1. In Intune: Devices > macOS > Configuration profiles > Create profile"
echo "  2. Platform: macOS, Profile type: Templates > Custom"
echo "  3. Upload $CLIENT_NAME.mobileconfig"
echo "  4. Assign to your Mac device group"
