#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."

# Secrets: generate once, never print
if [ ! -f .env ]; then
    printf 'CA_PASSWORD=%s\nVAULT_PASSWORD=%s\n' \
      "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" > .env
fi
set -a; . ./.env; set +a

# CA first: everything else depends on ots output
docker compose up -d ca --wait

# Export public material (must exist before the hosts start)
mkdir -p ca
docker compose cp ca:/home/step/certs/ssh_user_ca_key.pub ca/user_ca.pub
docker compose cp ca:/home/step/certs/ssh_host_ca_key.pub ca/host_ca.pub
echo "@cert-authority [localhost]:2222,bastion,server1,server2 $(cat ca/host_ca.pub)" > ca/known_hosts
FP=$(docker compose exec -T ca step certificate fingerprint /home/step/certs/root_ca.crt | tr -d '\r')

# Generate Ansible variables
cat > control/group_vars/all/vars.yml <<EOF
ca_fingerprint: "$FP"
host_cert_path: /etc/ssh/host_keys/ssh_host_ed25519_key-cert.pub
ca_provisioner_password: "{{ vault_ca_provisioner_password }}"
EOF
printf 'vault_ca_provisioner_password: "%s"\n' "$CA_PASSWORD" > control/group_vars/all/vault.yml

# Everything else
docker compose up -d --build --wait

# Vault: password file lives inside the container, then encrypt
printf '%s' "$VAULT_PASSWORD" | docker compose exec -T control sh -c \
  'cat > /root/.vault_pass && chmod 600 /root/.vault_pass'
docker compose exec -T control ansible-vault encrypt group_vars/all/vault.yml

# Bootstrap run only if some host has no certificate yet
need_bootstrap=0
for h in bastion,server1,server2; do
    docker compose exec -T "$h" test -f /etc/ssh/host_keys/ssh_host_ed25519_key-cert.pub || need_bootstrap=1
done
if [ "$need_bootstrap" = 1 ]; then
  cat > control/ssh_config_bootstrap <<'EOF'
Host bastion server1 server2
  User admin
  IdentityFile ~/.ssh/id_ed25519
  CertificateFile ~/.ssh/id_ed25519-cert.pub
  IdentitiesOnly yes
  UserKnownHostsFile /tmp/bootstrap_known_hosts
  StrictHostKeyChecking accept-new
Host server1 server2
  ProxyJump bastion
EOF
  docker compose exec -T control ansible-playbook -i inventory.yml site.yml \
    -e '{"ansible_ssh_common_args": "-F /work/ssh_config_bootstrap"}'
fi

# Strict run: proves the hosts now present CA-signed certificates
docker compose exec -T control ansible-playbook -i inventory.yml site.yml
echo "Lab is up. Next: scripts/login.sh"
