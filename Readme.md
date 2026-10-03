# Bastion Access Project

A Docker Compose lab demonstrating a hardened SSH bastion (jump host) pattern: a single, controlled entry point in front of a network of otherwise unreachable machines, with authentication and host identity both handled by a private SSH certificate authority ([step-ca](https://smallstep.com/docs/step-ca/)).

## Architecture

```
                 ┌───────────────────────────────────────────────┐
                 │                  "public" network             │
                 │                                               │
   your host ────┼────   localhost:2222 ────▶  bastion           |
                 │                               │               │
                 └────────────────────────────── ┼───────────────┘
                                                 │
                 ┌───────────────────────────────┼───────────────┐
                 │          "private" network (internal: true)   │
                 │                             │                 │
                 │                 ┌───────────┴───────────┐     │
                 │                 │                       │     │
                 │              server1                 server2  │
                 │                                               │
                 └───────────────────────────────────────────────┘

                 ┌───────────────────────────────────────────────┐
   your host ────┼── 127.0.0.1:9000 ───▶  ca (step-ca)           │
                 │          "ca" network (no link to the others) │
                 └───────────────────────────────────────────────┘
```

- **bastion** is the only SSH host on both `public` and `private`, and the only one that publishes a port to the host (`2222:22`).
- **server1** and **server2** sit only on `private`, a Docker `internal: true` network with no route to the host or the outside world.
- **ca** runs the official `smallstep/step-ca` image on its own `ca` network. Nothing connects it to `public` or `private`, and its API is published to `127.0.0.1:9000` only. The servers never contact the CA: they only need its *public* keys, installed once.
- The three SSH hosts are built from one shared Dockerfile. Their role is determined by Compose configuration (networking, ports), not by separate images. The CA is a different kind of machine, so it uses its own image.

## How certificate authentication works here

The CA holds two separate SSH signing keys (created at init with `DOCKER_STEPCA_INIT_SSH=true`):

| CA key | Signs | Trusted by | Configured in |
|---|---|---|---|
| **User CA** | Login certificates ("this key may log in as `admin`") | The servers, via `TrustedUserCAKeys` | `hardening.conf`, key at `/etc/ssh/user_ca.pub` |
| **Host CA** | Host certificates ("this machine really is `server1`") | The client, via `@cert-authority` | `ca/known_hosts` on the client |

Everything is verified **offline**. Servers and clients never call the CA at login time, so certificate expiry takes the place of revocation: a short-lived user certificate is useless once its window closes.

The client never stores a per-server fingerprint. `ca/known_hosts` holds a single line trusting the host CA for the lab's host names, and `StrictHostKeyChecking yes` means anything the CA hasn't vouched for is refused with no prompt.

## What "hardened" means here, concretely

| Property | How it's enforced | How it was verified |
|---|---|---|
| Network isolation | `private` network is `internal: true`; only `bastion` bridges both networks; `ca` has its own network | Direct `ssh` to server1's container IP from the host **times out** (packets dropped, not rejected) — vs. successful access via the bastion |
| Key-only authentication | `PasswordAuthentication no` in `sshd_config.d/hardening.conf` | Forcing `PubkeyAuthentication=no` from the client returns `Permission denied (publickey)`, not a password prompt |
| No root login | `PermitRootLogin no` in the same drop-in | `sshd -T` showing the resolved (not just written) config |
| Unique host identity per container | Host keys deleted at build time, generated at container start via an entrypoint script | `ssh-keygen -lf` fingerprints differ across bastion/server1/server2 |
| Stable host identity across restarts | Host keys in a per-container named volume at `/etc/ssh/host_keys`, with `HostKey` lines pointing sshd at it | Fingerprint identical before/after `docker restart` **and** after `docker compose down && up` |
| Bastion never holds your private key | `ProxyJump` — the client authenticates both hops itself; the bastion only relays encrypted bytes | Standard OpenSSH behavior; no private key material is copied into any container |
| Certificate-only login | No `authorized_keys` exists in the image; sshd trusts only the CA via `TrustedUserCAKeys` | `/home/admin/.ssh` is absent on freshly recreated containers, yet login works; server log shows `Accepted publickey for admin ... ED25519-CERT ... ID tanish (serial ...) CA ECDSA SHA256:...` on bastion, server1 and server2 |
| CA-verified host identity | Each host presents a CA-signed host certificate (`HostCertificate`); client trusts only `@cert-authority` with strict checking | `ssh -v` shows `Host '...' is known and matches the ED25519-CERT host certificate` for bastion, server1 and server2, with no fingerprint stored anywhere |
| Short-lived credentials | User certs issued for 1h (8h for a working session); host certs for 30 days | Validity window visible with `ssh-keygen -Lf` |
| Expired certificates are rejected | Same mechanism (sshd checks the validity window locally) | **Not yet tested** — deliberately deferred, see below |

## The starting point vs. where it ended up

This project deliberately started with the naive version of each piece, then hardened it, so the "before" is preserved as a teaching artifact:

- **Auth:** `root:password` via `chpasswd` → key-only login as a non-root `admin` user → **CA-signed, short-lived user certificates with no static keys on any host**.
- **Host keys:** all three containers silently shared identical host keys (baked in at image-build time by the `openssh-server` post-install script) → each container generates and persists its own unique identity → **each identity is vouched for by a host certificate**.
- **Host verification:** trust-on-first-use fingerprint prompts → a single `@cert-authority` line with strict checking.
- **Network reachability:** initial Compose file had no isolation → `server1`/`server2` verified unreachable except through the bastion.
- **Jump auth:** initially failed with a password prompt for the bastion hop, because `-i` on the command line doesn't propagate to the hidden first-hop connection `-J` creates → solved with a per-host `ssh_config` (`IdentityFile`, `CertificateFile`, `ProxyJump`) plus `ssh-agent` to avoid repeated passphrase prompts.

## Key design decisions

- **One image for the SSH hosts, a separate image for the CA.** Topology (networks, ports, volumes) defines a machine's role among the SSH hosts. The CA is a different kind of machine, so it doesn't share their image.
- **Host keys generated at container start, not build time.** Keeps the image free of key material and gives every container its own identity the moment it's created.
- **Host keys persisted via named volumes, scoped narrowly.** Only `/etc/ssh/host_keys` is volume-backed, not all of `/etc/ssh`, so `sshd_config` and the hardening drop-in still come fresh from the image on every rebuild. The alternative (mounting the whole directory) was rejected because stale config could silently survive a rebuild.
- **Host certificates live in the volumes, not the image.** The image is shared by all three hosts, so a baked-in certificate would be identical everywhere. A certificate is also bound to one exact host key, which is another reason persistent host keys matter: if a volume were deleted, the key would regenerate and its certificate would no longer match.
- **The CA is network-isolated and never contacted by servers.** The only things that travel to the servers are public keys, installed at build time. A compromised server or bastion has no path to the CA.
- **Two separate CA keys (user and host).** Trusting one does not imply trusting the other.
- **`ProxyJump` over `sshd`-level forwarding tricks.** The bastion is a relay, never a holder of credentials. Note that user certificates must keep `permit-port-forwarding`, because `ProxyJump` relies on it.
- **A project-local `known_hosts`** (`UserKnownHostsFile ca/known_hosts`), so the CA line is the *only* host trust the client has. A success can then only be explained by the CA, not by an old fingerprint in `~/.ssh/known_hosts`.
- **Issuance is manual in v1.** The `docker cp` / `docker exec` steps are visible on purpose, so the CA mechanics are understood before they're automated.

## Problems encountered and how they were solved

| Problem | Root cause | Fix |
|---|---|---|
| `failed to decrypt JWE: invalid password` when signing | Two different secrets exist: `/home/step/secrets/password` encrypts the CA's own keys, while the **provisioner password** (printed once in `docker logs ca` at first init) authorizes signing | Use the provisioner password |
| Login succeeded but the log said plain `ED25519`, not `ED25519-CERT` | The static `authorized_keys` entry was still valid, so the client's first offer (the plain key) was accepted before the certificate was tried | Remove the static key's ability to log in and read the server-side `Accepted` line to see which method actually worked |
| Client not offering the certificate | Relying on OpenSSH auto-discovering `<key>-cert.pub` | Explicit `CertificateFile` in both `ssh_config` blocks (the `ProxyJump` first hop is a separate connection) |
| Rebuild "worked" but `authorized_keys.bak` was still present | Compose only recreates containers when the image changes; the edit hadn't taken effect, so the old containers were tested | Verify the change landed, then `docker compose up -d --build --force-recreate` |
| `ssh server1 true` appeared to do nothing | Not a fault: `true` runs, exits successfully and disconnects, so success is silent | Judge by the server's `Accepted` log line, or run `ssh server1 hostname` |
| `open server1_host-cert.pub: permission denied` while signing | `docker cp` creates files as root; inside the container `step` runs as an unprivileged user and cannot write into a root-owned directory | Sign from a scratch directory created inside the container (`mkdir /tmp/hk`) |
| Bastion crash-looping after adding the host certificate | Typo in `hardening.conf`: `HostCertificates` instead of the singular `HostCertificate`. sshd refuses to start on an unknown option | Correct the directive. Check `docker compose logs` first when a container restarts |
| Noisy `Could not save your private key in /etc/ssh/host_keys/etc/ssh/...` on every start | A stray `ssh-keygen -A -f /etc/ssh/host_keys` line in the entrypoint tried to write to a nested path that doesn't exist | Removed the line; the key-generation loop already does the job |
| Repeated key passphrase prompts (one per `ProxyJump` hop) | The agent was empty: it was never started in that terminal, or its cache lifetime (matched to the certificate's validity) had expired | `ssh-agent` + `ssh-add keys/key`, once per session |

A common thread: **verify the mechanism, not just the outcome.** "The login worked" was true in several cases where the certificate was not involved at all.

## Known, deliberately deferred gaps

Documented here rather than fixed, to keep the project's scope bounded:

- **Expired-certificate rejection is not yet demonstrated.** The mechanism is standard OpenSSH behavior, but no test has been run yet. This is a planned CI check.
- **Issuance is manual.** Signing and distributing user and host certificates is done by hand; automating it (Ansible) is the next phase.
- **Host certificates expire after 30 days** and need re-signing (and a restart of the host) before then.
- **Lab credentials.** The CA's provisioner password was exposed during development, so it is a lab-only value. Wipe the `ca_data` volume and re-initialize before reusing this CA for anything real.
- No `fail2ban` / intrusion detection on the bastion.
- **Session audit logging is only partial.** sshd now logs to `docker logs` (`-e`), including the certificate ID, serial and CA fingerprint of every login, but there is no central collection or retention.
- Sudo is installed on all containers but not specifically scoped or restricted for `admin`.
- The CA uses a single JWK provisioner with a shared password; there is no per-user identity or OIDC integration.

## Reproducing / testing this yourself

Bootstrap order matters: the SSH images copy in the CA's public user key, so the CA has to exist first.

```bash
# 1. Start the CA alone; first start initializes it (including the two SSH CA keys)
docker compose up -d ca
docker logs ca 2>&1 | grep -i password     # the provisioner password (shown once)

# 2. Export the CA's PUBLIC keys into the project (safe to commit)
mkdir -p ca
docker cp ca:/home/step/certs/ssh_user_ca_key.pub ca/user_ca.pub
docker cp ca:/home/step/certs/ssh_host_ca_key.pub ca/host_ca.pub
echo "@cert-authority [localhost]:2222,bastion,server1,server2 $(cat ca/host_ca.pub)" > ca/known_hosts

# 3. Build and start the SSH hosts
docker compose up -d --build
```

Issue a user certificate for your existing key (the private key never leaves your machine). Run `step` from a shell *inside* the CA container; under Git Bash, calling `docker exec` with `/tmp/...` arguments gets mangled by path conversion.

```bash
docker cp keys/key.pub ca:/tmp/key.pub
docker exec -it ca sh
#   step ssh certificate --sign --force --provisioner admin \
#       --principal admin --not-after 1h tanish /tmp/key.pub
#   exit
docker cp ca:/tmp/key-cert.pub keys/key-cert.pub
ssh-keygen -Lf keys/key-cert.pub         # principal, validity window, signing CA
eval "$(ssh-agent -s)" && ssh-add keys/key
```

Sign the host keys (from a scratch directory the `step` user owns), install the certificates into the volumes, then enable `HostCertificate` in `hardening.conf` and recreate:

```bash
mkdir -p ca/tmp
docker cp bastion:/etc/ssh/host_keys/ssh_host_ed25519_key.pub ca/tmp/bastion_host.pub
docker cp server1:/etc/ssh/host_keys/ssh_host_ed25519_key.pub ca/tmp/server1_host.pub
docker cp server2:/etc/ssh/host_keys/ssh_host_ed25519_key.pub ca/tmp/server2_host.pub
docker cp ca/tmp ca:/tmp/hostkeys
docker exec -it ca sh
#   mkdir /tmp/hk && cp /tmp/hostkeys/*.pub /tmp/hk/ && cd /tmp/hk
#   step ssh certificate --sign --host --provisioner admin \
#       --principal bastion --principal localhost --not-after 720h bastion bastion_host.pub
#   step ssh certificate --sign --host --provisioner admin \
#       --principal server1 --not-after 720h server1 server1_host.pub
#   step ssh certificate --sign --host --provisioner admin \
#       --principal server2 --not-after 720h server2 server2_host.pub
#   exit
docker cp ca:/tmp/hk/. ca/tmp/
for h in bastion server1 server2; do
  docker cp ca/tmp/${h}_host-cert.pub $h:/etc/ssh/host_keys/ssh_host_ed25519_key-cert.pub
done
# add to hardening.conf, AFTER the certs are in place:
#   HostCertificate /etc/ssh/host_keys/ssh_host_ed25519_key-cert.pub
docker compose up -d --build --force-recreate bastion server1 server2
```

Verify:

```bash
# Hardening is enforced, not just written
docker exec bastion sshd -T | grep -iE "passwordauthentication|permitrootlogin|trustedusercakeys|hostcertificate"

# Isolation: this should time out
ssh admin@$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' server1)

# Host certificates are what the client is trusting
ssh -v -F ssh_config server1 true 2>&1 | grep -i "host certificate"

# No static keys exist, yet login works, and the server log names the certificate used
docker exec bastion ls /home/admin/.ssh        # expect: No such file or directory
ssh -F ssh_config server1 true
docker logs server1 2>&1 | grep Accepted | tail -1   # ...ED25519-CERT... ID tanish ... CA ECDSA SHA256:...
```

Note that `ssh server1 true` runs a no-op command and returns silently on success; the server's `Accepted` log line is the evidence, or use `ssh -F ssh_config server1 hostname` for visible output.

## Files

- `docker-compose.yml` — services (`bastion`, `server1`, `server2`, `ca`), networks (`public`, `private [internal]`, `ca`), named volumes for host keys and CA state (`ca_data`)
- `Dockerfile` — shared SSH-host image: Ubuntu 24.04, openssh-server, non-root `admin` user, and the CA's public user key at `/etc/ssh/user_ca.pub`. No `authorized_keys` is baked in
- `host_keygen.sh` — entrypoint: generates missing host keys, then `exec`s sshd with `-e` so logs reach `docker logs`
- `hardening.conf` — sshd drop-in: `PasswordAuthentication no`, `PermitRootLogin no`, `HostKey` paths, `TrustedUserCAKeys`, `HostCertificate`
- `ssh_config` — client config: `bastion` and `server1`/`server2` (via `ProxyJump`) with `IdentityFile` and `CertificateFile`; `Host *` sets `UserKnownHostsFile ca/known_hosts` and `StrictHostKeyChecking yes`
- `ca/user_ca.pub`, `ca/host_ca.pub`, `ca/known_hosts` — public CA keys and the client trust line (safe to commit)
- `keys/key` — your private key (git-ignored). `keys/key.pub` is signed by the CA to produce `keys/key-cert.pub`
- `.gitignore` — should also list `keys/key-cert.pub` and `ca/tmp/` (generated artifacts; a user certificate is a time-limited credential)

**Never commit:** the `ca_data` volume contents, the CA provisioner password, or any private key.