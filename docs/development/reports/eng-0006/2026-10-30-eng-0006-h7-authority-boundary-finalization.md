# ENG-0006-H7 — Authority Boundary Finalization

**Date:** 2026-10-30
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `2b175765f847a3693d0f45db4652d00bb409b092` (H7 operator authority security preflight)
**Published remote:** `e47679c18ee8cb77156adea00cd0b48caaadb88a` (H6A)
**Nature:** Documentation and read-only verification. **No implementation authorization.**
**Recommendation:** **HOLD for H7 implementation. GO for the operator rulings in §10**, with O-1 approvable **only conditionally**: on the cessation of agent execution on schai, which this review itself contradicts today (§3.1).

> **Evidence classes.** **VERIFIED** — observed on this host by a read-only
> command or readable file. **DECLARED** — stated by the operator and not
> independently verified here. **INFERRED** — follows from verified facts plus
> documented upstream behaviour. **UNKNOWN** — the deciding artifact is not
> readable without privilege, or lies off-host.
>
> **Method boundary.** No `sudo` in any form. No Docker, LXD or Podman API call.
> No change to any user, group, service, SSH, sudoers, PAM, polkit or firewall
> setting. No secret, key, token or `authorized_keys` key material read. Only
> option prefixes and counts were extracted.

---

## 1. Repository preflight

| Gate | Result | Class |
|---|---|---|
| branch | `arch/eng-0006-health-runtime` | VERIFIED |
| HEAD | `2b175765f847a3693d0f45db4652d00bb409b092` ✓ | VERIFIED |
| remote | `e47679c18ee8cb77156adea00cd0b48caaadb88a` ✓ (`git ls-remote`) | VERIFIED |
| ancestry | +4 / −0, 0 merges: `239bd48` readiness → `064ff21` authority design → `c0acf6b` cross-plane review → `2b17576` security preflight; `e47679c..HEAD` touches 4 files, all reports | VERIFIED |
| worktree / index / stash / untracked | clean / empty / none / none | VERIFIED |
| H7 implementation files | none (`tools/health`: conditions, errors, freshness, hysteresis, `__init__`, records, store) | VERIFIED |
| `/var/lib/kyri/health` | absent | VERIFIED |

All four prior H7 reports were re-read. Nothing in the repository differs from
the expected state.

---

## 2. Operator architecture clarification

| Statement | Class |
|---|---|
| General sudo for `cschott` is `(ALL : ALL) ALL` | **DECLARED** (operator inspection, 2026-10-30). Consistent with the preflight's INFERRED stock policy |
| Exactly two digest-constrained Kyri `NOPASSWD` helpers; all sudoers files parse; no unexpected general `NOPASSWD` | **DECLARED**. Consistent with the preflight's VERIFIED helper digests (`0d9c8d8c…`, `2878fff0…`) |
| `cschott` ∈ `sudo`, `docker`, `lxd`; Docker active | **DECLARED** and **VERIFIED** |
| **"No autonomous agents are configured to execute on schai, and no agents will be deployed there. Agent activity is isolated outside this host."** | **DECLARED** as the intended deployment architecture. **Contradicted by the current execution path (§3.1)** |

The preflight's findings S-1…S-11 are **preserved, not withdrawn**. Under the
declared architecture they become *conditional* threats (§9). They become
*active* threats whenever an agent executes on schai, and §3.1 shows that one is
executing now.

---

## 3. Verified remote execution boundary

### 3.1 This review's own execution path — **reported first, as required**

**This review is being performed by an AI agent executing commands on schai.**

| Fact | Evidence | Class |
|---|---|---|
| the agent process | `claude` pid 3214087, running since 2026-10-28 08:04:45; `/proc/3214087/exe` → `/home/cschott/.local/share/claude/versions/2.1.280` (`cschott:cschott 0755`) | **VERIFIED** |
| where it sits | child of the operator's login `bash` (pid 3214017, `pts/0`), itself a child of `sshd` for a **password**-authenticated session from `192.168.86.x` | **VERIFIED** |
| what it does | runs every shell command in this review as `uid=1000(cschott)` with all of `cschott`'s groups, `sudo` and `docker` included, on schai (`hostname` → `schai`) | **VERIFIED** |
| model location | inference is remote: established TCP/443 to two external endpoints. **Tool execution is local** | **VERIFIED** (connections); endpoint ownership not asserted |
| self-updating | launcher `~/.local/bin/claude` → `versions/2.1.312` (relinked 2026-10-28 08:04) while 2.1.280 runs. Agent code on schai is replaced from the network, in a `cschott`-writable path, without review | **VERIFIED** |
| history | the project transcript directory held 17 `.jsonl` files on 2026-10-28; it now holds 2. That is consistent with operator pruning. Not investigated further | **VERIFIED** (counts) |

