# Acceptance Results — AI Platform Baseline

**STATUS: TASK 8A COMPLETE — FIREWALL VALIDATION PENDING.**

Task 8A runtime acceptance passed on `schai`. The canonical integrated stack was
deployed against the pre-existing 23 GB Ollama model volume, all API, GPU,
persistence, logging, and backup checks passed, and no rollback was needed.

Task 8B (firewall) is not started. `0.1.0` is **not** marked complete.
`CHANGELOG.md` is unmodified.

## Validation context

| Field | Value |
|---|---|
| Validation date | 2026-07-28, 08:04–08:23 CDT (America/Chicago) |
| Hostname | `schai` |
| Operator | `cschott` (uid 1000; `docker`, `sudo` groups) |
| Repository path | `/opt/schott-platform` |
| Branch | `feature/ai-platform-baseline` |
| Tested commit SHA | `1c72dcef886dd957668e27626808db88364dd6b5` |
| Ubuntu version | 24.04.4 LTS (kernel 6.8.0-136-generic) |
| Docker Engine | 29.6.2 |
| Docker Compose | v5.3.1 |
| NVIDIA driver | 580.173.02 (CUDA 13.0) |
| GPU model | NVIDIA Tesla P4, 7680 MiB |
| Disk at validation | 96 G total, 42 G free (55% used) |

## Results by phase

| Phase | Result |
|---|---|
| 1 — Execution context | PASS |
| 2 — Static validation | PASS — 0 failures, 0 skips |
| 3 — Local environment | PASS |
| 4 — Pre-deployment inventory | PASS |
| 5 — Deploy integrated stack | PASS — healthy on first attempt |
| 6 — GPU and model inventory | PASS |
| 7 — Runtime health / API acceptance | PASS |
| 8 — Persistence test | PASS |
| 9 — Logging validation | PASS |
| 10 — Sanitized backup | PASS |
| 11 — Firewall (Task 8B) | **PENDING — not started** |

### Static validation

| Check | Result |
|---|---|
| `bash tests/test-static.sh` | PASS — 0 failures, 0 skips |
| `bash -n scripts/*.sh` | PASS |
| `bash -n tests/test-static.sh` | PASS |
| `scripts/validate-config.sh` | PASS |
| `docker compose … ai/compose.yaml config` | PASS |
| `docker compose … ai/ollama/compose.yaml config` | PASS |
| `docker compose … ai/litellm/compose.yaml config` | PASS |

## Local environment

| Property | Value |
|---|---|
| `ai/.env` | pre-existing; preserved, not overwritten |
| Mode / owner | `600`, `cschott:cschott` |
| Git ignored | yes (`.gitignore:3`); absent from `git status` |
| `LITELLM_MASTER_KEY` | non-empty, 64 chars, unchanged |
| `OLLAMA_VOLUME_NAME` | exactly 1 active entry → `ollama_ollama-data` |

The volume override was appended, preserving the file inode (`2490487`), mode,
and ownership. The master-key line was fingerprinted before and after the edit —
SHA-256 prefix `feb8e5c10e56a57d` both times, proving it was not altered. The key
value was never printed, never passed as a command-line argument, and is not
recorded in this document. Sensitive variables were loaded only inside subshells.

## Rendered configuration (sanitized)

| Property | Value |
|---|---|
| Ollama image | `ollama/ollama:0.11.4` |
| LiteLLM image | `ghcr.io/berriai/litellm:main-v1.74.3-stable` |
| Resolved model volume | `ollama_ollama-data` |
| Ollama host ports | none (container-internal `11434/tcp` only) |
| LiteLLM published binding | `0.0.0.0:4000 -> 4000/tcp` |
| Network | `ai_ai-backend` (private bridge) |
| Logging (both services) | `json-file`, `max-size 10m`, `max-file 3` |

Legacy and canonical mounts both resolve to `/root/.ollama` on the same volume.

## Legacy container handoff

### Pre-handoff state

