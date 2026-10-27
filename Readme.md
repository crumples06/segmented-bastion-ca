# Bastion Access Project

![CI](https://github.com/crumples06/segmented-bastion-ca/actions/workflows/ci.yml/badge.svg)

A Docker Compose lab demonstrating a hardened SSH bastion (jump host) pattern: a single, controlled entry point in front of a network of otherwise unreachable machines. Authentication and host identity are both handled by a private SSH certificate authority ([step-ca](https://smallstep.com/docs/step-ca/)), host certificates are issued and renewed by an Ansible playbook, and a GitHub Actions pipeline rebuilds the whole lab from scratch and verifies the security properties on every pull request.

## Quick start

```bash
git clone https://github.com/crumples06/segmented-bastion-ca.git
cd segmented-bastion-ca

bash scripts/bootstrap.sh                      # CA, public keys, hosts, host certificates, strict-checked rerun
bash scripts/login.sh                          # issue your own 1h user certificate
eval "$(ssh-agent -s)" && ssh-add keys/key     # once per shell session
ssh -F ssh_config server1 hostname             # reaches server1 through the bastion

bash scripts/reset.sh                          # tear everything down and delete generated files
```

`bootstrap.sh` is safe to rerun. A first run takes a minute or two, mostly waiting for the CA to initialise.

**Prerequisites:** Docker with Compose v2, git, an OpenSSH client, `openssl`, and ports `2222` and `9000` free on the host.

**On Windows (Git Bash):**
- `.gitattributes` forces LF line endings on `*.sh`. `host_keygen.sh` is the container entrypoint, and CRLF endings make it fail with `bad interpreter`.
- `bootstrap.sh` and `login.sh` set `MSYS_NO_PATHCONV=1`, because Git Bash otherwise rewrites arguments that start with `/` (for example `/home/step/...`) into Windows paths. Do the same for your own `docker exec` commands that take absolute paths.

Nothing lab-specific is committed. The CA's public keys, the Ansible variables, the vault and your keys are all generated on your machine and gitignored, so a fresh clone cannot succeed by accident on someone else's CA.

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
| **User CA** | Login certificates ("this key may log in as `admin`") | The servers, via `TrustedUserCAKeys` | `hardening.conf`; the public key is bind-mounted read-only at `/etc/ssh/user_ca.pub` |
| **Host CA** | Host certificates ("this machine really is `server1`") | Clients, via `@cert-authority` | `ca/known_hosts` |

Everything is verified **offline**. Servers and clients never call the CA at login time, so certificate expiry takes the place of revocation: a short-lived user certificate is useless once its window closes.

Clients never store a per-server fingerprint. `ca/known_hosts` holds a single line trusting the host CA for the lab's host names, and `StrictHostKeyChecking yes` means anything the CA hasn't vouched for is refused with no prompt.

The CA also has an **X.509 root** that protects its HTTPS API. That is a third, unrelated trust anchor: the `step` CLI uses it (via `step ca bootstrap`) to trust the CA's API, and it plays no part in SSH verification.

## What "hardened" means here, concretely

| Property | How it's enforced | How it was verified |
|---|---|---|
| Network isolation | `private` is `internal: true`; only `bastion` bridges `public` and `private`; `ca` has its own network | By hand, direct `ssh` to server1's container IP **times out** (packets dropped, not rejected); CI asserts on every run that the direct connection fails |
| Key-only authentication | `PasswordAuthentication no` in `sshd_config.d/hardening.conf` | Forcing `PubkeyAuthentication=no` from the client returns `Permission denied`, not a password prompt; checked on every CI run |
| No root login | `PermitRootLogin no` in the same drop-in | `sshd -T` showing the resolved (not just written) config |
| Unique host identity per container | Host keys deleted at build time, generated at container start via an entrypoint script | `ssh-keygen -lf` fingerprints differ across bastion/server1/server2 |
| Stable host identity across restarts | Host keys in a per-container named volume at `/etc/ssh/host_keys`, with `HostKey` lines pointing sshd at it | Fingerprint identical before/after `docker restart`, after `docker compose down && up`, **and** across a certificate renewal |
| Bastion never holds your private key | `ProxyJump`: the client authenticates both hops itself; the bastion only relays encrypted bytes | Standard OpenSSH behavior; no private key material is copied into any container |
| Certificate-only login | No `authorized_keys` exists in the image; sshd trusts only the CA via `TrustedUserCAKeys` | `/home/admin/.ssh` is absent in every container (checked by hand, see "Verify" below), yet login works; the server log shows `Accepted publickey for admin ... ED25519-CERT ... ID <key id> (serial ...) CA ECDSA SHA256:...` on bastion, server1 and server2 |
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

These were recorded on the original lab. Each "after" serial was read from the certificate a client actually received during an SSH handshake (`ssh -v ... | grep "Server host certificate"`), not just from the file on disk, which proves the running sshd reloaded the new certificate.

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

`scripts/bootstrap.sh` runs this for you. To run it by hand later, for example to force a renewal:

```bash
docker compose exec control ansible-playbook -i inventory.yml site.yml
# force a renewal to exercise the full path:
docker compose exec control ansible-playbook -i inventory.yml site.yml -e force_renew=true
```

No vault flag is needed: `bootstrap.sh` writes the vault password to `/root/.vault_pass` inside the control container, and `ANSIBLE_VAULT_PASSWORD_FILE` in `docker-compose.yml` points Ansible at it. The password file lives inside the container, not on the bind mount, because Windows bind mounts expose files as executable and Ansible would try to run it as a script. If the control container is recreated the file is gone; rerun `bash scripts/bootstrap.sh` to restore it.

Inside Docker, the control node connects to the bastion on port 22 (not the published 2222). `ca/known_hosts` trusts the host CA for `[localhost]:2222` (the developer's client), `bastion`, `server1` and `server2`, and the host certificates include the matching names as principals, so strict checking passes with no extra signing.

## Bootstrap and automation scripts

| Script | What it does |
|---|---|
| `scripts/bootstrap.sh` | Builds a working lab from nothing: secrets, CA, public keys, Ansible variables, vault, containers, host certificates, and a strict-checked verification run. Safe to rerun |
| `scripts/login.sh` | Issues a 1-hour user certificate for `keys/key` (generated if missing) and tries to load the key into ssh-agent; if no agent is running it prints the commands to start one. `KEY_ID=<id>` sets the certificate's key ID (default `me`) |
| `scripts/reset.sh` | `docker compose down -v`, then deletes `.env` and the generated files (see "Resetting") |

### Under the hood: what `bootstrap.sh` does

The order matters, because each stage needs the output of the one before it.

1. **Generate secrets once.** If `.env` is missing, write a random CA provisioner password (`CA_PASSWORD`) and a random vault password (`VAULT_PASSWORD`) into it. Compose reads `CA_PASSWORD` and passes it to the CA as `DOCKER_STEPCA_INIT_PASSWORD`, so the password is known in advance instead of being printed once in the CA's logs.
2. **Start the CA alone** and wait for its healthcheck. Everything else depends on its output.
3. **Export the CA's public material:** the user CA and host CA public keys into `ca/`, a single `@cert-authority` line into `ca/known_hosts`, and the X.509 root fingerprint into a variable. Only public keys leave the CA. This must happen before the SSH hosts start, because `ca/user_ca.pub` is bind-mounted into them and Docker would otherwise create a directory in its place.
4. **Generate the Ansible variables:** `vars.yml` (fingerprint, certificate path, and a reference to the vaulted password) and a plaintext `vault.yml` holding the provisioner password.
5. **Build and start everything else.** Each host generates its own keys into its named volume on first start.
6. **Encrypt the vault.** The vault password goes into `/root/.vault_pass` inside the control container, then `ansible-vault encrypt` runs on `vault.yml`.
7. **Bootstrap run, only if needed.** The script loops over `bastion server1 server2` and checks whether each host already has a certificate. If any host has none, strict host checking cannot succeed, so this one run uses a generated `ssh_config_bootstrap` with `StrictHostKeyChecking accept-new` and a scratch known-hosts file. It is passed as a full config so both `ProxyJump` hops see the same settings. On a rerun where every host already has a certificate, this step is skipped.
8. **Strict run, always.** The normal playbook run with strict checking succeeds only if the hosts now present CA-signed certificates the control node accepts. This is the proof that step 7 worked.

Manual equivalent, if you want to see each piece: the CA is started with `docker compose up -d ca --wait`; the public keys come from `docker compose cp ca:/home/step/certs/ssh_user_ca_key.pub ca/user_ca.pub` (and `ssh_host_ca_key.pub`); the fingerprint is `docker compose exec -T ca step certificate fingerprint /home/step/certs/root_ca.crt`; a human certificate is signed with `step ssh certificate --sign --provisioner admin --principal admin --not-after 1h <key-id> <pubkey>` inside the CA container.

### Verify

Run these from the repository root, since `ssh_config` uses relative paths:

```bash
# Hardening is enforced, not just written
docker compose exec bastion sshd -T | grep -iE "passwordauthentication|permitrootlogin|trustedusercakeys|hostcertificate"

# Isolation: this should time out
ssh admin@$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' server1)

# Host certificates are what the client is trusting
ssh -v -F ssh_config server1 true 2>&1 | grep -iE "Server host certificate|known and matches"

# No static keys exist, yet login works, and the server log names the certificate used
MSYS_NO_PATHCONV=1 docker compose exec bastion ls /home/admin/.ssh     # expect: No such file or directory
ssh -F ssh_config server1 hostname
docker logs server1 2>&1 | grep Accepted | tail -1                     # ...ED25519-CERT... ID me ...
```

`ssh server1 true` runs a no-op and returns silently on success. The server's `Accepted` log line is the evidence, or use `hostname` for visible output.

### Resetting

`bash scripts/reset.sh` removes the containers, networks and volumes (CA state, host keys, host certificates) and deletes `.env`, `ca/user_ca.pub`, `ca/host_ca.pub`, `ca/known_hosts`, the generated vars and vault, the bootstrap config and `keys/key*`. A new CA means a new fingerprint, password and public keys, so everything is regenerated by the next `bootstrap.sh`.

Compose must parse `docker-compose.yml` for every command, including `down`, and the CA service requires `CA_PASSWORD`. `reset.sh` passes a dummy value for the teardown for that reason. If you run `docker compose down -v` yourself without a `.env`, use `CA_PASSWORD=unused docker compose down -v`.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request to `main` and can also be started by hand (`workflow_dispatch`). It is one job on a blank runner: it builds a throwaway copy of the entire lab with the same `bootstrap.sh` a human runs, tests it, and tears it down. Nothing from your own lab (CA volume, keys, vault) is used or needed.

### What the pipeline does

1. **Write `.env`** with a throwaway CA password (`CI_CA_PASSWORD`, defined once in the workflow's `env:`), so the secret is known in advance.
2. **Start the CA** and wait for it to be healthy.
3. **Allow short-lived certificates on the CI CA** by lowering the `admin` provisioner's minimum SSH certificate duration, so expiry can be tested in seconds instead of minutes.
4. **Run `scripts/bootstrap.sh`.** This is the whole lab setup: public keys, `known_hosts`, generated variables, vault, containers, the relaxed bootstrap run that issues every host certificate, and the strict run that proves them.
5. **Issue a test user certificate** with `KEY_ID=ci-user bash scripts/login.sh` (principal `admin`, 1h).
6. **Run the positive tests, then the negative tests** (below).
7. **Always:** on failure, dump every container's logs; then `docker compose down -v`.

Because CI runs the same script as a person following the Quick start, the documented path and the tested path cannot drift apart.

### Positive tests (`ci/positive-tests.sh`)

| Check | What it proves |
|---|---|
| `ssh <host> hostname` on bastion, server1, server2 matches `hostname` run inside that container | The login reached the machine that was meant, not just any machine |
| Each host's log contains `Accepted publickey for admin ... ED25519-CERT ... ID ci-user` | The login used the certificate, not a static key |
| `ssh -v` reports `known and matches the ED25519-CERT host certificate` for each host | The client verified host identity through the host CA |

### Negative tests (`ci/negative-tests.sh`)

Each login case is built as its own complete ssh config so both `ProxyJump` hops use the same identity. Cases 1-5 only pass if the login fails **and** the output contains `Permission denied`, so a typo or a timeout cannot make them pass for the wrong reason. The isolation case (6) is different: it passes if the direct connection to server1's container IP fails for any reason, and it does not check that the failure was a timeout.

| Case | Expected result |
|---|---|
| 1. Valid key, no certificate | Refused (`Permission denied`) |
| 2. Certificate signed by a rogue CA (principal `admin`) | Refused (`Permission denied`) |
| 3. Certificate from the real CA, principal `notadmin` | Refused (`Permission denied`) |
| 4. Password authentication (public-key auth disabled on the client) | Refused (`Permission denied`) |
| 5. Expired certificate (issued with a short validity, used after it lapses) | Refused (`Permission denied`) |
| 6. Direct connection to server1's container IP from the runner | Connection fails (a timeout when run by hand) |

### Running the tests against your own lab

Both scripts run from the repository root and expect the stack to be up. They were written for CI, so against your lab:

- The positive tests grep for key ID `ci-user`, so issue your certificate with `KEY_ID=ci-user bash scripts/login.sh` first.
- `negative-tests.sh` signs extra certificates through the CA, so it needs the CA password. It reads `CI_CA_PASSWORD` if set and otherwise falls back to `CA_PASSWORD` from `.env`.
- The expired-certificate case signs a 1-minute certificate, which the lab CA rejects because its minimum is 5 minutes. That case only works on the CI CA.

### How CI differs from the lab, on purpose

- **A known CA password.** Locally the password is random and kept in `.env`; CI sets its own throwaway value up front. The CI CA is destroyed at the end of every run.
- **A lowered minimum certificate duration** on the CI CA only, so the expiry test takes seconds. The lab CA is unchanged.
- **Nothing else.** The relaxed `accept-new` bootstrap run, the vault, the generated variables and the strict verification run are the same code path in both places.

## The starting point vs. where it ended up

This project deliberately started with the naive version of each piece, then hardened it, so the "before" is preserved as a teaching artifact:

- **Auth:** `root:password` via `chpasswd` → key-only login as a non-root `admin` user → **CA-signed, short-lived user certificates with no static keys on any host**.
- **Host keys:** all three containers silently shared identical host keys (baked in at image-build time by the `openssh-server` post-install script) → each container generates and persists its own unique identity → **each identity is vouched for by a host certificate**.
- **Host verification:** trust-on-first-use fingerprint prompts → a single `@cert-authority` line with strict checking.
- **Certificate issuance:** a sequence of hand-typed `docker cp` / `docker exec` commands → **an idempotent Ansible playbook** that talks to the CA's API from a dedicated control node.
- **Network reachability:** initial Compose file had no isolation → `server1`/`server2` verified unreachable except through the bastion.
- **Jump auth:** initially failed with a password prompt for the bastion hop, because `-i` on the command line doesn't propagate to the hidden first-hop connection `-J` creates → solved with a per-host `ssh_config` (`IdentityFile`, `CertificateFile`, `ProxyJump`) plus `ssh-agent` to avoid repeated passphrase prompts.
- **Verification:** manual command checks → **a GitHub Actions pipeline** that rebuilds the lab from nothing and asserts both what must work and what must be refused.
- **Setup:** a ten-step manual procedure (scrape the CA password from logs, copy keys by hand, type the vault password, run the playbook twice with different configs) → **one idempotent `bootstrap.sh`** that the CI pipeline also runs, so the path users follow is the path that is tested.

## Key design decisions

- **One image for the SSH hosts, separate images for the CA and control node.** Topology defines a machine's role among the SSH hosts; the CA and the control node are different kinds of machine.
- **Host keys generated at container start, not build time.** Keeps the image free of key material and gives every container its own identity the moment it's created.
- **Host keys persisted via named volumes, scoped narrowly.** Only `/etc/ssh/host_keys` is volume-backed, so `sshd_config` and the hardening drop-in still come fresh from the image on every rebuild. Mounting all of `/etc/ssh` was rejected because stale config could silently survive a rebuild.
- **Host certificates live in the volumes, not the image.** The image is shared by all three hosts, so a baked-in certificate would be identical everywhere. A certificate is bound to one exact host key, so the key and its certificate must live and die together: they are in the same volume, so deleting the volume removes both, and the next playbook run sees no certificate and issues a new one for the regenerated key.
- **The user CA's public key is bind-mounted, not baked into the image.** The image contains no lab-specific material, and a different CA no longer needs an image rebuild (recreate the containers so they pick up the new file). The file must exist before the hosts start, which is why `bootstrap.sh` exports it first. Ansible cannot deliver this file: it logs in with a certificate the servers can only accept once they already trust the user CA, so Compose provisions it.
- **Two separate CA keys (user and host).** Trusting one does not imply trusting the other.
- **`ProxyJump` over `sshd`-level forwarding tricks.** The bastion is a relay, never a holder of credentials. User certificates must keep `permit-port-forwarding`, because `ProxyJump` relies on it.
- **A project-local `known_hosts`** (`ca/known_hosts`), so the CA line is the *only* host trust a client has. A success can then only be explained by the CA, never by an old fingerprint.
- **The control node talks to the CA over its HTTPS API, not through `docker exec`.** The CA image has no Python (so Ansible modules can't run on it), and driving it with `docker exec` would mean mounting the Docker socket into the control container, which is root-equivalent on the host and would bypass every network boundary. The `step` CLI in the control container signs over `https://ca:9000` instead, trusting the CA via `step ca bootstrap` and a pinned root fingerprint.
- **Control sits on `public` and `ca`, not on `private`.** It reaches the servers through the bastion (`ProxyJump`), so the `private` network keeps exactly one way in. Joining `private` would have made the control node a second bridge into it.
- **Ansible is a client of the system it manages.** It logs in with a CA-signed certificate like any user, so automation exercises the same trust path as humans and is distinguishable in logs by its key ID.
- **A dedicated, passphrase-less key for the control node, with an 8-hour certificate.** The key never leaves the control container. An unencrypted key is acceptable only because the credential is short-lived: a stolen key plus certificate is useless after the certificate expires. The control play issues a fresh certificate on every run.
- **Renewal is conditional, with a 7-day threshold.** Host certificates last 30 days; the playbook reads each host's current certificate and only re-signs when it is missing or close to expiry. A `force_renew` variable exercises the renewal path on demand.
- **Secrets are generated, never typed or committed.** `.env` (gitignored) holds a random CA password and a random vault password. The provisioner password sits in an Ansible-Vault-encrypted `vault.yml`, is passed to `step` over stdin, and every task that touches it has `no_log: true`. `vars.yml` stays readable: it holds the public values (root fingerprint, certificate path) and refers to the vaulted password as `vault_ca_provisioner_password`.
- **Generated, lab-specific files are not committed.** `ca/`, `keys/`, `vars.yml`, `vault.yml` and the bootstrap SSH config belong to one CA instance, so they are gitignored and rebuilt by `bootstrap.sh`. A fresh clone has nothing stale to remove.
- **One bootstrap path for humans and CI.** The pipeline runs the same script as the Quick start, so the documented setup is the tested setup. Only the CA password and the minimum certificate duration differ.
- **Tests verify the mechanism, not just the outcome.** The positive tests read the server's `Accepted ... ED25519-CERT` log line and the client's host-certificate message; the login negative tests require `Permission denied` specifically.
- **CI is hermetic.** It never reads the lab's CA, keys or vault. Everything it needs is created on the runner and destroyed afterwards.

## Problems encountered and how they were solved

| Problem | Root cause | Fix |
|---|---|---|
| `failed to decrypt JWE: invalid password` when signing (several times, in different phases) | Two different secrets can exist: `/home/step/secrets/password` encrypts the CA's own keys, while the **provisioner password** authorizes signing. Separately, in CI the password the script sent differed from the one the CA was initialized with | Use the provisioner password; keep the vault *password* (which unlocks `vault.yml`) conceptually separate from the secret stored *inside* it. Now the CA is initialised from `CA_PASSWORD` in `.env`, and the vault, the generated variables and every signing step read that same value |
| `error allocating terminal: open /dev/tty` during signing in CI | A misspelled variable name expanded to nothing, so the password file was empty and `step` fell back to prompting on a terminal that does not exist on a runner | Correct the variable name; a `${VAR:?message}` guard turns an empty variable into a readable failure |
| `requested duration is less than minimum accepted duration for selected provisioner` | The CA's `admin` provisioner refuses SSH certificates shorter than 5 minutes, so a 1-minute certificate for the expiry test was rejected | Lower the minimum on the throwaway CI CA only |
| Login succeeded but the log said plain `ED25519`, not `ED25519-CERT` | The static `authorized_keys` entry was still valid, so the client's first offer was accepted before the certificate was tried | Remove the static key's ability to log in and read the server-side `Accepted` line to see which method actually worked |
| Client not offering the certificate | Relying on OpenSSH auto-discovering `<key>-cert.pub` | Explicit `CertificateFile` in every `ssh_config` block (the `ProxyJump` first hop is a separate connection) |
| Rebuild "worked" but `authorized_keys.bak` was still present | Compose only recreates containers when the image changes; the edit hadn't taken effect | Verify the change landed, then `docker compose up -d --build --force-recreate` |
| `ssh server1 true` appeared to do nothing | Not a fault: `true` runs, exits successfully and disconnects, so success is silent | Judge by the server's `Accepted` log line, or run `ssh server1 hostname` |
| `open server1_host-cert.pub: permission denied` while signing | `docker cp` creates files as root; inside the container `step` runs as an unprivileged user | Sign from a scratch directory created inside the container |
| Bastion crash-looping after adding the host certificate | Typo in `hardening.conf`: `HostCertificates` instead of the singular `HostCertificate`. sshd refuses to start on an unknown option | Correct the directive; check `docker compose logs` first when a container restarts |
| Noisy `Could not save your private key in /etc/ssh/host_keys/etc/ssh/...` on every start | A stray `ssh-keygen -A -f /etc/ssh/host_keys` line in the entrypoint | Removed the line; the key-generation loop already does the job |
| Repeated key passphrase prompts (one per `ProxyJump` hop), and `Could not open a connection to your authentication agent` | The agent was empty or never started in that terminal | `ssh-agent` + `ssh-add keys/key`, once per shell session |
| Git Bash mangled `docker exec ... /etc/...` into `C:/.../Git/etc/...` (and later `root_ca.crt` not found inside `bootstrap.sh`) | MSYS path conversion rewrites arguments that start with `/` | `export MSYS_NO_PATHCONV=1` at the top of the scripts, or the same prefix on a manual command |
| Play 2 reported `Could not match supplied host pattern: ssh_hosts` | The playbook was run without `-i inventory.yml`, so only the implicit `localhost` existed | Always pass `-i inventory.yml` |
| `Missing sudo password` on every host | `admin` had no sudo rights, and Ansible needs root to write into `/etc/ssh/host_keys` and reload sshd | Passwordless sudo for `admin` in the image |
| Personal login failed after the Ansible work, with a stale host-certificate check and no further hops | The human user certificate (1h) had long expired, and no static key remains as a fallback | Re-issue it with `scripts/login.sh`; this is expiry working as designed |
| `docker compose down -v` failed with `required variable CA_PASSWORD is missing a value` | Compose parses the whole file for every command, and the `${CA_PASSWORD:?...}` guard fails when `.env` is absent | `reset.sh` passes a dummy `CA_PASSWORD` for the teardown, then deletes `.env` |
| `ansible-vault` failed with `Exec format error` on the password file | Windows bind mounts expose files as executable, so Ansible runs the vault password file as a script | Keep the vault password file inside the container (`/root/.vault_pass`) and point `ANSIBLE_VAULT_PASSWORD_FILE` at it |
| `bootstrap.sh` always took the relaxed `accept-new` path and printed `unknown shorthand flag: 'T' in -T` | A typo (`docker comopse exec`) in the "does this host have a certificate yet?" check. The `|| need_bootstrap=1` after it treated the broken command as "no certificate", so the check always said yes, and the strict rerun still passed, which hid the fault | Fix the typo. Lesson: a check that fails for the wrong reason looks identical to one that fails for the right reason |
| After fixing the typo, `bootstrap.sh` *still* always took the relaxed path | The loop was `for h in bastion,server1,server2`: the commas made it one iteration over a single bogus service name, so `docker compose exec` failed and `need_bootstrap=1` was set every time. Again the strict rerun passed and hid it | Loop over space-separated names: `for h in bastion server1 server2`. The same lesson applies: a failing check is not the same as a check that found something |
| CI failed with `control/group_vars/all/vars.yml: No such file or directory` | After untracking the generated vars and vault, the directory was empty and git does not store empty directories, so it vanished from a fresh clone. It existed on the local machine, which is why only CI caught it | `mkdir -p control/group_vars/all` in `bootstrap.sh`, so the script creates what it needs |

A common thread: **verify the mechanism, not just the outcome.** "The login worked" was true in several cases where the certificate wasn't involved, "the task reported `changed`" doesn't prove sshd is serving the new certificate, and "the script finished" was true while one of its checks was silently broken (twice).

## Files

- `scripts/bootstrap.sh`, `scripts/login.sh`, `scripts/reset.sh`: the setup, login and teardown scripts described above
- `docker-compose.yml`: services (`bastion`, `server1`, `server2`, `ca`, `control`), networks (`public`, `private [internal]`, `ca`), named volumes for host keys and CA state (`ca_data`). The CA's init password comes from `CA_PASSWORD` in `.env`; the SSH hosts bind-mount `./ca/user_ca.pub` read-only; `control` mounts `./control` at `/work` and `./ca` read-only at `/ca`, and sets `ANSIBLE_VAULT_PASSWORD_FILE`
- `dockerfile`: shared SSH-host image: Ubuntu 24.04, openssh-server, Python 3 (for Ansible modules), non-root `admin` user with passwordless sudo. No `authorized_keys` and no CA key are baked in
- `host_keygen.sh`: entrypoint: generates missing host keys, then `exec`s sshd with `-e` so logs reach `docker logs`
- `hardening.conf`: sshd drop-in: `PasswordAuthentication no`, `PermitRootLogin no`, `HostKey` paths, `TrustedUserCAKeys`, `HostCertificate`
- `ssh_config`: your own client config: `bastion` and `server1`/`server2` (via `ProxyJump`) with `IdentityFile` and `CertificateFile`; `Host *` sets `UserKnownHostsFile ca/known_hosts` and `StrictHostKeyChecking yes`
- `control/dockerfile`: control image: Ansible, `community.crypto`, the `step` CLI and OpenSSH
- `control/site.yml`: the two plays described above
- `control/inventory.yml`: the `ssh_hosts` group with per-host certificate principals (`bastion` also gets `localhost`)
- `control/ssh_config_control`: the control node's SSH config: identity and certificate, `ProxyJump` via the bastion, strict host checking against `/ca/known_hosts`
- `ci/positive-tests.sh`, `ci/negative-tests.sh`: the assertions run by CI
- `.github/workflows/ci.yml`: the pipeline
- `.gitattributes`: forces LF line endings on shell scripts

**Generated by `bootstrap.sh` and `login.sh` (gitignored, never committed):**

- `.env`: the CA provisioner password and the vault password
- `ca/user_ca.pub`, `ca/host_ca.pub`, `ca/known_hosts`: the lab CA's public keys and the client trust line (public, but specific to one CA instance)
- `control/group_vars/all/vars.yml`, `control/group_vars/all/vault.yml`: Ansible variables; the vault holds the provisioner password and is encrypted with Ansible Vault
- `control/ssh_config_bootstrap`: the relaxed SSH config for the first playbook run
- `keys/key`, `keys/key.pub`, `keys/key-cert.pub`: your private key, its public half, and the CA-signed certificate

**Never commit:** `.env`, the `ca_data` volume contents, the CA provisioner password in plaintext, any vault password file, or any private key.

## License

MIT. See `LICENSE`.