**Consequence.** The declaration describes an architecture that is **not the
present state of the host**. The model may well be "isolated outside this host",
but its *execution* is not: a remote model directs a local executor that holds
the operator's full OS authority. **This report does not and cannot claim schai
is agent-isolated.** Everything in §9 is evaluated twice: under the declared
architecture, and under the observed one.

### 3.2 Other execution surfaces

| Surface | Finding | Class |
|---|---|---|
| SSH keys | `~/.ssh/authorized_keys` is **0 bytes** (mtime 2026-07-27). Only `root` and `cschott` have login shells | **VERIFIED** |
| SSH authentication used | every `Accepted` event in the retained logs (2026-10-05 →) is `password for cschott from 192.168.86.x` (4 events); 0 `Failed password` | **VERIFIED** |
| SSH policy | `sshd_config`: `UsePAM yes`, `KbdInteractiveAuthentication no`, `X11Forwarding yes`, includes `sshd_config.d/*.conf`. `50-cloud-init.conf` is `root 0600` and unreadable, so `PasswordAuthentication`, `PermitRootLogin`, `AllowTcpForwarding`, `AllowStreamLocalForwarding` and `AllowAgentForwarding` effective values are **UNKNOWN**. Upstream defaults permit TCP, stream-local and agent forwarding | **VERIFIED** / **UNKNOWN** / **INFERRED** |
| forwarded credentials | `SSH_AUTH_SOCK` unset in the current session | **VERIFIED** (now only) |
| remote Docker | no TCP listener (`ss -tln`: only `:22`, `:4000` LiteLLM, loopback DNS). **But any SSH login as `cschott` reaches the socket**: locally, by stream-local forwarding of `/var/run/docker.sock`, or by `DOCKER_HOST=ssh://cschott@schai` | **VERIFIED** (listeners); SSH path **INFERRED** |
| remote LXD | not installed | **VERIFIED** |
| VS Code Remote-SSH | `~/.vscode-server` present (one server build, GitHub PR extension), last activity 2026-08-08; no process running | **VERIFIED** dormant. A client reconnecting would re-establish remote execution, including any IDE agent mode |
| Copilot | `~/.copilot` present (dated 2026-07-28); no process | **VERIFIED** dormant |
| CI/CD | 6 workflows, all `runs-on: ubuntu-24.04` (GitHub-hosted); no self-hosted runner, no deploy step, no SSH, no secret beyond `GITHUB_TOKEN` | **VERIFIED** |
| automation on host | no user crontab; no user systemd units; `Linger=no`; no `/etc/cron.d` or systemd unit references the repository or `kyri`; no runner, webhook or config-management process | **VERIFIED** |
| git hooks | no non-sample hook in `.git/hooks`; no `core.hooksPath`/`fsmonitor`/`pager`/`sshCommand` override | **VERIFIED** |
| `kyri-capability` | rootless Podman under its own user manager (uid 999), no supplementary groups | **VERIFIED** — the identity precedent for §6 |

### 3.3 The brief's questions

| Can an externally hosted agent… | Answer | Class |
|---|---|---|
| establish SSH sessions? | **only with `cschott`'s password.** No keys are authorized. Whoever holds the password (operator, or any tool or agent on the operator's workstation given it) can | VERIFIED / DECLARED (who holds it) |
| invoke remote shell commands? | **yes, today**: §3.1 is that exact path, operator-initiated | **VERIFIED** |
| use forwarded SSH credentials? | not in the current session; possible if a client forwards an agent and sshd permits it (UNKNOWN) | VERIFIED / UNKNOWN |
| access Docker or LXD remotely? | Docker **through any `cschott` SSH session**; LXD no | INFERRED / VERIFIED |
| reach privileged APIs or sockets? | through `cschott`'s groups: the Docker socket (root-equivalent) and `sudo` (password) | VERIFIED |
| modify operator approval evidence? | none exists yet. Once root-owned, only via root, and **root is reachable from `cschott` through Docker** | INFERRED |
| modify files later executed as root? | **yes**: the repository is `cschott`-owned, and root has executed scripts from it (preflight S-7) | VERIFIED |
| trigger privileged deployment? | no automation does; the operator runs ceremonies with `sudo` by hand | VERIFIED |
| execute through CI/CD, webhooks, automation? | **no** path found | VERIFIED |