| Property | Value |
|---|---|
| Container / ID | `ollama` / `ef423000e7c4c7dbbb4e62d2bfdb5e1fbc4d3684a032047756f7704fa21cf9c7` |
| Image | `ollama/ollama:latest` (`sha256:10c13eb515db…`) |
| Server version | 0.32.4 |
| Health | healthy, up 24 h |
| Restart policy | `unless-stopped` |
| Published ports | `0.0.0.0:11434`, `[::]:11434` |
| Mounted volume | `ollama_ollama-data` → `/root/.ollama` (RW) |
| Volume size / blobs | 23 G / 12 blobs |
| Manifest tree SHA-256 | `a5ddc9d76b97d53282b2a5595b5b00b639dbfc5e70d921bf65960ab55558a7da` |
| GPU from container | Tesla P4 visible |

Models present before handoff: `qwen3:8b` (`500a1f067a9f`, 5.2 GB),
`qwen3:30b` (`ad815644918f`, 18 GB), `nomic-embed-text:latest`
(`0a109f422b47`, 274 MB).

### Stop result

`docker stop ollama` → exited cleanly, exit code `0`.

| Check | Result |
|---|---|
| Legacy container state | `exited`, code 0 |
| Auto-restart occurred | no (`unless-stopped` honours a manual stop) |
| External restart source | none — no systemd unit references ollama |
| Containers mounting the volume afterwards | none — exactly one planned writer |
| Volume still exists | yes, mountpoint unchanged |
| Container removed | no — preserved as the rollback path |

`docker compose down`, `down -v`, `docker volume rm`, and any rename or deletion
of the volume were **not** run at any point.

## Deployment result

`./scripts/deploy-schai.sh` → exit 0, healthy on the first attempt.

| Container | ID | Image | Status | Ports |
|---|---|---|---|---|
| `ai-ollama-1` | `56160e32d0b2` | `ollama/ollama:0.11.4` | healthy | `11434/tcp` not published |
| `ai-litellm-1` | `eb40ed8e532b` | `ghcr.io/berriai/litellm:main-v1.74.3-stable` | healthy | `0.0.0.0:4000->4000/tcp` |

`ai-ollama-1` was originally `d5e82268a05e`; the ID changed during the
persistence test, which is the expected result of recreation.

| Image | ID / repo digest |
|---|---|
| `ollama/ollama:0.11.4` | `sha256:be17b353bf3cfab0b6980530284e64716a57589ed753a82d9a6a2a5fa9a61a31` |
| `ghcr.io/berriai/litellm:main-v1.74.3-stable` | `sha256:229665e372493ab0948f36ca813a5a20f352e258424383d6a7043bf088eb12fb` |

### Volume adoption evidence

| Check | Result |
|---|---|
| Canonical Ollama mounts `ollama_ollama-data` | PASS |
| Models listed immediately, no re-download | PASS — all three at once |
| Manifest tree SHA-256 after deploy | `a5ddc9d76b97…` — identical to pre-stop |
| Blob count / size after deploy | 12 / 23 G — unchanged |
| New empty volume created | none — exactly one volume on the host |
| Both services on `ai_ai-backend` | PASS — `172.19.0.2`, `172.19.0.3` |
| Ollama host-published port | PASS — none |
| Tesla P4 inside canonical Ollama | PASS — 6017 MiB in use during inference |

## Runtime API results

`./scripts/health-check.sh --deep` → all checks PASS in 14.6 s.

Independent verification, issued directly rather than through the health script:

| Check | Result |
|---|---|
| Unauthenticated `/v1/models` | 401 — `Authentication Error, No api key passed in.` |
| Unauthenticated `/v1/chat/completions` | 401 |
| Malformed header / empty bearer | 401 — `Malformed API Key passed in.` |
| Well-formed but invalid key | 400 — `No connected db.` (rejected; see note) |
| Authenticated `/v1/models` | 200 — `local-embed`, `local-fast`, `local-general` |
| `local-fast` completion | 200 — `ollama/qwen3:8b`, non-empty, 60 tokens |
| `local-general` completion | 200 — `ollama/qwen3:30b`, non-empty, 62 tokens |
| `local-embed` embedding | 200 — `ollama/nomic-embed-text`, 768 dims, all numeric |

