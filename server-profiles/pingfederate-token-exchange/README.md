# PingFederate token-exchange server profile

This directory is a Ping Identity server profile for the perf lab's
PingFederate deployment, in the format documented by Ping's DevOps
[buildPingFederateProfile](https://developer.pingidentity.com/devops/how-to/buildPingFederateProfile.html)
guide. Push it to a git repository you own and point `SERVER_PROFILE_URL`
at it:

```bash
# .env
SERVER_PROFILE_URL=https://github.com/<your-org>/<your-profiles-repo>.git
SERVER_PROFILE_PATH=pingfederate-token-exchange   # if pushed as the repo root
SERVER_PROFILE_BRANCH=main
```

If the repository is private, create the chart's optional git secrets so the
image can clone it:

```bash
kubectl -n pf-perf create secret generic pf-pingfederate-admin-git-secret \
  --from-literal=SERVER_PROFILE_GIT_USER=<user> \
  --from-literal=SERVER_PROFILE_GIT_PASSWORD=<pat>
kubectl -n pf-perf create secret generic pf-pingfederate-engine-git-secret \
  --from-literal=SERVER_PROFILE_GIT_USER=<user> \
  --from-literal=SERVER_PROFILE_GIT_PASSWORD=<pat>
```

## Contents

| Path | Purpose |
|---|---|
| `instance/bulk-config/data.json.subst` | Declarative PingFederate configuration, imported by the image at startup |
| `instance/server/default/data/perf-subject-jwks.json` | Public verification key (JWKS) for the self-signed subject tokens, served in-cluster by the jwks-server chart |

## How the configuration is applied

No custom scripts: the PingFederate image's own startup hooks handle
everything. On admin startup the image expands `${VARIABLES}` in
`data.json.subst` from container environment variables and imports the
result through the bulk import API, then replicates the configuration to the
engine Pods. The import runs on every admin start, imposing this profile as
the full desired state.

## Required environment variables (on the admin container)

| Variable | Purpose | Where it comes from |
|---|---|---|
| `SUBJECT_ISSUER` | Allowed issuer for the subject tokens (`https://pf-perf-subject`) | `pingfederate-admin.envs` in the chart values |
| `SUBJECT_AUDIENCE` | Allowed audience (`perf-test-client`) | `pingfederate-admin.envs` |
| `SUBJECT_JWKS_URL` | Where the processor fetches verification keys (`http://perf-jwks-server/jwks.json`) | `pingfederate-admin.envs` — keep in sync with the jwks-server chart's Service name |
| `OUTPUT_ISSUER` | Issuer claim of the issued tokens (`https://pf-pingfederate-engine`) | `pingfederate-admin.envs` |
| `OUTPUT_AUDIENCE` | Audience claim of the issued tokens (`token-exchange-perf`) | `pingfederate-admin.envs` |
| `PERF_CLIENT_SECRET` | OAuth client secret (shared by all ten agent clients) | `pingfederate-admin.envs` — keep equal to `CLIENT_SECRET` in `.env` |
| `PF_ADMIN_PUBLIC_HOSTNAME` | Used only in `location` ref fields | set by the chart already |

The verification JWKS is **not** embedded in the bulk config: the token
processor is configured in JWKS URL mode and fetches
`instance/server/default/data/perf-subject-jwks.json` from the endpoint
`SUBJECT_JWKS_URL` at runtime, the same way it would fetch any issuer's
published JWKS. `scripts/deploy.sh` serves that exact file through the
`helm/jwks-server` chart (nginx pod + ClusterIP Service
`perf-jwks-server`) and deploys it before PingFederate so the URL resolves
from first use.

## What the bulk config creates

1. **PerfSubjectTokenProcessor** — JWT Token Processor 2.0
   (`com.pingidentity.pf.tokenprocessors.jwt.JwtTokenProcessor`) validating
   the k6-signed subject tokens against the JWKS fetched from
   `${SUBJECT_JWKS_URL}`, issuer `https://pf-perf-subject`, audience
   `perf-test-client`.
2. **PerfAccessTokenManager** — JWT access token manager (RS256, centralized
   signing key) issuing the exchanged (output) tokens.
3. **PerfTokenExchangePolicy** — token exchange processor policy mapping
   subject token type `urn:ietf:params:oauth:token-type:access_token` to the
   processor.
4. **Default processor policy** — the policy set as the server default via
   `/oauth/tokenExchange/processor/settings`.
5. **PerfTokenExchangeMapping** — access token mapping binding the policy to
   the token manager (`sub` ← TEPP `subject`).
6. **Ten OAuth clients, `perf-agent-0` … `perf-agent-9`** — one per k6 agent
   Pod, all confidential, all with the `TOKEN_EXCHANGE` grant,
   `client_secret_basic` auth (shared secret `${PERF_CLIENT_SECRET}`), and
   the policy assigned directly via `tokenExchangeProcessorPolicyRef`. Per-
   agent clients keep PF's per-client reporting aligned 1:1 with the load
   generator's per-agent view.

## Checking the result

After `make deploy`, the import outcome is in the admin pod log (the image's
`85-import-configuration.sh` hook logs it):

```bash
! kubectl -n pf-perf logs deploy/pf-pingfederate-admin -c pingfederate-admin | grep -i bulk
```

`INFO: Removing Imported Bulk File` means the import succeeded. Any error
there prints the API's failure response — `failFast=false` on the import
endpoint means all items are attempted and every failure is reported.

## Deliberate design constraints

- **All ten `perf-agent-N` clients are `TOKEN_EXCHANGE`-grant-only, with no refresh tokens.**
  This is enforcement by configuration, not convention: PingFederate cannot
  issue refresh tokens on this client, so every grant is transient and the
  persistent store is never touched at runtime. Agent flows should not mint
  refresh tokens through token exchange — the agent already holds stronger
  credentials, and the subject JWT carries the user authorization. Do not add
  `REFRESH_TOKEN` to `grantTypes` without revisiting the datastore strategy
  (the embedded HSQLDB is not a shared, durable grant store).
- **Subject-token validation is signature-local** (JWT Token Processor 2.0 in
  JWKS URL mode): signature checks run against PF's in-memory JWKS cache, so
  there is no datastore round-trip and no per-request JWKS fetch — the
  endpoint is hit on cache expiry/refresh, not per token. Opaque PF-issued
  subject tokens would validate via grant lookup and change the performance
  profile — not part of this design.

## Changing the subject signing key

The JWKS must match the private key k6 uses (`keys/subject-signing.key`,
generated by `make keys`). `make keys` rewrites
`instance/server/default/data/perf-subject-jwks.json`; re-push the profile
and redeploy so the jwks-server pod serves the new keys. Do not regenerate
the key between deploys without re-pushing — the signature must verify
against the exact public key at the JWKS URL.
