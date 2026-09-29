# Bastion Access Project

A Docker Compose lab demonstrating a hardened SSH bastion (jump host) pattern: a single, controlled entry point in front of a network of otherwise unreachable machines.

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
```

- **bastion** is the only container on both networks, and the only one that publishes a port to the host (`2222:22`).
- **server1** and **server2** sit only on `private`, which is a Docker `internal: true` network — it has no route to the host or the outside world at all.
- All three containers are built from one shared Dockerfile. Role is determined entirely by Compose configuration (networking, ports), not by separate images.

## What "hardened" means here, concretely

Each property below was not just implemented but **tested**, with the specific evidence noted.

| Property | How it's enforced | How it was verified |
|---|---|---|
| Network isolation | `private` network is `internal: true`; only `bastion` bridges both networks | Direct `ssh` to server1's container IP from the host **times out** (packets dropped, not rejected) — vs. successful access via the bastion |
| Key-only authentication | `PasswordAuthentication no` in `sshd_config.d/hardening.conf` | Forcing `PubkeyAuthentication=no` from the client returns `Permission denied (publickey)`, not a password prompt |
| No root login | `PermitRootLogin no` in the same drop-in | Verified via `sshd -T` showing the resolved (not just written) config |
| Unique host identity per container | Host keys deleted at build time, generated fresh at container start via an entrypoint script | `ssh-keygen -lf` fingerprints differ across bastion/server1/server2 |
| Stable host identity across restarts | Host keys written to a per-container named Docker volume, mounted at `/etc/ssh/host_keys`, with `HostKey` lines pointing sshd at that path | Fingerprint identical before/after `docker restart` **and** after a full `docker compose down && up` |
| Bastion never holds your private key | `ProxyJump` (`-J`) — the client authenticates both hops itself; the bastion only relays encrypted bytes | Standard OpenSSH behavior; no private key material is ever copied into any container |

## The starting point vs. where it ended up

This project deliberately started with the naive version of each piece, then hardened it, so the "before" is preserved as a teaching artifact:

- **Auth:** `root:password` via `chpasswd` → key-only login as a non-root `admin` user, with password auth explicitly disabled at the sshd level.
- **Host keys:** all three containers silently shared identical host keys (baked in at image-build time by the `openssh-server` package's post-install script) → each container generates and persists its own unique identity.
- **Network reachability:** initial Compose file had no isolation → `server1`/`server2` verified unreachable except through the bastion.
- **Jump auth:** initially failed with a password prompt for the bastion hop, because `-i` on the command line doesn't propagate to the hidden first-hop connection `-J` creates → solved with a per-host `ssh_config` (`IdentityFile`, `ProxyJump`) plus `ssh-agent` to avoid repeated passphrase prompts.

## Key design decisions

- **One image, three roles.** Simpler to maintain, and demonstrates that topology (networks, ports, volumes) is what actually defines a machine's role in Compose — not a separate Dockerfile per container.
- **Host keys generated at container start, not build time.** Keeps the image itself free of any key material, and gives every container instance its own identity the moment it's created.
- **Host keys persisted via named volumes, scoped narrowly.** Only `/etc/ssh/host_keys` is volume-backed, not all of `/etc/ssh` — so `sshd_config` and the hardening drop-in still come fresh from the image on every rebuild, while host key identity survives container recreation. The alternative (mounting the whole `/etc/ssh` directory) was rejected because it would let stale config silently survive a rebuild.
- **`ProxyJump` over `sshd`-level forwarding tricks.** Keeps the trust model clean: the bastion is a relay, never a holder of credentials.

## Known, deliberately deferred gaps

Documented here rather than fixed, to keep the project's scope bounded:

- No `fail2ban` / intrusion detection on the bastion.
- No session audit logging of who jumped through and when.
- Sudo is installed on all containers but not specifically scoped or restricted for `admin`.

## Reproducing / testing this yourself

```bash
# Bring the stack up
docker compose up -d --build

# Confirm each container has a unique, correct host key
docker exec bastion ssh-keygen -lf /etc/ssh/host_keys/ssh_host_ed25519_key.pub
docker exec server1 ssh-keygen -lf /etc/ssh/host_keys/ssh_host_ed25519_key.pub
docker exec server2 ssh-keygen -lf /etc/ssh/host_keys/ssh_host_ed25519_key.pub

# Confirm hardening is actually enforced, not just written to a file
docker exec bastion sshd -T | grep -iE "passwordauthentication|permitrootlogin"

# Confirm isolation: this should time out
ssh admin@$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' server1)

# Confirm access via the bastion works
ssh -F ssh_config server1
```

## Files

- `docker-compose.yml` — services, networks (`public`, `private [internal]`), per-service named volumes for host keys
- `Dockerfile` — shared base image: Ubuntu 24.04, openssh-server, non-root `admin` user with baked-in public key
- `host_keygen.sh` — entrypoint: generates missing host keys, then `exec`s sshd
- `hardening.conf` — sshd drop-in: `PasswordAuthentication no`, `PermitRootLogin no`, `HostKey` paths
- `ssh_config` — client-side config defining `bastion` and `server1`/`server2` (via `ProxyJump`) for one-command access