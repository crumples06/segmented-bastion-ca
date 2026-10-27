#!usr/bin/env bash
cd "$(dirname "$0")/.."
CA_PASSWORD="${CA_PASSWORD:-unused}" docker compose down -v
rm -f .env ca/user_ca.pub ca/host_ca.pub ca/known_hosts \
      control/group_vars/all/vars.yml control/group_vars/all/vault.yml \
      control/ssh_config_bootstrap keys/key keys/key.pub keys/key-cert.pub