**A network connection alone grants nothing here.** Execution authority comes
only from an authenticated `cschott` session, and today one such session hosts
an agent.

---

## 4. Privileged installation integrity

### 4.1 What the existing ceremonies already do well

`install-generation-24.sh` pins `COMMIT=2bda293b…` and `PREDECESSOR_COMMIT`. It
refuses unless the commit exists, is an ancestor of `HEAD`, is on the expected
branch, and the tree is clean (`:625-648`). It reads every payload as a **git blob
of the pinned commit**, through `runuser -u cschott -- git …` (`:451-453`), so git
configuration and hooks never execute as root. It compares blob digests to
reviewed constants (`:655-659`, `:1423`). The installed runtime lives under
root-owned `/usr/lib/kyri/python` and `/usr/libexec/kyri-exec-*` (VERIFIED,
preflight S-8).

### 4.2 The gap

**The ceremony script itself is executed by path from the `cschott`-writable
tree** (`sudo bash /opt/schott-platform/provisioning/execution/install-generation-24.sh`,
auth.log 2026-10-12, VERIFIED). Every check in 4.1 is code inside that file. An
edit to the file before the operator types `sudo` replaces the checks along with
everything else. The same holds for `sudo python3 -c` run from the repository,
where the cwd shadows the standard library (VERIFIED by probe). **No repository
control can protect a file that the attacker can rewrite before it is read.**

### 4.3 Secure deployment workflow — **[PROPOSED], NOT IMPLEMENTED**

| Stage | Action | Control | Enforceable? |
|---|---|---|---|
| 1 Development | on a branch; any tooling | — | — |
| 2 Review | independent review approves a **commit SHA** and an **artifact manifest** (path → sha256) produced from that commit | the manifest is recorded in the review record, outside schai | procedural |
| 3 Immutable source | `git archive <SHA>`, run as `cschott` via `runuser`, produces a tar | the tar's sha256 must equal the reviewed value; mismatch halts | **yes** at stage 4 |
| 4 Bootstrap | the **only** step that touches root using unreviewed code is a short, fixed command sequence of **root-owned system binaries**, typed or pasted from the review record. `sudo install -d -o root -g root -m 0700 /root/kyri-stage/<SHA>`; `sudo sha256sum -c` against the reviewed manifest; `sudo tar -x --no-same-owner --no-same-permissions -C /root/kyri-stage/<SHA>` | no repository script runs as root before its digest is checked against an independent record | **yes**, given secure_path and env_reset (stock defaults; **DECLARED** policy, values **UNKNOWN**) |
| 5 Install | from the root-owned stage into root-owned destinations (`/usr/libexec/kyri-*`, `/usr/lib/kyri/<component>`), every ancestor `root:root`, not group- or world-writable; files `0555`/`0444` | `namei -l` on each destination; `install -o root -g root` | **yes** |
| 6 Execute | **only** installed artifacts. Python as `#!/usr/bin/python3 -I` (no cwd, no `PYTHON*` variables, no user site). Shell with `set -Eeuo pipefail`, `PATH=/usr/sbin:/usr/bin:/sbin:/bin` set explicitly, `cd /`, no `source` of any non-root file. Payloads and inputs read through descriptors (`O_NOFOLLOW`) | **yes** |
| 7 Verify | re-hash installed files against the reviewed manifest, re-run `namei -l`, and record both in the next report | **yes** (detection) |

Risk-by-risk:

