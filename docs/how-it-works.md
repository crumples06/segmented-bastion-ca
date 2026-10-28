# How it works

[← Back to README](../README.md)

## Certificate authentication

The CA holds two separate SSH signing keys (created at init with `DOCKER_STEPCA_INIT_SSH=true`):

| CA key | Signs | Trusted by | Configured in |
|---|---|---|---|
| **User CA** | Login certificates ("this key may log in as `admin`") | The servers, via `TrustedUserCAKeys` | `hardening.conf`; the public key is bind-mounted read-only at `/etc/ssh/user_ca.pub` |
| **Host CA** | Host certificates ("this machine really is `server1`") | Clients, via `@cert-authority` | `ca/known_hosts` |

Everything is verified **offline**. Servers and clients never call the CA at login time, so certificate expiry takes the place of revocation: a short-lived user certificate is useless once its window closes.

Clients never store a per-server fingerprint. `ca/known_hosts` holds a single line trusting the host CA for the lab's host names, and `StrictHostKeyChecking yes` means anything the CA hasn't vouched for is refused with no prompt.

The CA also has an **X.509 root** that protects its HTTPS API. That is a third, unrelated trust anchor: the `step` CLI uses it (via `step ca bootstrap`) to trust the CA's API, and it plays no part in SSH verification.

## Ansible automation

`control/site.yml` has two plays.

**Play 1: prepare the control node (`localhost`, local connection):**
1. Trust the CA's HTTPS API: `step ca bootstrap` with the pinned root fingerprint (guarded by `creates:` so it runs once).
2. Check the CA answers (`step ca health`).
3. Make sure `~/.ssh` exists.
4. Create the control node's ed25519 key pair (once).
5. Issue a fresh 8-hour user certificate for it (key ID `ansible-control`, principal `admin`). This task reports `changed` on every run by design.

**Play 2: issue and renew host certificates (`ssh_hosts`, through the bastion):**
1. Read each host's current certificate (`ssh-keygen -L`).
2. Decide whether a renewal is due: no certificate, fewer than 7 days left, or `force_renew=true`.
3. Fetch the host's public key to the control node.
4. Sign it with the CA (`step ssh certificate --sign --host`) with the right principals per host. `bastion` also gets `localhost`, because that is the name the developer's own client uses.
5. Install the certificate on the host and reload sshd.

To run it by hand, for example to force a renewal:

```bash
docker compose exec control ansible-playbook -i inventory.yml site.yml
# force a renewal to exercise the full path:
docker compose exec control ansible-playbook -i inventory.yml site.yml -e force_renew=true
```

No vault flag is needed: `bootstrap.sh` writes the vault password to `/root/.vault_pass` inside the control container, and `ANSIBLE_VAULT_PASSWORD_FILE` in `docker-compose.yml` points Ansible at it. The file lives inside the container, not on the bind mount, because Windows bind mounts expose files as executable and Ansible would try to run it as a script. If the control container is recreated the file is gone; rerun `bash scripts/bootstrap.sh` to restore it.

