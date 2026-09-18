# PingFederate token-exchange performance test

This project deploys the current Ping Identity Kubernetes topology and drives RFC 8693 token exchange from inside the cluster:

- 1 PingFederate administration Pod
- 2 PingFederate engine Pods behind one Kubernetes Service
- 1 disposable k6 Job generating a constant arrival rate (or N parallel agent Pods with a profile)

The load is sent directly to the engine Service on port 9031. Administration traffic on port 9999 is not part of the benchmark.

Subject tokens are **self-signed by the load generator** (RS256 with the predefined key in `keys/subject-signing.key`) and validated by PingFederate against the matching public JWKS shipped in the server profile — user authentication is not part of the measurement. Each request carries a freshly signed token whose subject rotates through 100 synthetic users, so no token is ever replayed. The PingFederate side (token processor, access token manager, token exchange policy, OAuth client) is declarative: the server profile carries it as `instance/bulk-config/data.json.subst`, which the PF image imports at startup — see `docs/pingfederate-configuration.md`.

## Scope of this campaign

This campaign is a **baseline characterization** of the RFC 8693 token-exchange path at fixed reference load levels up to **500 exchanges/second**: token-endpoint latency (p50/p90/p95/max), achieved throughput, error rate, and PingFederate pod CPU/memory, measured over five-minute steady windows at each reference level.

**Deliberately out of scope — this data does not support conclusions about:**

- the saturation point, maximum sustainable throughput, capacity, headroom, or recommended operating limits — no reference level is run to failure;
- behavior above 500 exchanges/second — untested is not the same as acceptable;
- overload, burst, failure, and recovery behavior;
- autoscaling (the engine topology is fixed at two pods);
- deployments whose token path adds persistent-store access, opaque subject-token validation, or remote JWKS fetching — for those, these results are a floor, not a measurement (see Benchmark assumptions).

The bound is a design decision, not an omission: the cluster is shared with workloads this project does not own, and deliberately driving co-tenants toward a failure point is not authorized. Reference levels are therefore fixed points, measured as-is, and load stops there. Capacity conclusions would require a separate campaign on isolated infrastructure.

### Why 500 exchanges/second

The highest reference level is derived from a workload model, not chosen arbitrarily:

```
TPS = agents × users_per_agent × exchanges_per_user_per_minute / 60
    = 10 × 3,000 × 1/60
    = 500/s
```

- **10 service agents** — machine identities calling the token endpoint on their users' behalf.
- **3,000 active users per agent** (30,000 active users total) — the user population served in the measured period.
- **1 exchange per active user per minute** — the assumed steady-state interaction rate. The estimate is linear in every parameter, so replace these values with the deployment's actual population and interaction rate and the reference level moves with them. Bursts above steady state are out of scope (see above).

The profile (`RATE=500`) and this derivation must stay in sync: if the deployment's estimate is higher, write a new reference profile — do not silently stretch this one.