Alias mappings resolve exactly as required: `local-fast` → `ollama/qwen3:8b`,
`local-general` → `ollama/qwen3:30b`, `local-embed` → `ollama/nomic-embed-text`.

**On the `400` for invalid keys.** This baseline runs LiteLLM with no key
database, so the master key is the only key it can verify; any other well-formed
token cannot be looked up and is refused with `400 "No connected db."` rather
than `401`. Access is denied either way — authentication still fails closed.
`health-check.sh` was subsequently updated to assert this explicitly: an invalid
key must return `400`/`401`/`403`, and any `2xx` is a hard failure.

## Persistence result

Ollama was recreated in place with `up -d --force-recreate --no-deps ollama` —
no volume removal, no `down`.

| Check | Result |
|---|---|
| Container ID changed | `d5e82268a05e` → `56160e32d0b2` |
| Healthy after recreation | yes, ~9 s |
| Mount after recreation | `ollama_ollama-data` → `/root/.ollama` |
| All three models still listed | PASS |
| Manifest tree SHA-256 | `a5ddc9d76b97…` — unchanged |
| Volume count | 1 — no stray volume |
| `local-fast` after recreation | 200, non-empty |
| LiteLLM health after Ollama recreation | healthy |

## Logging result

| Check | Result |
|---|---|
| `ai-ollama-1` log config | `json-file`, `max-size 10m`, `max-file 3` |
| `ai-litellm-1` log config | `json-file`, `max-size 10m`, `max-file 3` |
| Prompt marker in either container's logs | 0 occurrences |
| Prompt body text in either container's logs | 0 occurrences |

LiteLLM logs record only model name, status, timestamp, and aggregate token
counts — no prompt or response content, consistent with
`turn_off_message_logging: true`. Log rollover was **not** forced; only that
rotation limits are configured is claimed.

## Backup result

| Item | Value |
|---|---|
| Archive | `backups/schott-platform-config-20260728-132203.tar.gz` |
| Checksum | `sha256sum -c` → OK |
| Entries | 49 files |
| Recorded git HEAD | `1c72dcef886dd957668e27626808db88364dd6b5` |
| Ollama model inventory | `ok` |

| Sanitization check | Result |
|---|---|
| Live master-key value present | PASS — absent (non-printing `grep -F`) |
| Real `.env` present | PASS — absent (only 3 `.env.example` templates) |
| Rendered Compose config | PASS — `LITELLM_MASTER_KEY: "<REDACTED>"` |

An earlier archive from the initial validation attempt was preserved. The
temporary extraction directory was removed after inspection.

## Rollback status

**Not used.** Deployment succeeded on the first attempt. The rollback path
remains intact: the legacy container `ollama` (`ef423000e7c4`,
`ollama/ollama:latest`, server 0.32.4) is stopped-but-present and can be
restarted with `docker start ollama` after stopping the canonical stack. The
model volume is untouched and shared by both paths.

## Firewall — PENDING

**Not performed.** No `ufw`, `iptables`, or `nft` command was run. Access to
ports `11434` and `4000` is unchanged.

Notes for Task 8B planning:

- The canonical stack **no longer publishes 11434 at all** — the only host-facing
  port is LiteLLM `0.0.0.0:4000`, a net reduction in exposure versus the legacy
  container, which published `11434` on all interfaces.
- The stopped legacy container still carries an `0.0.0.0:11434` mapping in its
  configuration. It is inert while stopped, but starting it would re-expose that
  port. Retiring it is a pending decision.
- `docs/security/network-policy.md` restricts `4000/tcp` to an approved subnet;
  that transition is Task 8B.

## Known risks

1. **Ollama server downgrade: 0.32.4 → 0.11.4.** The legacy container ran a much
   newer Ollama than the pinned canonical image. The 0.32.4-written model store
   was read correctly by 0.11.4 — all three models load and infer, and the
   manifest tree hash is byte-identical before and after — so no damage
   occurred. But the pin is far behind what this host was running, and a future
   `ollama pull` under 0.11.4 may fetch differently-formatted artifacts. The pin
   deserves a deliberate review.
