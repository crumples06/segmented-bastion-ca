#!/usr/bin/env bash
set -euo pipefail

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PW="${CI_CA_PASSWORD:?set CI_CA_PASSWORD}"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Build a full ssh config for one identity (cert optional)
mkcfg() {  # $1=file  $2=key  $3=cert (optional)
  cat > "$1" <<EOF
Host bastion
    HostName localhost
    Port 2222
Host bastion server1 server2
    User admin
    IdentityFile $2
    ${3:+CertificateFile $3}
    IdentitiesOnly yes
Host server1 server2
    ProxyJump bastion
Host *
    UserKnownHostsFile ca/known_hosts
    StrictHostKeyChecking yes
EOF
}

# Pass only if login is refused FOR AUTHENTICATION REASONS
expect_denied() {  # $1=label  $2=config  $3...=extra ssh options
  local label=$1 cfg=$2; shift 2
  local out rc=0
  out=$(ssh -F "$cfg" -o BatchMode=yes -o ConnectTimeout=10 "$@" server1 true 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: login unexpectedly SUCCEEDED"
  echo "$out" | grep -q "Permission denied" || fail "$label: failed, but not with Permission denied: $out"
  pass "$label rejected"
}

# Sign a public key with the CI CA (used for expired and wrong-principal certs)
sign() {  # $1=pubkey  $2=principal  $3=not-after  $4=id
  printf '%s' "$PW" | docker compose exec -T ca sh -c 'cat > /tmp/pw'
  docker compose cp "$1" ca:/tmp/n.pub
  docker compose exec -T ca step ssh certificate --sign --force --provisioner admin \
    --provisioner-password-file /tmp/pw --principal "$2" --not-after "$3" "$4" /tmp/n.pub
  docker compose cp ca:/tmp/n-cert.pub "${1%.pub}-cert.pub"
}

# --- Start the slow one first so it can expire while the others run ---
ssh-keygen -t ed25519 -N "" -q -f "$WORK/expired"
sign "$WORK/expired.pub" admin 1m expired-user

# 1. Valid key, but no certificate (fresh key: no -cert.pub sits beside it)
ssh-keygen -t ed25519 -N "" -q -f "$WORK/nocert"
mkcfg "$WORK/c_nocert" "$WORK/nocert"
expect_denied "no certificate" "$WORK/c_nocert"

# 2. Certificate from a CA the servers don't trust
ssh-keygen -t ecdsa -N "" -q -f "$WORK/rogue_ca"
ssh-keygen -t ed25519 -N "" -q -f "$WORK/rogue"
ssh-keygen -q -s "$WORK/rogue_ca" -I rogue -n admin -V +1h "$WORK/rogue.pub"
mkcfg "$WORK/c_rogue" "$WORK/rogue" "$WORK/rogue-cert.pub"
expect_denied "certificate from untrusted CA" "$WORK/c_rogue"

# 3. Genuine CA, wrong principal
ssh-keygen -t ed25519 -N "" -q -f "$WORK/wrongp"
sign "$WORK/wrongp.pub" notadmin 1h wrongp-user
mkcfg "$WORK/c_wrongp" "$WORK/wrongp" "$WORK/wrongp-cert.pub"
expect_denied "wrong principal" "$WORK/c_wrongp"

# 4. Password auth (using the valid test identity)
mkcfg "$WORK/c_valid" keys/key keys/key-cert.pub
expect_denied "password authentication" "$WORK/c_valid" \
  -o PubkeyAuthentication=no -o PreferredAuthentications=password

# 5. Expired certificate (65 s after issuing, a margin past the 1 m validity)
mkcfg "$WORK/c_expired" "$WORK/expired" "$WORK/expired-cert.pub"
sleep 65
expect_denied "expired certificate" "$WORK/c_expired"

# 6. Isolation: server1's container IP must not be reachable from the runner
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' server1)
if timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
     -o UserKnownHostsFile=/dev/null admin@"$IP" true 2>/dev/null; then
  fail "isolation: server1 reachable directly at $IP"
fi
pass "server1 not directly reachable"