Sanity check (Little's law): at 500/s with p95 ≈ 100 ms, in-flight concurrency is ≈ 50 requests cluster-wide, ≈ 5 per agent — far inside the per-agent VU allocation, so the load generator is not the constraint at the reference level.

### Measurement basis

- Each reference level is run **once per campaign**, in ascending order against the same continuously warmed engines. Numbers are baseline measurements of that warmed steady state, not confidence-bounded statistical estimates — rerun before treating a difference between two runs as meaningful.
- The achieved rate is part of the result, not an assumption: k6's `dropped_iterations` and the per-second request rate are recorded with every run. A run that dropped iterations measured less load than its target rate — do not quote it at the target rate.
- The nodes are shared: co-tenant load during a run is visible in the report's node-CPU panel and is an uncontrolled environmental factor.

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

Profile values win over `.env`, so a profile fully describes its test. The bundled `agents` profile runs 10 parallel k6 agent Pods signing fresh subject tokens for 100 rotating synthetic users at a combined 100 exchanges/second:

1. Generate the signing key once: `make keys`.
2. Push the server profile (with the generated JWKS) to your profiles repo, set `SERVER_PROFILE_URL`, and `make deploy`.
3. Run: `make test PROFILE=agents`.

Each agent Pod runs `RATE / AGENTS` iterations per second, signs a fresh RS256 subject token per iteration (rotating `sub` through its share of the users), and exchanges it with `client_credentials`-authenticated requests. The measured path is exactly the production one and no single subject token is replayed.

Custom profiles: copy `profiles/agents.env`, adjust `AGENTS`, `RATE`, and `SUBJECT_USER_COUNT`, then `make test PROFILE=<name>`. Reference levels for this campaign live in `profiles/stage-*.env` (100–500/s) and must stay within the documented bound — see "Scope of this campaign".

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

Run the reference levels in `profiles/stage-*.env` in ascending order — do not run a level whose rate exceeds the campaign bound (500/s). Keep PingFederate CPU and memory requests/limits unchanged between runs. The thresholds (`P95_MS`, `SUCCESS_RATE`) are **provisional** sanity bounds for these reference levels, not production SLOs — no business requirement is attached to them.

## What the result means

k6 reports transport metrics and three test-specific metrics:

- `token_exchange_latency`: complete token endpoint response time
- `token_exchange_success`: HTTP 200 plus `access_token` and `issued_token_type`
- `token_exchange_oauth_errors`: count of failed or invalid OAuth responses

With multiple agents each k6 Pod prints its own summary; the per-agent latencies are comparable because every agent drives the same share of the rate. The Kubernetes Service should distribute requests across both engine Pods. Compare their CPU/memory samples in `results/` to catch imbalance. For precise per-node request counts, enable PingFederate access metrics/logging and aggregate by Pod name.

## Benchmark assumptions

These assumptions define what the measured numbers mean. They are design decisions, not accidents — changing any of them changes what the benchmark measures.

1. **Subject tokens are always self-contained JWTs, validated by a JWT token processor.** The inbound token is an RS256 JWT validated by PingFederate's JWT Token Processor 2.0 against the public JWKS shipped in the server profile (issuer `https://pf-perf-subject`, audience `perf-test-client`). Validation is self-contained — signature, issuer, audience, expiry are all checked from the token itself against in-memory key material.

2. **No persistent storage on the hot path.** The client is `TOKEN_EXCHANGE`-grant-only — PingFederate never issues refresh tokens here, so every grant is transient and the persistent store is never read or written. Token exchange produces transient grants by definition, and JWT subject-token validation requires no grant lookup (unlike opaque PF-issued tokens, which validate via a grant-store read). This holds even for subject tokens that originally came from a refresh-token-backed session: the JWT processor validates the token on its own merits.

3. **The embedded HSQLDB is therefore out of the request path entirely.** Its known limitations (not shared between cluster nodes, not durable across restarts, trial-only licensing) do not affect these results — there is nothing for it to store, and configuration durability is provided by the bulk import re-imposing the profile on every admin restart. **This is deliberate: agent flows should not use refresh tokens through token exchange** — the agent already holds stronger credentials (its client secret), and the subject token itself carries the user authorization, so a refresh token would be redundant long-lived material to protect. Enforcement is by config (`grantTypes: ["TOKEN_EXCHANGE"]` only), not convention: PingFederate cannot issue refresh tokens here. If a future platform variant introduces opaque subject tokens validated by grant lookup, or refresh-token flows, the persistent store re-enters the hot path and this assumption must be revisited — with an external, shared datastore per Ping's production guidance.

4. **What the numbers include and exclude.** Measured: client authentication, JWT validation, token-exchange policy evaluation, output-token signing, transport. Not measured: user authentication (synthetic subjects, no IdP round-trip), persistent-grant storage (never touched), external IdP/PAZ calls. Results are therefore a *floor* for real deployments that add storage-backed validation steps.

5. **Stage numbers reflect continuously-warmed engines.** Ladder stages run sequentially against the same deployment: by the time a later stage runs, JIT compilation, caches, and JWKS parsing are hot from the preceding stages. The 30s warmup primes each run's connections, but cross-stage comparisons embed this ordering effect — the first stage of a campaign after a fresh deployment is not directly comparable to later stages. All stage numbers therefore represent a *continuously-warmed* PingFederate, which is itself a representativeness claim: production engines serving steady traffic are warm, so this matches the intended steady-state use case, at the cost of not characterizing cold-start behavior (first requests after a restart, before the warmup period).

6. **Known behavior: a 30s-cadence latency wave, traced to Jetty's runtime idle timeout.** At sub-10 ms latencies the response-time charts show a regular sawtooth: a ~6–8 s-wide elevation of ~1.5–4 ms recurring every 30 s, simultaneous across all agents and both engines. Diagnosis by elimination (autocorrelation 0.80 at 30 s lag; zero connection setup or TLS at wave seconds; flat engine CPU; GC-pause correlation at chance level; no engine log entries; cycle pre-existed every prior campaign): the period matches `pf.runtime.http.idleTimeout=30000` exactly (`/opt/out/instance/bin/run.properties`), so the wave is consistent with Jetty's idle-connection reaper sweeping the selector every 30 s and briefly stalling in-flight requests. The stall is fixed (~4 ms), measured through rather than filtered out, and negligible at production latencies; it explains the wave in the charts, not any verdict. Related observation: both engines allocate ~250 MB/s even at idle (GC every ~1 s / ~6 s respectively), so JVM heap churn — not requests — dominates baseline CPU at these low rates.

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
