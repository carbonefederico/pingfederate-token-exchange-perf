# PingFederate token-exchange performance test

This project deploys the current Ping Identity Kubernetes topology and drives RFC 8693 token exchange from inside the cluster:

- 1 PingFederate administration Pod
- 2 PingFederate engine Pods behind one Kubernetes Service
- 1 disposable k6 Job generating a constant arrival rate (or N parallel agent Pods with a profile)

The load is sent directly to the engine Service on port 9031. Administration traffic on port 9999 is not part of the benchmark.

Subject tokens are **self-signed by the load generator** (RS256 with the predefined key in `keys/subject-signing.key`) and validated by PingFederate against the matching public JWKS shipped in the server profile — user authentication is not part of the measurement. Each request carries a freshly signed token whose subject rotates through 100 synthetic users, so no token is ever replayed. The PingFederate side (token processor, access token manager, token exchange policy, OAuth client) is declarative: the server profile carries it as `instance/bulk-config/data.json.subst`, which the PF image imports at startup — see `docs/pingfederate-configuration.md`.

## Prerequisites

- Kubernetes cluster and a working `kubectl` context
- Helm 3
- Ping DevOps user/key or an equivalent licensed image setup
- A git repository to host the server profile (push `server-profiles/` there)
- `python3` and `openssl` for `make keys` and the smoke test
- Metrics Server if you want `make monitor`

The project pins the official Ping chart to `0.15.0` and the k6 image to `2.2.0`. Change these in `.env` and `helm/loadtest/values.yaml` deliberately when upgrading.

## Quick start

```bash
cp .env.example .env
# Edit .env. Never commit it; shell-quote values containing special characters.

make keys
# -> keys/subject-signing.key (private, git-ignored) and the JWKS in the profile

# Push server-profiles/pingfederate-token-exchange/ to your profiles repo and
# set SERVER_PROFILE_URL / SERVER_PROFILE_PATH in .env.

make validate
make deploy
make verify
```

After the deploy, the profile's bulk config configures PingFederate automatically (token processor, access token manager, token exchange policy, OAuth client). Check its output:

```bash
! kubectl -n pf-perf logs deploy/pf-pingfederate-admin -c pingfederate-admin | grep -i bulk
```

Before starting load, verify one token exchange. Port-forward the engine Service from your workstation, point `PF_TOKEN_URL` at `https://localhost:9031/as/token.oauth2`, and run:

```bash
kubectl -n pf-perf port-forward service/pf-pingfederate-engine 9031:9031
make smoke
```

Run the real test inside Kubernetes so network latency represents the cluster rather than your workstation:

```bash
make test
```

In a second terminal, capture per-Pod CPU and memory every five seconds:

```bash
make monitor
```

## Load profiles

A profile is a self-contained file in `profiles/<name>.env` loaded on top of `.env`:

```bash
make test PROFILE=agents
```

Profile values win over `.env`, so a profile fully describes its test. The bundled `agents` profile runs 10 parallel k6 agent Pods signing fresh subject tokens for 100 rotating synthetic users:

1. Generate the signing key once: `make keys`.
2. Push the server profile (with the generated JWKS) to your profiles repo, set `SERVER_PROFILE_URL`, and `make deploy`.
3. Run: `make test PROFILE=agents`.

Each agent Pod runs `RATE / AGENTS` iterations per second, signs a fresh RS256 subject token per iteration (rotating `sub` through its share of the users), and exchanges it with `client_credentials`-authenticated requests. The measured path is exactly the production one and no single subject token is replayed.

Custom profiles: copy `profiles/agents.env`, adjust `AGENTS`, `RATE`, and `SUBJECT_USER_COUNT`, then `make test PROFILE=<name>`.

## Load controls

The defaults generate 50 token exchanges per second for five minutes. Set these in `.env` (or in the profile, which wins):

| Variable | Default | Meaning |
|---|---:|---|
| `RATE` | `50` | Total iterations per second (divided across agents) |
| `AGENTS` | `1` | Parallel k6 agent Pods |
| `DURATION` | `5m` | Steady test duration |
| `PRE_ALLOCATED_VUS` | `25` | Initially allocated k6 workers per agent |
| `MAX_VUS` | `200` | Maximum workers used to sustain the rate, per agent |
| `P95_MS` | `500` | p95 latency threshold in milliseconds |
| `SUCCESS_RATE` | `0.99` | Minimum valid OAuth response rate |

Run several stages rather than jumping immediately to saturation: 10 requests/second as a baseline, then 25, 50, 100, and upward until latency or error thresholds fail. Keep PingFederate CPU and memory requests/limits unchanged between runs.

## What the result means

k6 reports transport metrics and three test-specific metrics:

- `token_exchange_latency`: complete token endpoint response time
- `token_exchange_success`: HTTP 200 plus `access_token` and `issued_token_type`
- `token_exchange_oauth_errors`: count of failed or invalid OAuth responses

With multiple agents each k6 Pod prints its own summary; the per-agent latencies are comparable because every agent drives the same share of the rate. The Kubernetes Service should distribute requests across both engine Pods. Compare their CPU/memory samples in `results/` to catch imbalance. For precise per-node request counts, enable PingFederate access metrics/logging and aggregate by Pod name.

## Configuration and safety notes

- `.env` contains credentials and is excluded from Git. Profiles in `profiles/` hold only shape settings and client IDs, never secrets. `keys/` holds the subject signing key and is also excluded.
- k6 response bodies are parsed only to validate the response; token values are never logged.
- The subject signing key must stay stable across a test campaign: every request's signature must verify against the JWKS in the deployed profile. Regenerate only with `./scripts/generate-signing-key.sh --force`, then re-push the profile and redeploy.
- `INSECURE_SKIP_TLS_VERIFY=true` is suitable for the chart's internal/self-signed TLS during a lab test. Install trusted certificates and set it to `false` for a production-like test.
- The anti-affinity rule prefers different Kubernetes nodes but does not require them. Check `make verify` output if physical node separation matters.
- See `docs/pingfederate-configuration.md` for the PF objects and the profile's bulk-config behavior.

## Cleanup

```bash
make uninstall
```

The namespace and Secrets are intentionally retained. Delete the namespace explicitly only when you no longer need anything in it:

```bash
kubectl delete namespace pf-perf
```