| Risk | Control |
|---|---|
| Python import shadowing | `-I`; imports only from stdlib and root-owned `/usr/lib/kyri/python`; never `sudo python3 -c` in a user directory |
| writable dependencies | every imported file and ancestor root-owned: `find <root> -writable` as `cschott` must be empty (as `/usr/lib/kyri/python` already is) |
| `PATH` manipulation | explicit `PATH` in every root script; absolute paths for `git`, `sha256sum` and `install` |
| symlink traversal | stage under `/root` (`0700`); `tar --no-same-owner`; refuse symlinks in the archive; destinations created with `install -d`; reads via `O_NOFOLLOW` |
| TOCTOU | verify the tar digest, extract into a root-only stage, and verify extracted files **before** install. After stage 4, no step reads a `cschott`-writable path |
| unapproved repository change executed as root | stages 3–4: nothing from the repository executes as root unless its bytes equal a digest the reviewer recorded **off-host** |

**Residual:** the review record is the root of trust. If a reviewer approves a
SHA that an agent produced, the workflow faithfully installs it. That is a review
property, not an installation property.

---

## 5. Approval ceremony feasibility

### 5.1 Requirements against existing infrastructure

| Requirement | Achievable with existing infrastructure? | Technically enforceable or procedural |
|---|---|---|
| explicit operator action | yes: `sudo /usr/libexec/kyri-health-approve …` plus typed confirmation on `/dev/tty` | **enforceable** that *someone at a TTY* acted; **procedural** that it was the operator |
| authentication appropriate to the host | yes: `sudo` with `pam_unix` password (`/etc/pam.d/sudo` → `common-auth`, VERIFIED) | **enforceable**: single factor, and **the same password authenticates SSH** (§3.2) |
| reject non-interactive execution | yes: the helper opens `/dev/tty` and refuses if that fails. Agent shell subprocesses have no controlling TTY (VERIFIED) | **enforceable** against TTY-less callers; **not** against a process holding a TTY (§3.1: the agent CLI holds `pts/0`) |
| not rely on a reusable sudo ticket alone | partly: the typed digest-prefix confirmation is required per approval regardless of ticket. Eliminating ticket reuse needs `Defaults!/usr/libexec/kyri-health-approve timestamp_timeout=0`, a **sudoers change not authorized here** | confirmation **enforceable**; ticket elimination **future, enforceable** once applied |
| root-owned approval directory | yes: precedent `/var/lib/kyri/evidence root:root 0755` (VERIFIED) | **enforceable** against non-root; **not** against `cschott`→Docker→root |
| strict canonical JSON | yes: `canonical_json.parse` + `serialise(parse(b)) == b` | **enforceable**; the helper must carry a **root-owned copy** of the encoder (stdlib only) |
| bind evidence to exact bytes | yes: `approval_digest = sha256(file bytes)`; the operator computes the same with coreutils `sha256sum` | **enforceable** |
| verify before CHENV allocation | yes, in ingestion (cross-plane V1–V13 precede V14) | **enforceable** |
| ordinary Health writers cannot publish approvals | yes, **if** the Health writer is `kyri-health` with no `sudo`, no `docker` and no root path (§6) | **enforceable** for `kyri-health`; **not** for `cschott` (Docker) |
| reject duplicate / replayed requests | yes: the helper refuses an existing `<request_id>.json` (`link` → `EEXIST`) and a digest already published; ingestion refuses a reused `request_id` or a second CHENV per statement | **enforceable** for cooperating writers; **detectable** otherwise (`verify`) |
| preserve immutable evidence | yes: `0444`, `nlink=1`, no delete tool, `protected_hardlinks=1` | **enforceable** against non-root; **procedural** against root |
| fail closed on malformed or ambiguous input | yes: every stage refuses without defaults | **enforceable** |

**Verdict: every requirement is achievable with existing primitives.** Four
remain partly procedural:

- that the human is the operator;
- immunity from root;
- immunity from `cschott`'s Docker path;
- ticket elimination, until the sudoers change is applied.

### 5.2 What the ceremony is, and is not

It is **filesystem-enforced approval with OS-account attribution and a
human-presence check at a TTY**. It is **not** human identity authentication, and
**not** a cryptographic signature. A password prompt shows that someone knew a
password. A typed digest prefix shows that someone at a terminal saw a digest.
Neither binds a person to the bytes in a form that can be verified later, off
this host, against a key the person alone controls. **This report does not
present either as equivalent to a signature.**

