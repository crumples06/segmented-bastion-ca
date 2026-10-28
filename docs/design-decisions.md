# Design decisions

[← Back to README](../README.md)

## How it evolved

This project deliberately started with the naive version of each piece, then hardened it, so the "before" is preserved as a teaching artifact:

- **Auth:** `root:password` via `chpasswd` → key-only login as a non-root `admin` user → **CA-signed, short-lived user certificates with no static keys on any host**.
- **Host keys:** all three containers silently shared identical host keys (baked in at image-build time by the `openssh-server` post-install script) → each container generates and persists its own unique identity → **each identity is vouched for by a host certificate**.
- **Host verification:** trust-on-first-use fingerprint prompts → a single `@cert-authority` line with strict checking.
- **Certificate issuance:** a sequence of hand-typed `docker cp` / `docker exec` commands → **an idempotent Ansible playbook** that talks to the CA's API from a dedicated control node.
- **Network reachability:** initial Compose file had no isolation → `server1`/`server2` verified unreachable except through the bastion.
- **Jump auth:** initially failed with a password prompt for the bastion hop, because `-i` on the command line doesn't propagate to the hidden first-hop connection `-J` creates → solved with a per-host `ssh_config` (`IdentityFile`, `CertificateFile`, `ProxyJump`) plus `ssh-agent` to avoid repeated passphrase prompts.
- **Verification:** manual command checks → **a GitHub Actions pipeline** that rebuilds the lab from nothing and asserts both what must work and what must be refused.
- **Setup:** a ten-step manual procedure (scrape the CA password from logs, copy keys by hand, type the vault password, run the playbook twice with different configs) → **one idempotent `bootstrap.sh`** that the CI pipeline also runs, so the path users follow is the path that is tested.

## Verify the mechanism, not just the outcome

This was the recurring lesson of the project:

- "The login worked" was true in several cases where the certificate wasn't involved (a leftover static key was accepted first).
- "The task reported `changed`" doesn't prove sshd is serving the new certificate, so renewal was verified by reading the serial presented on the wire.
- "The script finished" was true while one of `bootstrap.sh`'s checks was silently broken, **twice**. First a typo (`docker comopse exec`) made the "does this host have a certificate yet?" check always fail, and then a loop written as `for h in bastion,server1,server2` made it one iteration over a single bogus service name. Both times the failure was read as "no certificate yet", the relaxed path ran every time, and the strict rerun still passed and hid the fault.

A check that fails for the wrong reason looks identical to one that fails for the right reason, and a failing check is not the same as a check that found something. That is why the positive tests read the server's `Accepted ... ED25519-CERT` log line and the negative tests require `Permission denied` specifically.

## Decisions

### Structure and network

- **One image for the SSH hosts, separate images for the CA and control node.** Topology defines a machine's role among the SSH hosts; the CA and the control node are different kinds of machine.
- **Control sits on `public` and `ca`, not on `private`.** It reaches the servers through the bastion (`ProxyJump`), so the `private` network keeps exactly one way in. Joining `private` would have made the control node a second bridge into it.
- **`ProxyJump` over `sshd`-level forwarding tricks.** The bastion is a relay, never a holder of credentials. User certificates must keep `permit-port-forwarding`, because `ProxyJump` relies on it.

### Keys and certificates

- **Host keys generated at container start, not build time.** Keeps the image free of key material and gives every container its own identity the moment it's created.
- **Host keys persisted via named volumes, scoped narrowly.** Only `/etc/ssh/host_keys` is volume-backed, so `sshd_config` and the hardening drop-in still come fresh from the image on every rebuild. Mounting all of `/etc/ssh` was rejected because stale config could silently survive a rebuild.
- **Host certificates live in the volumes, not the image.** The image is shared by all three hosts, so a baked-in certificate would be identical everywhere. A certificate is bound to one exact host key, so the key and its certificate must live and die together: they are in the same volume, so deleting the volume removes both, and the next playbook run sees no certificate and issues a new one for the regenerated key.
- **The user CA's public key is bind-mounted, not baked into the image.** The image contains no lab-specific material, and a different CA no longer needs an image rebuild (recreate the containers so they pick up the new file). The file must exist before the hosts start, which is why `bootstrap.sh` exports it first. Ansible cannot deliver this file: it logs in with a certificate the servers can only accept once they already trust the user CA, so Compose provisions it.
- **Two separate CA keys (user and host).** Trusting one does not imply trusting the other.
- **A project-local `known_hosts`** (`ca/known_hosts`), so the CA line is the *only* host trust a client has. A success can then only be explained by the CA, never by an old fingerprint.

### Automation

- **The control node talks to the CA over its HTTPS API, not through `docker exec`.** The CA image has no Python (so Ansible modules can't run on it), and driving it with `docker exec` would mean mounting the Docker socket into the control container, which is root-equivalent on the host and would bypass every network boundary. The `step` CLI in the control container signs over `https://ca:9000` instead, trusting the CA via `step ca bootstrap` and a pinned root fingerprint.
- **Ansible is a client of the system it manages.** It logs in with a CA-signed certificate like any user, so automation exercises the same trust path as humans and is distinguishable in logs by its key ID.
- **A dedicated, passphrase-less key for the control node, with an 8-hour certificate.** The key never leaves the control container. An unencrypted key is acceptable only because the credential is short-lived: a stolen key plus certificate is useless after the certificate expires. The control play issues a fresh certificate on every run.
- **Passwordless sudo for `admin`.** Ansible needs root to write into `/etc/ssh/host_keys` and reload sshd. This is a deliberate lab tradeoff; a production setup would scope it more narrowly.
- **Renewal is conditional, with a 7-day threshold.** Host certificates last 30 days; the playbook reads each host's current certificate and only re-signs when it is missing or close to expiry. A `force_renew` variable exercises the renewal path on demand.

### Secrets and repository hygiene

- **Secrets are generated, never typed or committed.** `.env` (gitignored) holds a random CA password and a random vault password. The provisioner password sits in an Ansible-Vault-encrypted `vault.yml`, is passed to `step` over stdin, and every task that touches it has `no_log: true`. `vars.yml` stays readable: it holds the public values (root fingerprint, certificate path) and refers to the vaulted password as `vault_ca_provisioner_password`.
- **Generated, lab-specific files are not committed.** `ca/`, `keys/`, `vars.yml`, `vault.yml` and the bootstrap SSH config belong to one CA instance, so they are gitignored and rebuilt by `bootstrap.sh`. A fresh clone has nothing stale to remove.

### Testing

- **One bootstrap path for humans and CI.** The pipeline runs the same script as the Quick start, so the documented setup is the tested setup. Only the CA password and the minimum certificate duration differ.
- **Tests verify the mechanism, not just the outcome.** See the section above.
- **CI is hermetic.** It never reads the lab's CA, keys or vault. Everything it needs is created on the runner and destroyed afterwards.