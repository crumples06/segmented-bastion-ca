#!/usr/bin/bash
set -euo pipefail

HOSTS="bastion server1 server2"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; } 

# Login works on every host
for h in $HOSTS; do
  got=$(ssh -F ssh_config "$h" hostname)
  want=$(docker compose exec -T "$h" hostname)
  [ "$got" = "$want" ] || fail "$h: reached '$got', expected '$want'"
  pass "login to $h reached the right machine"
done

# Login used certificate and not a static key
for h in $HOSTS; do
  docker compose logs "$h" 2>&1 \
    | grep -E "Accepted publickey for admin .*ED25519-CERT.*ID ci-user" >/dev/null \
    || fail "$h: no certificate login logged for ci-user"
  pass "$h logged a certificate login (ID ci-user)"
done

# The client verified each host by its host certificate
for h in $HOSTS; do
  out=$(ssh -v -F ssh_config "$h" true 2>&1)
  echo "$out" | grep -q "known and matches the ED25519-CERT host certificate" \
    || fail "$h: host certificate not verified"
  pass "$h verified via host certificate"
done