### 5.3 Ceremony — **NOT IMPLEMENTED**

As preflight §6.3, unchanged, with two additions:

- **Pre-flight refusal:** run the ceremony only from a login session that hosts
  no agent process. This is checked *procedurally*, by the operator running `ps`.
  A helper-side process scan would be advisory theatre, since a hostile process
  can rename itself.
- **Encoder provenance:** the helper's canonical-JSON implementation is installed
  through §4.3 from the same reviewed commit that promotes it to `tools/common`
  (O-3), so the helper and ingestion share one reviewed source.

---

## 6. Health service identity contract — **[PROPOSED], NOT IMPLEMENTED**

| Element | Contract |
|---|---|
| identity | system user `kyri-health`: own group, **no supplementary groups** (not `sudo`, `docker`, `lxd` or `adm`), shell `/usr/sbin/nologin`, no password, no SSH. Precedent: `kyri-capability` (VERIFIED) |
| store | `/var/lib/kyri/health` `kyri-health:kyri-health 0700`; record files `0600`; created by the H18 ceremony. This **changes ENG-0006-D:746-747** (`cschott:cschott 0700`), so it needs ruling O-13 |
| approved read access | `/var/lib/kyri/health-approvals` `root:root 0755`, statements `root:root 0444`; `kyri-health` reads them through `trusted_source(expected_uid=0, require_single_link=True, maximum_bytes=65536, refuse_oversize=True)` |
| writer permissions | only `kyri-health` writes the store; `cschott` has **no** access (not even read). Readers that need the store (evaluators, `verify`) run as `kyri-health` |
| separation from approvals | `kyri-health` cannot write the approval directory: not root, no group path to root. **Enforceable**, unlike for `cschott` |
| can it modify its own policy evidence? | **no**: approvals are root-owned. It **can** write arbitrary CHENV records into its own store, bypassing ingestion |
| how ingestion receives evidence | the operator runs `sudo -u kyri-health /usr/libexec/kyri-health-ingest <request_id>` (password `sudo`). Ingestion opens `<request_id>.json` by derived name; no path argument. *Optional:* a narrow `NOPASSWD` grant `cschott ALL=(kyri-health) /usr/libexec/kyri-health-ingest ^REQ-…$`. It is safe in principle, because ingestion only consumes root-published approvals, but it is a sudoers change requiring its own ruling |
| failure audit | refusals write nothing to the store (ADR-0013's six families, no audit record). The audit trail is the `sudo` log line plus ingestion's structured refusal on stderr, sent to the journal (`logger -t kyri-health-ingest`, or `systemd-cat`). That is **audit evidence, root-tamperable** |
| unauthorized-write detection | `verify` (as `kyri-health`): every CHENV must have exactly one root-owned approval whose sha256 equals the record's `approval_digest`; chains satisfy W1–W5; `validate()` reports `.tmp` debris. A forged CHENV is detectable because forging a passing one needs a root-owned statement. Run at every ceremony and on an operator-chosen schedule |
| what this changes in the threat model | store bypass by **`cschott` processes becomes prevention** (they cannot write the store). Bypass by a compromised `kyri-health` process stays **detection** (preflight S-10, the lock is advisory) |

---

## 7. C1/C2 implementation prerequisites

### 7.1 C1

| Contract | Status | Prerequisite |
|---|---|---|
| strict JSON approval input | specified (preflight §9.3) | **canonical encoder in `tools/common`**: today `tools/common` holds only `containment`, `immutable_store`, `trusted_source`, `yaml_strict`, so it is **not done** (VERIFIED) |
| canonical payload verification | specified (cross-plane §8.2, revised by preflight §9.3) | same, plus the canonical-bytes rule |
| mandatory approval evidence | specified (cross-plane §9.1) | **schema amendment** (`approval` required) and model mirror (O-2) |
| immutable CHENV persistence | **implemented** (`HealthStore.write_record` → `write_atomic`, H6) | — |
| duplicate version-1 refusal | specified (cross-plane K-9, V12) | **lock** (below) |
| atomic write and readback | write **implemented**; readback verification specified (V16) | none beyond C1 code |

### 7.2 C2

| Contract | Status | Prerequisite |
|---|---|---|
| immutable supersession | specified | — |
| validated `supersedes` | today `_text` (`records.py:532-534`); specified as a CHENV identifier, same-subject, existing | model change |
| version progression | specified (W3) | model change |
| store-wide advisory lock | **absent**: `HealthStore` inherits the no-op seam (`immutable_store.py:245-252`); Fabric pattern at `fabric/store.py:199-302` | **`HealthStore` override** |
| active-chain derivation | specified (W1–W5) | — |
| concurrent successor refusal | specified with proof (cross-plane §9.4); tests L-1…L-12 (preflight §8.4) | lock |
| ambiguous-chain fail-closed | specified | ruling O-5 |
| recovery from written-but-unverified | specified (`committed-unverified`; approved replacement) | ruling O-5 |

### 7.3 `superseded_by` — confirmed never written

No Health code writes it: `records.py:532` only **validates** it if an input
supplies it, and `HealthStore` has no update method (VERIFIED by `grep`). The
Fabric states the released convention verbatim: *"`superseded_by` is never
written here, and is never written by any released operation for any record kind
— deriving the forward link is the released convention"* (`fabric/admission.py:1318-1322`,
also `:1430-1434`). The cross-plane proposal (move it to `forbidden_fields`) aligns
Health with that convention. It remains in CHENV `optional_fields` (`:97`) and
CHSTATE (`capability-health-state.schema.yaml:259`) until ruled (O-10).