Inside Docker, the control node connects to the bastion on port 22 (not the published 2222). `ca/known_hosts` trusts the host CA for `[localhost]:2222` (the developer's client), `bastion`, `server1` and `server2`, and the host certificates include the matching names as principals, so strict checking passes with no extra signing.

## Scripts

| Script | What it does |
|---|---|
| `scripts/bootstrap.sh` | Builds a working lab from nothing: secrets, CA, public keys, Ansible variables, vault, containers, host certificates, and a strict-checked verification run. Safe to rerun |
| `scripts/login.sh` | Issues a 1-hour user certificate for `keys/key` (generated if missing) and tries to load the key into ssh-agent; if no agent is running it prints the commands to start one. `KEY_ID=<id>` sets the certificate's key ID (default `me`) |
| `scripts/reset.sh` | `docker compose down -v`, then deletes `.env` and the generated files |

### What `bootstrap.sh` does

The order matters, because each stage needs the output of the one before it.

1. **Generate secrets once.** If `.env` is missing, write a random CA provisioner password (`CA_PASSWORD`) and a random vault password (`VAULT_PASSWORD`) into it. Compose passes `CA_PASSWORD` to the CA as `DOCKER_STEPCA_INIT_PASSWORD`, so the password is known in advance instead of being printed once in the CA's logs.
2. **Start the CA alone** and wait for its healthcheck. Everything else depends on its output.
3. **Export the CA's public material:** the user CA and host CA public keys into `ca/`, a single `@cert-authority` line into `ca/known_hosts`, and the X.509 root fingerprint into a variable. Only public keys leave the CA. This must happen before the SSH hosts start, because `ca/user_ca.pub` is bind-mounted into them and Docker would otherwise create a directory in its place.
4. **Generate the Ansible variables:** `vars.yml` (fingerprint, certificate path, and a reference to the vaulted password) and a plaintext `vault.yml` holding the provisioner password.
5. **Build and start everything else.** Each host generates its own keys into its named volume on first start.
6. **Encrypt the vault.** The vault password goes into `/root/.vault_pass` inside the control container, then `ansible-vault encrypt` runs on `vault.yml`.
7. **Bootstrap run, only if needed.** The script checks whether each host already has a certificate. If any host has none, strict host checking cannot succeed, so this one run uses a generated `ssh_config_bootstrap` with `StrictHostKeyChecking accept-new` and a scratch known-hosts file. It is passed as a full config so both `ProxyJump` hops see the same settings. On a rerun where every host already has a certificate, this step is skipped.
8. **Strict run, always.** The normal playbook run with strict checking succeeds only if the hosts now present CA-signed certificates the control node accepts. This is the proof that step 7 worked.

Manual equivalent, if you want to see each piece: the CA is started with `docker compose up -d ca --wait`; the public keys come from `docker compose cp ca:/home/step/certs/ssh_user_ca_key.pub ca/user_ca.pub` (and `ssh_host_ca_key.pub`); the fingerprint is `docker compose exec -T ca step certificate fingerprint /home/step/certs/root_ca.crt`; a human certificate is signed with `step ssh certificate --sign --provisioner admin --principal admin --not-after 1h <key-id> <pubkey>` inside the CA container.

## Resetting

`bash scripts/reset.sh` removes the containers, networks and volumes (CA state, host keys, host certificates) and deletes `.env`, `ca/user_ca.pub`, `ca/host_ca.pub`, `ca/known_hosts`, the generated vars and vault, the bootstrap config and `keys/key*`. A new CA means a new fingerprint, password and public keys, so everything is regenerated by the next `bootstrap.sh`.

Compose must parse `docker-compose.yml` for every command, including `down`, and the CA service requires `CA_PASSWORD`. `reset.sh` passes a dummy value for the teardown for that reason. If you run `docker compose down -v` yourself without a `.env`, use `CA_PASSWORD=unused docker compose down -v`.

## Files

- `scripts/bootstrap.sh`, `scripts/login.sh`, `scripts/reset.sh`: setup, login and teardown
- `docker-compose.yml`: services (`bastion`, `server1`, `server2`, `ca`, `control`), networks (`public`, `private [internal]`, `ca`), named volumes for host keys and CA state. The CA's init password comes from `CA_PASSWORD` in `.env`; the SSH hosts bind-mount `./ca/user_ca.pub` read-only; `control` mounts `./control` at `/work` and `./ca` read-only at `/ca`
- `dockerfile`: shared SSH-host image: Ubuntu 24.04, openssh-server, Python 3, non-root `admin` user with passwordless sudo. No `authorized_keys` and no CA key are baked in
- `host_keygen.sh`: entrypoint: generates missing host keys, then `exec`s sshd with `-e` so logs reach `docker logs`
- `hardening.conf`: sshd drop-in: `PasswordAuthentication no`, `PermitRootLogin no`, `HostKey` paths, `TrustedUserCAKeys`, `HostCertificate`
- `ssh_config`: your own client config with `ProxyJump`, `IdentityFile`, `CertificateFile`, and strict checking against `ca/known_hosts`
- `control/dockerfile`: control image: Ansible, the `step` CLI and OpenSSH
- `control/site.yml`: the two plays above
- `control/inventory.yml`: the `ssh_hosts` group with per-host certificate principals
- `control/ssh_config_control`: the control node's SSH config
- `ci/positive-tests.sh`, `ci/negative-tests.sh`, `.github/workflows/ci.yml`: the tests and the pipeline (see [CI](ci.md))
- `.gitattributes`: forces LF line endings on shell scripts

**Generated by `bootstrap.sh` and `login.sh` (gitignored, never committed):**

- `.env`: the CA provisioner password and the vault password
- `ca/user_ca.pub`, `ca/host_ca.pub`, `ca/known_hosts`: the lab CA's public keys and the client trust line
- `control/group_vars/all/vars.yml`, `control/group_vars/all/vault.yml`: Ansible variables; the vault holds the provisioner password, encrypted with Ansible Vault
- `control/ssh_config_bootstrap`: the relaxed SSH config for the first playbook run
- `keys/key`, `keys/key.pub`, `keys/key-cert.pub`: your private key, its public half, and the CA-signed certificate

**Never commit:** `.env`, the `ca_data` volume contents, the CA provisioner password in plaintext, any vault password file, or any private key.