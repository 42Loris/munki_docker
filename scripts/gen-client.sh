#!/bin/bash
# Generates a shared client certificate signed by the local CA.
# Outputs:
#   munki-client.pem         — cert+key PEM (stays on server, never distribute directly)
#   munki-client-deploy.sh   — Intune shell script: deploys PEM to each Mac as root
#   munki-prefs.mobileconfig — Munki preference profile (SoftwareRepoURL + cert path)
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

echo "Creating PEM (cert + key) for Munki..."
cat "$CERTS_DIR/$CLIENT_NAME.crt" "$CERTS_DIR/$CLIENT_NAME.key" > "$CERTS_DIR/$CLIENT_NAME.pem"
chmod 600 "$CERTS_DIR/$CLIENT_NAME.pem"

echo "Generating Intune deployment script..."
PEM_B64=$(base64 < "$CERTS_DIR/$CLIENT_NAME.pem")

cat > "$CERTS_DIR/$CLIENT_NAME-deploy.sh" <<DEPLOY
#!/bin/bash
# Intune shell script: deploys Munki client certificate to each Mac.
# Upload to Intune as a macOS shell script, run as: root
set -euo pipefail

CERT_DIR="/Library/Managed Installs/certs"
mkdir -p "\$CERT_DIR"

base64 --decode > "\$CERT_DIR/munki_client.pem" <<'PEMEOF'
$PEM_B64
PEMEOF

chmod 600 "\$CERT_DIR/munki_client.pem"
chown root:wheel "\$CERT_DIR/munki_client.pem"

echo "Munki client cert deployed to \$CERT_DIR/munki_client.pem"
DEPLOY

echo "Generating Munki preferences mobileconfig..."
PROFILE_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")
PAYLOAD_UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()).upper())")
MUNKI_DOMAIN="${MUNKI_DOMAIN:-munki.example.com}"

# Build optional ClientIdentifier XML snippet
CLIENT_IDENTIFIER_XML=""
if [ -n "${MUNKI_CLIENT_IDENTIFIER:-}" ]; then
    CLIENT_IDENTIFIER_XML="
                                <key>ClientIdentifier</key>
                                <string>${MUNKI_CLIENT_IDENTIFIER}</string>"
fi

cat > "$CERTS_DIR/munki-prefs.mobileconfig" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.ManagedClient.preferences</string>
            <key>PayloadUUID</key>
            <string>$PAYLOAD_UUID</string>
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
                                <string>https://$MUNKI_DOMAIN</string>
                                <key>UseClientCertificate</key>
                                <true/>
                                <key>ClientCertificatePath</key>
                                <string>/Library/Managed Installs/certs/munki_client.pem</string>$CLIENT_IDENTIFIER_XML
                            </dict>
                        </dict>
                    </array>
                </dict>
            </dict>
        </dict>
    </array>
    <key>PayloadDescription</key>
    <string>Munki repository URL and client certificate configuration</string>
    <key>PayloadDisplayName</key>
    <string>Munki Preferences</string>
    <key>PayloadIdentifier</key>
    <string>systems.zoppi.munki.prefs.profile</string>
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

mkdir -p "$CERTS_DIR/intune_upload"
cp "$CERTS_DIR/$CLIENT_NAME-deploy.sh" "$CERTS_DIR/intune_upload/$CLIENT_NAME-deploy.sh"
cp "$CERTS_DIR/munki-prefs.mobileconfig" "$CERTS_DIR/intune_upload/munki-prefs.mobileconfig"

echo ""
echo "Client cert generated:"
echo "  Deploy script  : $CERTS_DIR/$CLIENT_NAME-deploy.sh"
echo "  Munki prefs    : $CERTS_DIR/munki-prefs.mobileconfig"
echo ""
echo "Intune deployment (two uploads):"
echo "  1. Devices > macOS > Shell scripts > Add"
echo "     Upload: intune_upload/$CLIENT_NAME-deploy.sh  (run as root)"
echo "  2. Devices > macOS > Configuration profiles > Create > Custom"
echo "     Upload: intune_upload/munki-prefs.mobileconfig"