2. **`down -v` remains destructive.** With the default
   `OLLAMA_VOLUME_EXTERNAL=false`, `docker compose down -v` would delete the
   volume. This host has not yet opted into `OLLAMA_VOLUME_EXTERNAL=true`
   (see below). Nothing in the repository runs `down -v`.
3. **Reasoning-model output.** `qwen3` emits `<think>` reasoning traces in
   completion content. Responses were non-empty and valid, but applications
   consuming `local-fast`/`local-general` will receive thinking text unless they
   strip it. An integration consideration, not a deployment defect.

## Deviations

1. **Images were pre-pulled before stopping the legacy container.** Non-mutating;
   it verified both pinned tags exist and shortened the window with no Ollama
   server running. `deploy-schai.sh` then re-pulled from cache and ran normally.
2. **Volume size was measured from inside the container** (`docker exec … du`)
   because the host mountpoint is root-only and `sudo` was not used for a
   read-only metric.
3. **Extra evidence was captured beyond the checklist**: manifest-tree SHA-256
   fingerprints before the stop, after deploy, and after recreation, plus
   inode/ownership and master-key-line fingerprints across the `ai/.env` edit.
4. Optional security tooling (`shellcheck`, `gitleaks`, `trivy`, `semgrep`) is
   not installed on `schai` and was neither installed nor pulled, per Task 8A
   constraints. SKIP retained; these remain required in CI.

## Constraints honoured

- `ai/.env` not overwritten; contents never displayed; key never printed.
- Container environment variables never inspected or printed.
- No `docker compose down`, `down -v`, or `docker volume rm` at any point.
- Legacy container stopped but not removed; legacy Compose directory intact.
- No firewall command of any kind.
- `CHANGELOG.md` unmodified; `0.1.0` not marked complete.

## Post-acceptance repository changes

Applied after Task 8A was approved, on top of `1c72dce`:

- **`OLLAMA_VOLUME_EXTERNAL`** (default `false`) was added to both Compose files.
  Adopters set it to `true` so Compose adopts an existing volume instead of
  creating one — a wrong volume name then fails loudly instead of silently
  starting against an empty store, `down -v` cannot delete the adopted data, and
  the Compose project-ownership warning is silenced. An unconditional
  `external: true` was rejected: it makes `up` fail with
  `external volume "…" not found` on any clean install.
- **`health-check.sh`** gained an invalid-key probe accepting `400`/`401`/`403`
  and failing hard on any `2xx`, with the `400 "No connected db."` behavior
  documented in `operations.md` and `SECURITY.md`.

### Open item for this host

`ai/.env` on `schai` still has `OLLAMA_VOLUME_EXTERNAL` unset (effectively
`false`) while adopting `ollama_ollama-data`. Setting it to `true` was verified
safe against the real volume via `docker compose up --dry-run` but was **not
applied** — it is an operational change requiring operator approval. Until it is
set, the adopted 23 GB remains deletable by `down -v`.

## History

The first validation attempt on 2026-07-28 06:43 CDT (commit
`18fb047e8d552245f1b80a2020e6523dfbe4fc88`) was **blocked** before deployment by
two pre-deployment findings. Both were resolved before the successful run
recorded above:

| Blocker | Finding | Resolution |
|---|---|---|
| 1 — Model volume | The canonical stack resolved to `ai_ollama-models`, which did not exist. Deploying would have started Ollama against an empty volume and orphaned 23 GB of models. | Commit `1c72dce` made the Docker volume name configurable via `OLLAMA_VOLUME_NAME`; `ai/.env` now adopts `ollama_ollama-data`. |
| 2 — Disk capacity | `/` had 1.4 G free of 48 G (98% used); the two pinned images alone exceeded free space. | Root filesystem expanded to 96 G; 48 G free before pulls, 42 G after. |

No deployment was attempted, no volume was detached, and no firewall rule was
changed during that first attempt. Both commit SHAs referenced in this document
were verified with `git cat-file -t` and resolve to real commit objects.
