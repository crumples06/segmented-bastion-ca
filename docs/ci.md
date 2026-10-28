# Continuous integration

[← Back to README](../README.md)

`.github/workflows/ci.yml` runs on every pull request to `main` and can also be started by hand (`workflow_dispatch`). It is one job on a blank runner: it builds a throwaway copy of the entire lab with the same `bootstrap.sh` a human runs, tests it, and tears it down. Nothing from your own lab (CA volume, keys, vault) is used or needed.

## What the pipeline does

1. **Write `.env`** with a throwaway CA password (`CI_CA_PASSWORD`, defined once in the workflow's `env:`), so the secret is known in advance.
2. **Start the CA** and wait for it to be healthy.
3. **Allow short-lived certificates on the CI CA** by lowering the `admin` provisioner's minimum SSH certificate duration, so expiry can be tested in seconds instead of minutes.
4. **Run `scripts/bootstrap.sh`.** This is the whole lab setup: public keys, `known_hosts`, generated variables, vault, containers, the relaxed bootstrap run that issues every host certificate, and the strict run that proves them.
5. **Issue a test user certificate** with `KEY_ID=ci-user bash scripts/login.sh` (principal `admin`, 1h).
6. **Run the positive tests, then the negative tests** (below).
7. **Always:** on failure, dump every container's logs; then `docker compose down -v`.

Because CI runs the same script as a person following the Quick start, the documented path and the tested path cannot drift apart.

## Positive tests (`ci/positive-tests.sh`)

| Check | What it proves |
|---|---|
| `ssh <host> hostname` on bastion, server1, server2 matches `hostname` run inside that container | The login reached the machine that was meant, not just any machine |
| Each host's log contains `Accepted publickey for admin ... ED25519-CERT ... ID ci-user` | The login used the certificate, not a static key |
| `ssh -v` reports `known and matches the ED25519-CERT host certificate` for each host | The client verified host identity through the host CA |

## Negative tests (`ci/negative-tests.sh`)

Each login case is built as its own complete ssh config so both `ProxyJump` hops use the same identity. Cases 1-5 only pass if the login fails **and** the output contains `Permission denied`, so a typo or a timeout cannot make them pass for the wrong reason. The isolation case (6) is different: it passes if the direct connection to server1's container IP fails for any reason, and it does not check that the failure was a timeout.

| Case | Expected result |
|---|---|
| 1. Valid key, no certificate | Refused (`Permission denied`) |
| 2. Certificate signed by a rogue CA (principal `admin`) | Refused (`Permission denied`) |
| 3. Certificate from the real CA, principal `notadmin` | Refused (`Permission denied`) |
| 4. Password authentication (public-key auth disabled on the client) | Refused (`Permission denied`) |
| 5. Expired certificate (issued with a short validity, used after it lapses) | Refused (`Permission denied`) |
| 6. Direct connection to server1's container IP from the runner | Connection fails (a timeout when run by hand) |

## Running the tests against your own lab

Both scripts run from the repository root and expect the stack to be up. They were written for CI, so against your lab:

- The positive tests grep for key ID `ci-user`, so issue your certificate with `KEY_ID=ci-user bash scripts/login.sh` first.
- `negative-tests.sh` signs extra certificates through the CA, so it needs the CA password. It reads `CI_CA_PASSWORD` if set and otherwise falls back to `CA_PASSWORD` from `.env`.
- The expired-certificate case signs a 1-minute certificate, which the lab CA rejects because its minimum is 5 minutes. That case only works on the CI CA.

## How CI differs from the lab, on purpose

- **A known CA password.** Locally the password is random and kept in `.env`; CI sets its own throwaway value up front. The CI CA is destroyed at the end of every run.
- **A lowered minimum certificate duration** on the CI CA only, so the expiry test takes seconds. The lab CA is unchanged.
- **Nothing else.** The relaxed `accept-new` bootstrap run, the vault, the generated variables and the strict verification run are the same code path in both places.