### 7.4 Required changes, by kind

| Kind | Change |
|---|---|
| schema | CHENV: `approval` required; `superseded_by` forbidden; `supersedes` identifier rules; optional decimal grammar (O-12). CHSTATE `superseded_by` (O-10) |
| common library | promote `canonical_json` to `tools/common`, with a capability re-export and golden vectors (O-3) |
| Health | `HealthStore` lock override; `ingest`; `verify`; model mirror; guard pair entries |
| provisioning (H18-class, operator gate) | `kyri-health` user (O-13); `/var/lib/kyri/health` as `kyri-health 0700`; `/var/lib/kyri/health-approvals` and `.staging`; `/usr/libexec/kyri-health-approve` and `kyri-health-ingest` installed by §4.3; optional sudoers `timestamp_timeout=0` for the approve helper |

---

## 8. Remaining blockers

| # | Blocker | Kind |
|---|---|---|
| **B-F1** | **The declared agent isolation is not the current state**: an agent executes on schai with the operator's authority (§3.1) | operator decision O-11 |
| B-F2 | O-1, O-2, O-3, O-5, O-10, O-12, O-13 unruled | rulings |
| B-F3 | shared encoder promotion not done | implementation increment |
| B-F4 | CHENV schema amendment not done | schema increment |
| B-F5 | the privileged installation workflow (§4.3) is not adopted; repository scripts are still run as root | operator procedure + increment |
| B-F6 | `sshd_config.d/50-cloud-init.conf` effective settings UNKNOWN | operator-assisted read: `sudo sshd -T \| grep -E 'passwordauthentication\|permitrootlogin\|allowtcpforwarding\|allowstreamlocalforwarding\|allowagentforwarding'` |

---

## 9. Updated threat classification

"Declared" = under the declared architecture (no agent executes on schai).
"Observed" = as the host is today. The preflight's threats are preserved.

