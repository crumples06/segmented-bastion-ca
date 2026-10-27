#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
KEY_ID="${KEY_ID:-me}"

mkdir -p keys
[ -f keys/key ] || ssh-keygen -t ed25519 -N "" -q -f keys/key

printf '%s' "$CA_PASSWORD" | docker compose exec -T ca sh -c \
  'mkdir -p /tmp/t && cat > /tmp/t/pw && chmod 600 /tmp/t/pw'
docker compose cp keys/key.pub ca:/tmp/t/key.pub
docker compose exec -T ca step ssh certificate --sign --force --provisioner admin \
  --provisioner-password-file /tmp/t/pw --principal admin --not-after 1h "$KEY_ID" /tmp/t/key.pub
docker compose cp ca:/tmp/t/key-cert.pub keys/key-cert.pub
docker compose exec -T ca rm -rf /tmp/t

ssh-add keys/key 2>/dev/null || echo "Run: eval \"\$(ssh-agent -s)\" && ssh-add keys/key"
echo "Certificate valid for 1h. Try: ssh -F ssh_config server1 hostname"