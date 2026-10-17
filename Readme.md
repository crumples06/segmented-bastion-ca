# Bastion Access Project

![CI](https://github.com/<user>/<repo>/actions/workflows/ci.yml/badge.svg)

A Docker Compose lab demonstrating a hardened SSH bastion (jump host) pattern: a single, controlled entry point in front of a network of otherwise unreachable machines. Authentication and host identity are both handled by a private SSH certificate authority ([step-ca](https://smallstep.com/docs/step-ca/)), host certificates are issued and renewed by an Ansible playbook, and a GitHub Actions pipeline rebuilds the whole lab from scratch and verifies the security properties on every pull request.

## Architecture

```
                 ┌───────────────────────────────────────────────┐
                 │                  "public" network             │
                 │                                               │
   your host ────┼────   localhost:2222 ────▶  bastion           │
                 │                               │               │
                 │                    control ───┼── (ssh :22)   │
                 │                      │        │               │
                 └──────────────────────┼─────── ┼───────────────┘
                                        │        │
                 ┌──────────────────────┼────────┼───────────────┐
                 │          "private" network (internal: true)   │
                 │                      │    │                   │
                 │                 ┌────┴────┴─────────┐         │
                 │                 │                   │         │
                 │              server1             server2      │
                 │                                               │
                 └───────────────────────────────────────────────┘

                 ┌───────────────────────────────────────────────┐
                 │  "ca" network:   ca (step-ca)  ◀── control    │
                 │  127.0.0.1:9000 published to the host only    │
                 └───────────────────────────────────────────────┘
```

- **bastion** is the only SSH host on both `public` and `private`, and the only one that publishes a port to the host (`2222:22`).
- **server1** and **server2** sit only on `private`, a Docker `internal: true` network with no route to the host or the outside world.
- **ca** runs the official `smallstep/step-ca` image on its own `ca` network. Its API is published to `127.0.0.1:9000` only. The SSH hosts have no network path to it and never contact it: they only need its *public* keys.
- **control** runs Ansible and the `step` CLI. It sits on `public` (to reach the bastion on port 22 and, through it, the servers) and on `ca` (to call the CA's HTTPS API). It does **not** join `private`, so the servers stay reachable only through the bastion.
- The three SSH hosts share one Dockerfile; their role comes from Compose configuration (networks, ports, volumes). The CA and control node are different kinds of machine and use their own images.

## How certificate authentication works here

The CA holds two separate SSH signing keys (created at init with `DOCKER_STEPCA_INIT_SSH=true`):

| CA key | Signs | Trusted by | Configured in |
|---|---|---|---|
| **User CA** | Login certificates ("this key may log in as `admin`") | The servers, via `TrustedUserCAKeys` | `hardening.conf`, key at `/etc/ssh/user_ca.pub` |
| **Host CA** | Host certificates ("this machine really is `server1`") | Clients, via `@cert-authority` | `ca/known_hosts` |

Everything is verified **offline**. Servers and clients never call the CA at login time, so certificate expiry takes the place of revocation: a short-lived user certificate is useless once its window closes.

Clients never store a per-server fingerprint. `ca/known_hosts` holds a single line trusting the host CA for the lab's host names, and `StrictHostKeyChecking yes` means anything the CA hasn't vouched for is refused with no prompt.

The CA also has an **X.509 root** that protects its HTTPS API. That is a third, unrelated trust anchor: the `step` CLI uses it (via `step ca bootstrap`) to trust the CA's API, and it plays no part in SSH verification.

## What "hardened" means here, concretely

| Property | How it's enforced | How it was verified |
|---|---|---|
| Network isolation | `private` is `internal: true`; only `bastion` bridges `public` and `private`; `ca` has its own network | Direct `ssh` to server1's container IP **times out** (packets dropped, not rejected); checked on every CI run |
| Key-only authentication | `PasswordAuthentication no` in `sshd_config.d/hardening.conf` | Forcing `PubkeyAuthentication=no` from the client returns `Permission denied`, not a password prompt; checked on every CI run |
| No root login | `PermitRootLogin no` in the same drop-in | `sshd -T` showing the resolved (not just written) config |
| Unique host identity per container | Host keys deleted at build time, generated at container start via an entrypoint script | `ssh-keygen -lf` fingerprints differ across bastion/server1/server2 |
| Stable host identity across restarts | Host keys in a per-container named volume at `/etc/ssh/host_keys`, with `HostKey` lines pointing sshd at it | Fingerprint identical before/after `docker restart`, after `docker compose down && up`, **and** across a certificate renewal |
| Bastion never holds your private key | `ProxyJump`: the client authenticates both hops itself; the bastion only relays encrypted bytes | Standard OpenSSH behavior; no private key material is copied into any container |
| Certificate-only login | No `authorized_keys` exists in the image; sshd trusts only the CA via `TrustedUserCAKeys` | `/home/admin/.ssh` is absent in every container (CI-checked), yet login works; the server log shows `Accepted publickey for admin ... ED25519-CERT ... ID <key id> (serial ...) CA ECDSA SHA256:...` on bastion, server1 and server2 |
| CA-verified host identity | Each host presents a CA-signed host certificate (`HostCertificate`); clients trust only `@cert-authority` with strict checking | `ssh -v` shows `Host '...' is known and matches the ED25519-CERT host certificate` for all three hosts, with no fingerprint stored anywhere; checked on every CI run |
| Automated host-certificate renewal | Ansible re-signs a host's certificate when it is missing or has under 7 days left, then reloads sshd | A forced renewal ran `changed` on all three hosts; the serial presented **on the wire** changed (table below) while each host's key fingerprint stayed the same; strict checking still passed |
| Automation is attributable | The control node authenticates with its own CA-signed certificate, key ID `ansible-control` | Server logs show `ID ansible-control` for automation logins, distinct from the key ID of human logins |
| Short-lived credentials | User certs: 1h (human), 8h (control); host certs: 30 days | Validity window visible with `ssh-keygen -Lf` |
| Expired certificates are rejected | sshd checks the validity window locally | CI issues a short-lived certificate, waits past its expiry and confirms the login is refused with `Permission denied`; the check was also confirmed to go red when the wait is removed |
| Certificates from other CAs are rejected | sshd trusts only the user CA in `TrustedUserCAKeys` | CI signs a key with a throwaway rogue CA (principal `admin`) and confirms the login is refused |
| Principals are enforced | A certificate is only valid for the principals it was signed with | CI signs a key with a genuine CA certificate for principal `notadmin` and confirms the login is refused |
| A key alone is not enough | No static keys are trusted; a certificate is required | CI presents a valid, unsigned key and confirms the login is refused |

### Renewal evidence

| Host | Serial before | Serial after | Valid until |
|---|---|---|---|
| bastion | `13764757154211677940` | `326664126737054182` | 2026-11-06 |
| server1 | `15161208515906204963` | `13490649992394516742` | 2026-11-06 |
| server2 | `13613987186099281307` | `5242324572890086345` | 2026-11-06 |

Each "after" serial was read from the certificate a client actually received during an SSH handshake (`ssh -v ... | grep "Server host certificate"`), not just from the file on disk, which proves the running sshd reloaded the new certificate.

## Ansible automation

`control/site.yml` has two plays.

**Play 1: prepare the control node (`localhost`, local connection):**
1. Trust the CA's HTTPS API: `step ca bootstrap` with the pinned root fingerprint (guarded by `creates:` so it runs once).
2. Check the CA answers (`step ca health`).
3. Make sure `~/.ssh` exists.
4. Create the control node's ed25519 key pair (once).
5. Issue a fresh 8-hour user certificate for it (key ID `ansible-control`, principal `admin`).

**Play 2: issue and renew host certificates (`ssh_hosts`, through the bastion):**
1. Read each host's current certificate (`ssh-keygen -L`).
2. Decide whether a renewal is due: no certificate, fewer than 7 days left, or `force_renew=true`.
3. Fetch the host's public key to the control node.
4. Sign it with the CA (`step ssh certificate --sign --host`) with the right principals per host. `bastion` also gets `localhost`, because that is the name the developer's own client uses.
5. Install the certificate on the host and reload sshd.

Run it from inside the control container:

```bash
docker exec -it control bash
cd /work
ansible-playbook -i inventory.yml site.yml --ask-vault-pass
# force a renewal to exercise the full path:
ansible-playbook -i inventory.yml site.yml --ask-vault-pass -e force_renew=true
```

Inside Docker, the control node connects to the bastion on port 22 (not the published 2222). `known_hosts` lists `bastion`, `server1` and `server2`, and the host certificates include those names as principals, so strict checking passes with no extra signing.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request to `main` and can also be started by hand (`workflow_dispatch`). It is one job on a blank runner: it builds a throwaway copy of the entire lab, tests it, and tears it down. Nothing from the real lab (CA volume, keys, vault) is used or needed.

### What the pipeline does

1. **Start a fresh CA.** `docker-compose.ci.yml` overrides the CA's init password with a throwaway value (`CI_CA_PASSWORD`, defined once in the workflow's `env:`), so the secret is known in advance.
2. **Allow short-lived certificates on the CI CA** by lowering the `admin` provisioner's minimum SSH certificate duration, so expiry can be tested in seconds instead of minutes.
3. **Export the CA's public material.** Copy the user CA and host CA public keys into `ca/`, regenerate `ca/known_hosts`, and capture the root fingerprint. This happens before the build because the Dockerfile bakes `user_ca.pub` into the image.
4. **Write plain `group_vars`** with the CI CA's fingerprint and password, replacing the Vault-encrypted files on the runner only.
5. **Build and start the hosts and the control node**, then wait until each sshd logs `Server listening`.
6. **Run the playbook (bootstrap).** On a fresh lab no host has a certificate yet, so strict host checking cannot succeed on the very first connection. This one run uses `ssh_config_bootstrap`, a complete copy of the control config with `StrictHostKeyChecking accept-new` and a scratch known-hosts file, passed as a full config file so both `ProxyJump` hops see the same settings. The play issues and installs every host certificate.
7. **Run the playbook again with the normal strict config.** This only succeeds if the hosts now present CA-signed certificates the control node accepts.
8. **Issue a test user certificate** (key ID `ci-user`, principal `admin`, 1h) for a fresh key.
9. **Run the positive tests, then the negative tests** (below).
10. **Always:** on failure, dump every container's logs; then `docker compose down -v`.

### Positive tests (`ci/positive-tests.sh`)

| Check | What it proves |
|---|---|
| `ssh <host> hostname` on bastion, server1, server2 matches `hostname` run inside that container | The login reached the machine that was meant, not just any machine |
| Each host's log contains `Accepted publickey for admin ... ED25519-CERT ... ID ci-user` | The login used the certificate, not a static key |
| `ssh -v` reports `known and matches the ED25519-CERT host certificate` for each host | The client verified host identity through the host CA |
| `/home/admin/.ssh` does not exist on any host | No static keys are present |

### Negative tests (`ci/negative-tests.sh`)

Each case is built as its own complete ssh config so both `ProxyJump` hops use the same identity. A case only passes if the login fails **and** the output contains `Permission denied`, so a typo or a timeout cannot make a negative test pass for the wrong reason.

| Case | Expected result |
|---|---|
| Valid key, no certificate | Refused |
| Certificate signed by a rogue CA (principal `admin`) | Refused |
| Certificate from the real CA, principal `notadmin` | Refused |
| Password authentication (public-key auth disabled on the client) | Refused |
| Expired certificate (issued with a short validity, used after it lapses) | Refused |
| Direct connection to server1's container IP from the runner | Unreachable (times out) |

### How CI differs from the lab, on purpose

- **A throwaway CA with a known password.** The lab's provisioner password is random and shown once; CI needs to know it in advance. The CI CA is destroyed at the end of every run.
- **A bootstrap run with relaxed host checking.** Only the first playbook run uses `accept-new`; the second run and every test use strict checking against the CA.
- **A lowered minimum certificate duration** on the CI CA only, so the expiry test takes seconds. The lab CA is unchanged.

## The starting point vs. where it ended up

This project deliberately started with the naive version of each piece, then hardened it, so the "before" is preserved as a teaching artifact:

- **Auth:** `root:password` via `chpasswd` → key-only login as a non-root `admin` user → **CA-signed, short-lived user certificates with no static keys on any host**.
- **Host keys:** all three containers silently shared identical host keys (baked in at image-build time by the `openssh-server` post-install script) → each container generates and persists its own unique identity → **each identity is vouched for by a host certificate**.
- **Host verification:** trust-on-first-use fingerprint prompts → a single `@cert-authority` line with strict checking.
- **Certificate issuance:** a sequence of hand-typed `docker cp` / `docker exec` commands → **an idempotent Ansible playbook** that talks to the CA's API from a dedicated control node.
- **Network reachability:** initial Compose file had no isolation → `server1`/`server2` verified unreachable except through the bastion.
- **Jump auth:** initially failed with a password prompt for the bastion hop, because `-i` on the command line doesn't propagate to the hidden first-hop connection `-J` creates → solved with a per-host `ssh_config` (`IdentityFile`, `CertificateFile`, `ProxyJump`) plus `ssh-agent` to avoid repeated passphrase prompts.
- **Verification:** manual command checks → **a GitHub Actions pipeline** that rebuilds the lab from nothing and asserts both what must work and what must be refused.

## Key design decisions

- **One image for the SSH hosts, separate images for the CA and control node.** Topology defines a machine's role among the SSH hosts; the CA and the control node are different kinds of machine.
- **Host keys generated at container start, not build time.** Keeps the image free of key material and gives every container its own identity the moment it's created.
- **Host keys persisted via named volumes, scoped narrowly.** Only `/etc/ssh/host_keys` is volume-backed, so `sshd_config` and the hardening drop-in still come fresh from the image on every rebuild. Mounting all of `/etc/ssh` was rejected because stale config could silently survive a rebuild.
- **Host certificates live in the volumes, not the image.** The image is shared by all three hosts, so a baked-in certificate would be identical everywhere. A certificate is also bound to one exact host key, which is why persistent host keys matter: if a volume were deleted, the key would regenerate and its certificate would no longer match.
- **Two separate CA keys (user and host).** Trusting one does not imply trusting the other.
- **`ProxyJump` over `sshd`-level forwarding tricks.** The bastion is a relay, never a holder of credentials. User certificates must keep `permit-port-forwarding`, because `ProxyJump` relies on it.
- **A project-local `known_hosts`** (`ca/known_hosts`), so the CA line is the *only* host trust a client has. A success can then only be explained by the CA, never by an old fingerprint.
- **The control node talks to the CA over its HTTPS API, not through `docker exec`.** The CA image has no Python (so Ansible modules can't run on it), and driving it with `docker exec` would mean mounting the Docker socket into the control container, which is root-equivalent on the host and would bypass every network boundary. The `step` CLI in the control container signs over `https://ca:9000` instead, trusting the CA via `step ca bootstrap` and a pinned root fingerprint.
- **Control sits on `public` and `ca`, not on `private`.** It reaches the servers through the bastion (`ProxyJump`), so the `private` network keeps exactly one way in. Joining `private` would have made the control node a second bridge into it.
- **Ansible is a client of the system it manages.** It logs in with a CA-signed certificate like any user, so automation exercises the same trust path as humans and is distinguishable in logs by its key ID.
- **A dedicated, passphrase-less key for the control node, with an 8-hour certificate.** The key never leaves the control container. An unencrypted key is acceptable only because the credential is short-lived: a stolen key plus certificate is useless after the certificate expires. The control play issues a fresh certificate on every run.
- **Renewal is conditional, with a 7-day threshold.** Host certificates last 30 days; the playbook reads each host's current certificate and only re-signs when it is missing or close to expiry. A `force_renew` variable exercises the renewal path on demand.
- **Secrets in Ansible Vault.** The CA provisioner password lives in an encrypted `vault.yml`, is passed to `step` over stdin, and every task that touches it has `no_log: true`.
- **Tests verify the mechanism, not just the outcome.** The positive tests read the server's `Accepted ... ED25519-CERT` log line and the client's host-certificate message; the negative tests require `Permission denied` specifically.
- **CI is hermetic.** It never reads the lab's CA, keys or vault. Everything it needs is created on the runner and destroyed afterwards.

## Problems encountered and how they were solved

| Problem | Root cause | Fix |
|---|---|---|
| `failed to decrypt JWE: invalid password` when signing (several times, in different phases) | Two different secrets exist: `/home/step/secrets/password` encrypts the CA's own keys, while the **provisioner password** authorizes signing. Separately, in CI the password the script sent differed from the one the CA was initialized with | Use the provisioner password; keep the vault *password* (which unlocks `vault.yml`) conceptually separate from the secret stored *inside* it. In CI, define the password once (`CI_CA_PASSWORD`) and have the compose override, the generated `group_vars` and every signing step read it |
| `error allocating terminal: open /dev/tty` during signing in CI | A misspelled variable name expanded to nothing, so the password file was empty and `step` fell back to prompting on a terminal that does not exist on a runner | Correct the variable name; a `${VAR:?message}` guard turns an empty variable into a readable failure |
| `requested duration is less than minimum accepted duration for selected provisioner` | The CA's `admin` provisioner refuses SSH certificates shorter than 5 minutes, so a 1-minute certificate for the expiry test was rejected | Lower the minimum on the throwaway CI CA only |
| Login succeeded but the log said plain `ED25519`, not `ED25519-CERT` | The static `authorized_keys` entry was still valid, so the client's first offer was accepted before the certificate was tried | Remove the static key's ability to log in and read the server-side `Accepted` line to see which method actually worked |
| Client not offering the certificate | Relying on OpenSSH auto-discovering `<key>-cert.pub` | Explicit `CertificateFile` in every `ssh_config` block (the `ProxyJump` first hop is a separate connection) |
| Rebuild "worked" but `authorized_keys.bak` was still present | Compose only recreates containers when the image changes; the edit hadn't taken effect | Verify the change landed, then `docker compose up -d --build --force-recreate` |
| `ssh server1 true` appeared to do nothing | Not a fault: `true` runs, exits successfully and disconnects, so success is silent | Judge by the server's `Accepted` log line, or run `ssh server1 hostname` |
| `open server1_host-cert.pub: permission denied` while signing | `docker cp` creates files as root; inside the container `step` runs as an unprivileged user | Sign from a scratch directory created inside the container |
| Bastion crash-looping after adding the host certificate | Typo in `hardening.conf`: `HostCertificates` instead of the singular `HostCertificate`. sshd refuses to start on an unknown option | Correct the directive; check `docker compose logs` first when a container restarts |
| Noisy `Could not save your private key in /etc/ssh/host_keys/etc/ssh/...` on every start | A stray `ssh-keygen -A -f /etc/ssh/host_keys` line in the entrypoint | Removed the line; the key-generation loop already does the job |
| Repeated key passphrase prompts (one per `ProxyJump` hop), and `Could not open a connection to your authentication agent` | The agent was empty, never started in that terminal, or its cache lifetime (matched to the certificate's validity) had expired | `ssh-agent` + `ssh-add keys/key`, once per shell session |
| Git Bash mangled `docker exec ... /etc/...` into `C:/.../Git/etc/...` | MSYS path conversion rewrites arguments that start with `/` | `MSYS_NO_PATHCONV=1` before the command, or run commands from a shell inside the container |
| Play 2 reported `Could not match supplied host pattern: ssh_hosts` | The playbook was run without `-i inventory.yml`, so only the implicit `localhost` existed | Always pass `-i inventory.yml` |
| `Missing sudo password` on every host | `admin` had no sudo rights, and Ansible needs root to write into `/etc/ssh/host_keys` and reload sshd | Passwordless sudo for `admin` in the image |
| Personal login failed after the Ansible work, with a stale host-certificate check and no further hops | The human user certificate (1h) had long expired, and no static key remains as a fallback | Re-issue it; this is expiry working as designed |

A common thread: **verify the mechanism, not just the outcome.** "The login worked" was true in several cases where the certificate wasn't involved, and "the task reported `changed`" doesn't prove sshd is serving the new certificate.

## Reproducing / testing this yourself

Bootstrap order matters: the SSH images copy in the CA's public user key, and the control play needs the CA's root fingerprint, so the CA has to exist first.

```bash
# 1. Start the CA alone; first start initializes it (including the two SSH CA keys)
docker compose up -d ca
docker logs ca 2>&1 | grep -i password                 # the provisioner password (shown once)
docker exec ca step certificate fingerprint /home/step/certs/root_ca.crt   # root fingerprint

# 2. Export the CA's PUBLIC keys into the project (safe to commit)
mkdir -p ca
docker cp ca:/home/step/certs/ssh_user_ca_key.pub ca/user_ca.pub
docker cp ca:/home/step/certs/ssh_host_ca_key.pub ca/host_ca.pub
echo "@cert-authority [localhost]:2222,bastion,server1,server2 $(cat ca/host_ca.pub)" > ca/known_hosts

# 3. Put the root fingerprint in control/group_vars/all/vars.yml and the provisioner
#    password in the encrypted vault file
ansible-vault create control/group_vars/all/vault.yml   # vault_ca_provisioner_password: "..."

# 4. Build and start everything
docker compose up -d --build
```

Issue the SSH hosts' initial host certificates by running the playbook with `-e force_renew=true` (a host with no certificate is also treated as due), then add the `HostCertificate` line to `hardening.conf` and recreate the hosts. A human user certificate for your own key is issued the same way the control node's is:

```bash
docker cp keys/key.pub ca:/tmp/key.pub
docker exec -it ca sh
#   step ssh certificate --sign --force --provisioner admin \
#       --principal admin --not-after 1h tanish /tmp/key.pub
#   exit
docker cp ca:/tmp/key-cert.pub keys/key-cert.pub
eval "$(ssh-agent -s)" && ssh-add keys/key
```

Verify:

```bash
# Hardening is enforced, not just written
docker exec bastion sshd -T | grep -iE "passwordauthentication|permitrootlogin|trustedusercakeys|hostcertificate"

# Isolation: this should time out
ssh admin@$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' server1)

# Host certificates are what the client is trusting, and the serials are the current ones
ssh -v -F ssh_config server1 true 2>&1 | grep -iE "Server host certificate|known and matches"

# No static keys exist, yet login works, and the server log names the certificate used
MSYS_NO_PATHCONV=1 docker exec bastion ls /home/admin/.ssh     # expect: No such file or directory
ssh -F ssh_config server1 true
docker logs server1 2>&1 | grep Accepted | tail -1             # ...ED25519-CERT... ID <key id> ...
```

Note that `ssh server1 true` runs a no-op command and returns silently on success; the server's `Accepted` log line is the evidence, or use `ssh -F ssh_config server1 hostname` for visible output. Under Git Bash, prefix `docker exec` commands that take absolute paths with `MSYS_NO_PATHCONV=1`.

The automated version of all of this is the CI pipeline described above: `ci/positive-tests.sh` and `ci/negative-tests.sh` run from the repository root and expect the stack to be up and the test identity in `keys/`.

## Files

- `docker-compose.yml`: services (`bastion`, `server1`, `server2`, `ca`, `control`), networks (`public`, `private [internal]`, `ca`), named volumes for host keys and CA state (`ca_data`); `control` mounts `./control` at `/work` and `./ca` read-only at `/ca`
- `docker-compose.ci.yml`: CI-only override that sets the throwaway CA init password from `CI_CA_PASSWORD`
- `Dockerfile`: shared SSH-host image: Ubuntu 24.04, openssh-server, Python 3 (for Ansible modules), non-root `admin` user with passwordless sudo, and the CA's public user key at `/etc/ssh/user_ca.pub`. No `authorized_keys` is baked in
- `host_keygen.sh`: entrypoint: generates missing host keys, then `exec`s sshd with `-e` so logs reach `docker logs`
- `hardening.conf`: sshd drop-in: `PasswordAuthentication no`, `PermitRootLogin no`, `HostKey` paths, `TrustedUserCAKeys`, `HostCertificate`
- `ssh_config`: your own client config: `bastion` and `server1`/`server2` (via `ProxyJump`) with `IdentityFile` and `CertificateFile`; `Host *` sets `UserKnownHostsFile ca/known_hosts` and `StrictHostKeyChecking yes`
- `ca/user_ca.pub`, `ca/host_ca.pub`, `ca/known_hosts`: public CA keys and the client trust line (safe to commit)
- `control/dockerfile`: control image: Ansible, `community.crypto`, the `step` CLI and `openssh-client`
- `control/site.yml`: the two plays described above
- `control/inventory.yml`: the `ssh_hosts` group with per-host certificate principals (`bastion` also gets `localhost`)
- `control/ssh_config_control`: the control node's SSH config: identity and certificate, `ProxyJump` via the bastion, strict host checking against `/ca/known_hosts`
- `control/group_vars/all/vars.yml`, `control/group_vars/all/vault.yml`: Ansible variables, encrypted with Ansible Vault; the vault holds the provisioner password
- `ci/positive-tests.sh`, `ci/negative-tests.sh`: the assertions run by CI
- `.github/workflows/ci.yml`: the pipeline
- `keys/key`: your private key (git-ignored). `keys/key.pub` is signed by the CA to produce `keys/key-cert.pub`

**Never commit:** the `ca_data` volume contents, the CA provisioner password in plaintext, any vault password file, or any private key.