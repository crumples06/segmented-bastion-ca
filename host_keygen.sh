#!/bin/bash
mkdir -p /etc/ssh/host_keys
for type in rsa ecdsa ed25519; do
    key="/etc/ssh/host_keys/ssh_host_${type}_key"
    [ -f "$key" ] || ssh-keygen -t "$type" -f "$key" -N ""
done
exec /usr/sbin/sshd -D -e