| # | Threat | Declared | Observed | After §4–§6 (and agents off-host) |
|---|---|---|---|---|
| T-1 | compromised `cschott` session | only via the operator's password (SSH = sudo password) | **active**: an agent holds such a session (§3.1) | approvals: P, except against Docker→root; store: P (`kyri-health`) |
| T-2 | agent invokes `sudo` | n/a | password-gated; 14 refusals logged (preflight) | P |
| T-3 | agent reuses a cached ticket | n/a | conditional: the agent CLI shares `pts/0` and the operator's session | P with `timestamp_timeout=0` + separate login (procedure) |
| T-4 | `NOPASSWD` privilege | two narrow helpers (DECLARED) | same | P (never `NOPASSWD` for approve) |
| T-5 | writable privileged helper / repo code as root | **active by practice** (S-7), whoever edits the tree | active | P (§4.3) |
| T-6 | agent-modified approval input | operator-authored only | **active** | P against a post-review swap (digest pin); residual: approving unread bytes |
| T-7 | approval evidence replaced | root only, or `cschott` via Docker (operator) | **any `cschott` process** via Docker | P against non-root and `kyri-health`; not against `cschott`/root |
| T-8 | forged `actor`/`approving_authority` | inherent | inherent | A only; needs crypto |
| T-9 | replay | — | — | P (cooperating) + D |
| T-10 | duplicate v1 | — | — | P (cooperating) + D |
| T-11 / T-12 | concurrent C1 / C2 | — | — | P (lock, cooperating) + D (`verify`) |
| T-13 | digest ambiguity | — | — | P (canonical bytes) |
| T-14 | missing approval | — | — | P (schema) + D |
| T-15 | Trust verifier unavailable | n/a (T0) | n/a | n/a |
| T-16 | root compromise | none | none | **none**: accepted only by ruling |
| **T-17** *(new)* | self-updating agent binary in a user-writable path on schai | n/a | **active** (2.1.280 → 2.1.312) | eliminated if agents leave schai |
| **T-18** *(new)* | dormant VS Code Server / Copilot re-enabled | n/a | dormant | eliminated if removed, or by procedure |
| **T-19** *(new)* | single password for SSH and sudo over password auth | **active** | active | residual; mitigation: SSH keys with `PasswordAuthentication no` (sshd change, not authorized here) |
| **T-20** *(new)* | SSH forwarding of the Docker socket | any `cschott` login | same | residual while `cschott` ∈ `docker` |

---

## 10. O-1 through O-13 decision matrix

| # | Question | Evidence | Recommendation | Ready? | Exact decision needed |
|---|---|---|---|---|---|
| **O-1** | Approve the root-controlled approval ceremony? | §5: all requirements achievable; four partly procedural. §3.1: an agent executes on schai now. S-1: `cschott` → Docker → root | **Approve conditionally** | **conditional** | *"Approved as the H7 approval mechanism, on condition that (a) no agent executes on schai: Claude Code and VS Code Server removed or disabled, verified by `ps` and directory listing in the next report; (b) approvals are performed only from a login session the operator has verified hosts no agent; (c) the helper is installed only by the §4.3 workflow; (d) the ceremony is understood as filesystem-enforced approval with OS-account attribution, not identity authentication or a signature."* |
| O-2 | `approval` required in CHENV | no host dependency | required | **yes** | approve or reject the schema amendment |
| O-3 | promote `canonical_json` | VERIFIED not yet in `tools/common`; the helper needs the same encoder | promote | **yes** | approve the shared-library increment |
| O-4 | Trust: T0 now | gateway store mode denies (VERIFIED); Trust adds no authentication | T0 | **yes** | confirm T0 |
| O-5 | ambiguous chain / `committed-unverified` | — | refusal + `review_required`; recovery by an approved replacement | **yes** | approve the behaviour |
| O-6 | S2 succession claims | lock advisory (S-10); `kyri-health` makes it moot for `cschott` | no | **yes** | confirm "no" |
| **O-7** | residual-risk acceptance | §9; §11 | — | **yes, for decision** | the operator must accept or reject **each** of R-1…R-9 (§11) individually. **None is accepted here** |
| O-8 | report K-1 to Trust | reconfirmed | yes | **yes** | confirm |
| O-9 | C1 + C2 as one increment | shared lock, chain and replay rules | one increment | **yes** | confirm |
| O-10 | `superseded_by` forbidden (CHENV and CHSTATE) | Fabric released convention (§7.3) | forbid and derive | **yes** | approve both schema changes |
| **O-11** | Dedicated local agent UID unnecessary? | the declaration says agents are off-host; **§3.1 shows one on-host** | **unnecessary only if agents stop executing on schai.** If on-host agent use continues, it is **necessary** | **yes, as a binary choice** | choose one: **(A)** cease agent execution on schai (remove `~/.local/share/claude`, `~/.local/bin/claude`, `~/.vscode-server`; engineering agents work on an off-host clone and deliver reviewed commits), so no agent UID is needed; or **(B)** continue on-host agents, so a dedicated agent UID with no `sudo`/`docker`/`lxd`/`adm` groups becomes **mandatory** before O-1 |
| O-12 | canonical decimal grammar | multiple spellings accepted (preflight §9.2) | adopt | **yes** | approve the model change |
| **O-13** | dedicated `kyri-health` UID | `kyri-capability` precedent (VERIFIED); converts `cschott` store bypass to prevention; makes "Health writers cannot publish approvals" enforceable | **appropriate, and recommended** | **yes** | approve `kyri-health` and the change to ENG-0006-D:746-747 store ownership, effective at H18 |

