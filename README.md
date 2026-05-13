# Munki Docker Container

A self-hosted [Munki](https://github.com/munki/munki) server running on Docker. Serves the munki repo over HTTPS with mTLS client certificate authentication. Provides a WebDAV management endpoint for admin access and GitHub Actions automation.

**Stack:** Caddy (TLS termination + mTLS) — Apache httpd (WebDAV, write access) — no certbot sidecar needed.

## How it works

Munki is a macOS software management system. The server is a plain static file server. Mac clients (`munkitools`) fetch manifests and packages from it over HTTPS.

Authentication is handled via mTLS: the server only accepts connections from clients that present a valid certificate signed by the local CA.

```
Mac clients (munkitools)
  ├── presents munki-client cert (deployed via Intune shell script)
  └── fetches from https://MUNKI_DOMAIN/  →  Caddy (mTLS, read-only)

Admin Mac (MunkiAdmin / Finder / munkiimport)
  ├── presents munki-admin cert (deployed via Intune config profile → keychain)
  └── mounts https://MANAGE_DOMAIN/  →  Caddy (mTLS)  →  Apache httpd (WebDAV, read-write)

GitHub Actions (AutoPKG)
  ├── presents github-actions cert (stored as GitHub secrets)
  └── uploads via curl to https://MANAGE_DOMAIN/  →  Caddy (mTLS)  →  Apache httpd (WebDAV, read-write)
```

## Prerequisites

- Docker with the Compose plugin
- A domain managed by Cloudflare (see [DNS & DDNS setup](#dns--ddns-setup) below)
- Two DNS records: one for `MUNKI_DOMAIN`, one for `MANAGE_DOMAIN`
- Port **443** reachable on the server
- Port **80** reachable on the server (for HTTP → HTTPS redirects)
- `openssl` and `python3` installed on the server
- Intune for deploying certificates to Macs

> If the server is behind a NAT/router, forward ports 80 and 443 to it.

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/42Loris/munki_docker_container
cd munki_docker_container
cp env.example .env
nano .env
```

Fill in `.env`:

```
MUNKI_DOMAIN=munki.example.com
MANAGE_DOMAIN=munkimanage.example.com
ACME_EMAIL=admin@example.com
MUNKI_REPO_PATH=/srv/munki/repo
CF_API_TOKEN=your_cloudflare_api_token
MUNKI_CLIENT_IDENTIFIER=   # optional — leave empty to use machine serial number
```

### 2. Run setup

```bash
bash setup.sh
```

This will:
- Create the munki repo directory structure at `MUNKI_REPO_PATH`
- Generate a self-signed CA (`certs/ca.crt`, `certs/ca.key`)
- Generate the munki client cert + Intune shell script + Munki preferences profile
- Generate the admin client cert + Intune shell script (imports into System keychain)
- Generate the GitHub Actions cert + print base64 values for GitHub secrets
- Start the Caddy, Apache httpd, and DDNS containers

All files needed for Intune are copied to `certs/mdm_upload/` automatically — one place for everything you need to upload to your MDM.

### 3. Deploy certificates via Intune

All uploads come from `certs/mdm_upload/`:

| File | Intune section | Scope |
|---|---|---|
| `munki-client-deploy.sh` | Devices > macOS > Shell scripts (run as root) | All managed Macs |
| `munki-prefs.mobileconfig` | Devices > macOS > Configuration profiles > Custom | All managed Macs |
| `munki-admin-deploy.sh` | Devices > macOS > Shell scripts (run as root) | Admins group only |

#### Mac clients — all managed Macs

**Upload 1 — Shell script (deploys cert file):**

1. Intune → **Devices > macOS > Shell scripts > Add**
2. Upload `certs/mdm_upload/munki-client-deploy.sh`
3. Run script as signed-in user: **No** (runs as root)
4. Assign to your Mac device group

**Upload 2 — Configuration profile (sets Munki preferences):**

1. Intune → **Devices > macOS > Configuration profiles > Create profile**
2. Platform: **macOS**, Profile type: **Templates > Custom**
3. Upload `certs/mdm_upload/munki-prefs.mobileconfig`
4. Assign to your Mac device group

#### Admin Macs — Admins group only

**Upload 3 — Shell script (imports admin cert into System keychain):**

1. Intune → **Devices > macOS > Shell scripts > Add**
2. Upload `certs/mdm_upload/munki-admin-deploy.sh`
3. Run script as signed-in user: **No** (runs as root)
4. **Scope to your Admins device/user group only** — do not assign to all Macs

macOS imports the cert into the System keychain. Finder and MunkiAdmin present it automatically for mTLS — no password prompt.

> **Manual alternative:** Double-click `certs/munki-admin.p12` and enter the password printed by `gen-admin.sh` to install it into your keychain.

### 4. Connect as admin

**Finder (for munkiimport):**

1. Finder → Go → Connect to Server (⌘K)
2. Enter `https://MANAGE_DOMAIN`
3. macOS presents the admin cert from keychain automatically
4. The repo mounts as a volume — use this path with `munkiimport` and `makecatalogs`

**MunkiAdmin:**

Point MunkiAdmin directly at `https://MANAGE_DOMAIN` as the repo URL.

### 5. GitHub Actions — set secrets

From the output of `setup.sh` (or re-run `scripts/gen-actions.sh`), add to your AutoPKG repo:

- **`MUNKI_CLIENT_CERT`** — base64-encoded certificate
- **`MUNKI_CLIENT_KEY`** — base64-encoded private key
- **`MANAGE_DOMAIN`** — your management domain

In your workflow:

```yaml
- name: Upload to Munki repo
  env:
    MUNKI_CLIENT_CERT: ${{ secrets.MUNKI_CLIENT_CERT }}
    MUNKI_CLIENT_KEY: ${{ secrets.MUNKI_CLIENT_KEY }}
    MANAGE_DOMAIN: ${{ secrets.MANAGE_DOMAIN }}
  run: |
    echo "$MUNKI_CLIENT_CERT" | base64 --decode > /tmp/munki.crt
    echo "$MUNKI_CLIENT_KEY"  | base64 --decode > /tmp/munki.key
    curl --cert /tmp/munki.crt --key /tmp/munki.key \
         -T App.pkg "https://$MANAGE_DOMAIN/pkgs/apps/App.pkg"
    rm /tmp/munki.crt /tmp/munki.key
```

## Repo structure

```
/srv/munki/repo/         ← MUNKI_REPO_PATH
├── catalogs/            ← auto-generated by makecatalogs, do not edit manually
├── icons/               ← optional app icons (.png)
├── manifests/           ← per-machine or group manifests
├── pkgs/                ← packages (.pkg, .dmg, .mpkg)
└── pkgsinfo/            ← package metadata (plist files, generated by munkiimport)
```

## Adding packages

With the WebDAV share mounted on your admin Mac (e.g. at `/Volumes/MANAGE_DOMAIN`):

```bash
# Import a package
munkiimport /path/to/App.pkg --subdirectory apps

# Regenerate catalogs (must run after every import)
makecatalogs /Volumes/MANAGE_DOMAIN
```

Or use **MunkiAdmin** — point it at `https://MANAGE_DOMAIN` and manage everything via the GUI.

Or run `makecatalogs` directly on the server via Docker:

```bash
docker run --rm \
  -v /srv/munki/repo:/repo \
  ghcr.io/munki/munki:latest \
  makecatalogs /repo
```

## Certificate management

### Regenerate client certificate (Mac clients)

```bash
rm certs/munki-client.*
bash scripts/gen-client.sh
```

Re-upload `certs/munki-client-deploy.sh` and `certs/munki-prefs.mobileconfig` to Intune.

### Regenerate admin certificate

```bash
rm certs/munki-admin.*
bash scripts/gen-admin.sh
```

Re-upload `certs/mdm_upload/munki-admin-deploy.sh` to Intune. Macs will receive the new cert on the next shell script run.

### Regenerate GitHub Actions certificate

```bash
rm certs/github-actions.*
bash scripts/gen-actions.sh
```

Update `MUNKI_CLIENT_CERT` and `MUNKI_CLIENT_KEY` in your GitHub repo secrets.

### Regenerate everything (CA + all certs)

```bash
rm -rf certs/
bash setup.sh
```

This invalidates all existing certs. Re-deploy all Intune profiles and update GitHub secrets.

## DNS & DDNS setup

The server uses Cloudflare for DNS management and automatic DDNS. Your domain can remain registered at any registrar — you only delegate DNS to Cloudflare.

### One-time Cloudflare setup

1. Create a free account at [cloudflare.com](https://cloudflare.com)
2. Add your domain as a site — Cloudflare will scan existing DNS records
3. Cloudflare gives you two nameservers — update them at your registrar
4. Create two A records pointing to your server's public IP:
   - `munki` → your server's public IP
   - `munkimanage` → your server's public IP (or whatever subdomains you chose)
   - Set both to **DNS only (gray cloud)** — do NOT enable proxy (orange cloud), it breaks mTLS

### Cloudflare API token

The DDNS container updates both A records automatically when your public IP changes.

1. In Cloudflare: **My Profile → API Tokens → Create Token**
2. Use the **Edit zone DNS** template
3. Scope it to your zone only
4. Copy the token into `.env` as `CF_API_TOKEN`

## Security notes

- `certs/ca.key` never leaves the server. It is gitignored.
- `certs/munki-admin.p12` and `certs/munki-admin.mobileconfig` contain the admin private key — treat them as secrets. Both are gitignored.
- `certs/github-actions.key` contains the Actions private key — gitignored. Store the base64 value only in GitHub secrets.
- The shared munki client cert means all Macs use the same key pair. If a Mac is compromised, regenerate and redeploy. Per-device certs via Intune SCEP are a future option.
- The admin cert should be scoped to Admins in Intune — it grants write access to the entire repo.
- Caddy rejects any request without a valid client certificate — unauthenticated access returns a TLS error before any HTTP response, on both domains.
