#!/usr/bin/env bash
set -euo pipefail

# Load .env if present (for CERTS_DIR / DEV_DOMAINS)
if [ -f .env ]; then
  set -a; . ./.env; set +a
fi

# Put certs inside the treafik folder so all paths line up with compose
CERTS_DIR="${CERTS_DIR:-./traefik/certs}"
mkdir -p "$CERTS_DIR" ./traefik/certs

# Default domains: wildcard for nip.io plus explicit service hostnames
DOMAINS_DEFAULT="localhost 127.0.0.1 ::1 *.127.0.0.1.nip.io traefik.127.0.0.1.nip.io archon.127.0.0.1.nip.io archon-api.127.0.0.1.nip.io supabase.127.0.0.1.nip.io studio.127.0.0.1.nip.io llm.127.0.0.1.nip.io cipher.127.0.0.1.nip.io code.127.0.0.1.nip.io"
# Allow override via DEV_DOMAINS in .env (space-separated)
read -r -a DOMAINS <<< "${DEV_DOMAINS:-$DOMAINS_DEFAULT}"

if ! command -v mkcert >/dev/null 2>&1; then
  echo "mkcert not found. Please install it first."
  echo "macOS: brew install mkcert nss"
  echo "Ubuntu: sudo apt-get install -y libnss3-tools && (curl -JLO https://dl.filippo.io/mkcert/latest?for=linux/amd64 && chmod +x mkcert-v*-linux-amd64 && sudo mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert)"
  exit 1
fi

# Ensure local root CA is installed (prompts for sudo on macOS)
mkcert -install

# Generate a single cert covering all dev domains
mkcert -cert-file "$CERTS_DIR/local-cert.pem" \
       -key-file  "$CERTS_DIR/local-key.pem" \
       "${DOMAINS[@]}"

# Export mkcert root CA so containers can trust our proxy
cp "$(mkcert -CAROOT)/rootCA.pem" "$CERTS_DIR/rootCA.pem"

# Dynamic TLS file for Traefik
cat > /traefik/certs.yaml <<'YAML'
tls:
  certificates:
    - certFile: /etc/traefik/certs/local-cert.pem
      keyFile:  /etc/traefik/certs/local-key.pem
YAML

# --- NEW: generate a CA env file for containers that use Python/Requests/HTTPX/Node ---
# Inside Debian/Ubuntu/Alpine images we will place mkcert's root into the system store
# and then point Python & Node to the merged bundle explicitly.
#
# NOTE: Your Archon container already runs update-ca-certificates at startup (per logs).
# The only missing step is telling Python to use the system bundle, not Certifi's.
#
# This env file can be added to services via `env_file:` in docker compose.
CA_ENV_FILE="traefik/env.d/ca.env"
cat > "$CA_ENV_FILE" <<'ENV'
# Make Python/Requests/HTTPX use the system bundle (which includes mkcert root after update-ca-certificates)
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# If any Node services need to call through Traefik, this helps them trust mkcert too
NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
ENV

echo "✅ Certs ready at $CERTS_DIR"
echo "✅ Traefik TLS file written to traefik/certs.yaml"
echo "✅ Container CA env written to $CA_ENV_FILE"
echo
echo "Next steps:"
echo "1) Ensure your Archon/Supabase/LiteLLM containers mount the certs and include the env file, e.g.:"
echo
cat <<'COMPOSE'
# Example compose fragment to apply to TLS clients (Archon server, Studio, etc.)
# Add to those services:
#   env_file:
#     - ./traefik/env.d/ca.env
#   volumes:
#     - ./traefik/certs/rootCA.pem:/usr/local/share/ca-certificates/mkcert-root.crt:ro
#
# Their entrypoint/startup should already run:
#   update-ca-certificates
#
# If not, add a tiny init command before the app starts, e.g.:
#   sh -lc "update-ca-certificates && exec your-app"
COMPOSE