---

## 11. Residual risks requiring explicit operator acceptance

**None is accepted by this report.**

| # | Risk | Applies under | Mitigation available |
|---|---|---|---|
| R-1 | no human-identity authentication; `actor` and `approving_authority` are claims | always | cryptographic signing (Design A), out of scope |
| R-2 | the password that authenticates SSH also authenticates `sudo`; password SSH over LAN | always | keys + `PasswordAuthentication no` |
| R-3 | `cschott` → Docker → root without `sudo` or log: approval evidence is only as safe as every `cschott` session | always (DECLARED: only the operator) | remove `cschott` from `docker`, or rootless Docker |
| R-4 | root can rewrite approvals, records and logs consistently | always | off-host evidence / signing |
| R-5 | the operator approves bytes they did not read | always (human factor) | TTY rendering + typed confirmation (procedural strength) |
| R-6 | a cached sudo ticket within its timeout lets the helper run without a fresh password (typed confirmation still required) | until `timestamp_timeout=0` | sudoers per-command default |
| R-7 | a compromised `kyri-health` process forges CHENV records (detected, not prevented) | always | none beyond `verify` |
| R-8 | the review record is the root of trust for installation | always | independent reviewers |
| R-9 | **an agent executes on schai with operator authority** | **observed now** | O-11 (A) or (B) |

---

## 12. GO / HOLD

**HOLD — H7 C1/C2 implementation.** Prerequisites B-F3, B-F4 and the rulings in
B-F2 are outstanding.

**HOLD — the claim of agent isolation.** It is DECLARED, and the current
execution path contradicts it (§3.1). It becomes VERIFIED only after O-11 (A) is
carried out and re-inspected.

**GO — for operator rulings** O-2, O-3, O-4, O-5, O-6, O-8, O-9, O-10, O-12 and
O-13, for the O-11 choice, for individual decisions on R-1…R-9, and for O-1 **as a
conditional approval** worded as in §10.

**The honest summary.** The mechanisms are ready, and the remaining questions are
about principals. The ceremony delivers filesystem-enforced approval, attributed
to an OS account, with a presence check at a terminal. That is the most this
host can offer without keys, and it is meaningful **only if every process holding
`cschott`'s authority is the operator**. Today one is this review.

---

=== REVIEW PACKAGE ===

**Task:** ENG-0006-H7 authority boundary finalization. Documentation and
read-only verification.

**Files Changed:**
`docs/development/reports/eng-0006/2026-10-30-eng-0006-h7-authority-boundary-finalization.md`
(new). Nothing else.

**Tests Executed:** documentation and static suites, with counts in the commit
message and handoff. The full regression was **not** run.

**Commands Run (read-only):**

- `git rev-parse`, `ls-remote`, `status`, `log`, `diff --stat`, `config --get-regexp`
- `ps`, `/proc/<pid>/exe`, `tty`, `who`, `hostname`, `ss -tnp`/`-tlnp`, `getent`
- `stat`, `ls`, `find -newermt` (metadata only); `crontab -l`,
  `systemctl --user`, `systemctl list-timers`, `loginctl show-user`
- reads of `/etc/ssh/sshd_config`; `authorized_keys` option/type counts only
- `zcat`/`grep` over `/var/log/auth.log*` (accepted-auth method and subnet only)
- `grep` over `.github/workflows`, `/etc/systemd`, `/etc/cron.d`,
  `provisioning/execution/install-generation-24.sh` and `tools/`

**Not run:** no `sudo`, no container API, no configuration change, no
secret or key read.

**Known Risks:** R-1…R-9 (§11). R-9 is observed, not hypothetical.

**Architecture Decisions:** none taken. The installation workflow (§4.3) and
`kyri-health` contract (§6) are proposals.

**Questions for Reviewer:** O-1…O-13 (§10); B-F6 operator-assisted `sshd -T`.
