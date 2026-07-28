# Acceptance Results — AI Platform Baseline

**STATUS: COMPLETE.**

Both acceptance tasks passed on `schai`:

- **Task 8A** (2026-07-28, 08:04–08:23 CDT) — the canonical integrated stack was
  deployed against the pre-existing 23 GB Ollama model volume; all API, GPU,
  persistence, logging, and backup checks passed with no rollback.
- **Task 8B** (2026-07-28, 09:05–09:21 CDT) — the UFW transition was applied,
  the legacy `11434/tcp` allowance was removed, LiteLLM was validated from an
  approved LAN client, and the legacy container was retired.

`0.1.0` is marked complete in `CHANGELOG.md`. One accepted limitation is
recorded: UFW does not reliably filter Docker-published port `4000`
(see [Task 8B](#task-8b--firewall-validation)).

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
| 11 — Firewall (Task 8B) | PASS — see [Task 8B](#task-8b--firewall-validation) |

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

**Not used.** Deployment succeeded on the first attempt. The legacy container
served as the rollback path throughout Task 8A and was retired during Task 8B
only after every firewall and runtime check passed
(see [Legacy container disposition](#legacy-container-disposition)).

## Task 8B — firewall validation

**Date:** 2026-07-28, 09:05–09:21 CDT (America/Chicago).

### Approved source ranges

Set by explicit platform-owner decision for the current flat homelab LAN, and
recorded in `docs/security/network-policy.md` (replacing the previous
`<approved-subnet>` / `<management-subnet>` placeholders):

| Purpose | Range |
|---|---|
| Approved application range (LiteLLM `4000/tcp`) | `192.168.86.0/24` |
| Approved management range (SSH `22/tcp`) | `192.168.86.0/24` |

Both are identical only because the LAN is flat today; the policy document
requires narrowing them when VLANs or additional routed networks are introduced.
This was an owner decision, **not** an inference from the former Ollama rule.

### UFW before

```
[ 1] OpenSSH        ALLOW IN  Anywhere
[ 2] 11434/tcp      ALLOW IN  192.168.86.0/24
[ 3] OpenSSH (v6)   ALLOW IN  Anywhere (v6)
```

### UFW changes applied

All `sudo`-requiring commands were executed manually by the operator; no
repository script and no assistant-run command touched the firewall. No
`iptables` or `nft` command was run at any point.

```bash
sudo ufw allow from 192.168.86.0/24 to any port 22 proto tcp \
  comment 'SSH from trusted LAN'
sudo ufw allow from 192.168.86.0/24 to any port 4000 proto tcp \
  comment 'LiteLLM from trusted LAN'
sudo ufw delete 2          # the legacy 11434/tcp allowance
```

### UFW after

```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

[ 1] OpenSSH        ALLOW IN  Anywhere
[ 2] 22/tcp         ALLOW IN  192.168.86.0/24   # SSH from trusted LAN
[ 3] 4000/tcp       ALLOW IN  192.168.86.0/24   # LiteLLM from trusted LAN
[ 4] OpenSSH (v6)   ALLOW IN  Anywhere (v6)
```

No `11434/tcp` rule remains.

### SSH preservation

SSH was allowed from the approved range **before** the 11434 rule was removed,
and the pre-existing `OpenSSH ALLOW IN Anywhere` rules were left untouched
throughout, so no window existed in which management access could be lost. The
operator's session (`192.168.86.170` → `192.168.86.3:22`) remained connected
across every change; three established sessions were present throughout.

### Host-side validation

| Check | Result |
|---|---|
| `./scripts/health-check.sh --deep` | PASS — 8/8 |
| Authenticated `/v1/models` on `127.0.0.1:4000` | 200 — three aliases |
| Unauthenticated `/v1/models` | 401 — fails closed |
| Invalid API key | 400 — rejected, never `2xx` |
| Host listener on `11434` | none |
| `127.0.0.1:11434` / `192.168.86.3:11434` | connection refused |
| `docker ps` published ports | `ai-ollama-1` none; `ai-litellm-1` `0.0.0.0:4000->4000/tcp` |
| Authenticated `/v1/models` via `http://192.168.86.3:4000` | 200 |
| Authenticated `local-fast` via `http://schai:4000` | 200, `ollama/qwen3:8b`, non-empty |

### Approved LAN-client validation

Performed from `MAINPC` (WSL), an approved client inside `192.168.86.0/24`:

| Check | Result |
|---|---|
| `getent hosts schai` | `192.168.86.3  schai.home.arpa` — resolves |
| `nc -vz 192.168.86.3 4000` | **succeeded** |
| Authenticated `GET /v1/models` | **HTTP 200** — `local-embed`, `local-fast`, `local-general` |
| Authenticated `POST /v1/chat/completions` (`local-fast`) | **HTTP 200** — `ollama/qwen3:8b`, non-empty |
| `nc -vz 192.168.86.3 11434` | **Connection refused** |
| `curl http://192.168.86.3:11434/api/tags` | **Couldn't connect** |
| SSH from the approved range | reachable (operator session active throughout) |

Port `11434` was rejected by two independent methods. Its protection does not
depend on UFW at all: `ai/compose.yaml` publishes no Ollama host port, so no
Docker chain can expose it.

### Outside-approved-range test

**NOT PERFORMED.** No routed client outside `192.168.86.0/24` is available on
this flat homelab network. Negative confirmation from outside the approved range
is therefore not part of this acceptance record.

### Docker / UFW filtering limitation — accepted for v0.1.0

UFW does **not** reliably filter Docker-published ports: Docker's `DOCKER-USER`
and `DOCKER` chains are evaluated before UFW's `ufw-user-input` chain, so the
`4000/tcp` rule above documents intent but may not by itself block an
out-of-range host.

This is a **recorded, accepted limitation** for this release because:

- the host has **no public IPv4 address**, and **no public/NAT exposure is
  configured as part of this host task** — the only global IPv6 address is an
  `fd00::/8` unique local address, which is not internet-routable;
- port `4000` is therefore reachable only from the local LAN regardless of the
  UFW rule, and the LAN is the approved range;
- port `11434` is not published at all, so it is unaffected.

A persistent `DOCKER-USER` policy that enforces the approved range at the packet
level is **deferred to a separately designed network-hardening enhancement** and
is out of scope for `v0.1.0`.

### Legacy container disposition

Retired after all firewall and runtime checks passed.

| Property | Value |
|---|---|
| Container / ID | `ollama` / `ef423000e7c4c7dbbb4e62d2bfdb5e1fbc4d3684a032047756f7704fa21cf9c7` |
| Image / image ID | `ollama/ollama:latest` / `sha256:10c13eb515db…` |
| State before removal | `exited`, code 0, stopped 2026-07-28T13:17:02Z |
| Action | `docker rm ollama` — container only |

Post-removal verification: canonical containers healthy; `ollama_ollama-data`
still present; all three models available; manifest tree SHA-256 still
`a5ddc9d76b97…`; no `11434` listener; LiteLLM healthy. The
`ollama/ollama:latest` image was retained. Neither `ollama_ollama-data`,
`/opt/schott-platform-pre-git-backup`, nor any Docker volume was deleted.

### Final state

| Item | Value |
|---|---|
| `ai-ollama-1` | `ollama/ollama:0.11.4`, healthy, no published host port |
| `ai-litellm-1` | `litellm:main-v1.74.3-stable`, healthy, `0.0.0.0:4000->4000/tcp` |
| Volumes | `ollama_ollama-data` (external, adopted) |
| Models | `qwen3:8b`, `qwen3:30b`, `nomic-embed-text` |
| Disk | 96 G total, **41 G free** (56% used) |

## Known risks

1. **Ollama server downgrade: 0.32.4 → 0.11.4.** The legacy container ran a much
   newer Ollama than the pinned canonical image. The 0.32.4-written model store
   was read correctly by 0.11.4 — all three models load and infer, and the
   manifest tree hash is byte-identical before and after — so no damage
   occurred. But the pin is far behind what this host was running, and a future
   `ollama pull` under 0.11.4 may fetch differently-formatted artifacts. The pin
   deserves a deliberate review.
2. **UFW does not filter Docker-published port 4000.** Accepted for `v0.1.0`;
   mitigated by the absence of any public address or NAT exposure. Persistent
   `DOCKER-USER` policy is deferred to a separate network-hardening enhancement.
   See [the Task 8B limitation](#docker--ufw-filtering-limitation--accepted-for-v010).
3. **SSH is still allowed from `Anywhere`.** UFW rules `[1]` and `[4]`
   (`OpenSSH` IPv4 and IPv6) predate this work and were deliberately left in
   place as unrelated valid rules; the approved-range rule `[2]` was added
   alongside them. Real-world exposure is nil today (no public IPv4; IPv6 is a
   ULA), but this is broader than the documented management range. Tightening it
   is a follow-up decision — note that rule `[2]` is IPv4-only, so removing the
   IPv6 `OpenSSH` rule would break IPv6 SSH.
4. **Reasoning-model output.** `qwen3` emits `<think>` reasoning traces in
   completion content. Responses were non-empty and valid, but applications
   consuming `local-fast`/`local-general` will receive thinking text unless they
   strip it. An integration consideration, not a deployment defect.
5. **No outside-approved-range negative test.** No routed client outside
   `192.168.86.0/24` exists on this flat network, so blocking from outside the
   approved range was never empirically confirmed.

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

### Host adoption switch — applied

`ai/.env` on `schai` now sets `OLLAMA_VOLUME_EXTERNAL=true` alongside
`OLLAMA_VOLUME_NAME=ollama_ollama-data` (applied by the operator before Task
8B). Verified during Task 8B preflight: the rendered configuration shows
`external: true` on the adopted volume, and the Compose project-ownership
warning is gone. The adopted 23 GB is no longer removable by
`docker compose down -v`.

`ai/.env` remains mode `600`, owner `cschott:cschott`, git-ignored, with a
non-empty `LITELLM_MASTER_KEY`. No secret value was displayed at any point.

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
