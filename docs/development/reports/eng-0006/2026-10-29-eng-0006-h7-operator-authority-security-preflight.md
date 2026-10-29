# ENG-0006-H7 — Operator Authority Security Preflight

**Date:** 2026-10-29
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `c0acf6b63ecf1404a295f5346e9ead0e03b82ea8` (H7 cross-plane authority review)
**Published remote:** `e47679c18ee8cb77156adea00cd0b48caaadb88a` (H6A)
**Nature:** Read-only host security preflight. **Documentation only — no implementation authorization.**
**Recommendation:** **HOLD.** H7 implementation stays held, and the root-controlled approval ceremony is **not feasible on this host as currently configured**. The account every agent runs as can become root without `sudo`, without a password and without a `sudo` log entry, through rootful Docker (§3.4). The cross-plane review's **O-1 and O-7 cannot responsibly be approved** until §13's prerequisites P-1 and P-2 are met.

> **Evidence classes.** **VERIFIED** — observed directly on this host by a
> read-only command, a readable file, or an unprivileged scratch probe whose
> output is quoted. **INFERRED** — follows from verified facts plus documented
> upstream behaviour, but the deciding artifact was not observed. **NOT
> OBSERVABLE** — the deciding artifact cannot be read without privilege; it is
> reported as unknown, never as absent.
>
> **Method boundary.** No `sudo` was executed in any form (`-v`, `-k`, `-K`,
> `-n`, `-l`, `-V` included). No container was started, no Docker or LXD API was
> called, no service was touched, and no credential, token, key or session
> secret was read. Probes ran as `cschott` in the session scratchpad, outside
> the repository, against temporary directories. One was a module-shadowing
> demonstration: an unprivileged `python3` loading a scratch `json.py`.

---

## 1. Verified repository and host state

| Gate | Result | Evidence |
|---|---|---|
| repository / branch | `/opt/schott-platform`, `arch/eng-0006-health-runtime` | `git rev-parse --abbrev-ref HEAD` — VERIFIED |
| local HEAD | `c0acf6b63ecf1404a295f5346e9ead0e03b82ea8` ✓ | `git rev-parse HEAD` — VERIFIED |
| remote | `e47679c18ee8cb77156adea00cd0b48caaadb88a` ✓ | `git ls-remote origin refs/heads/arch/eng-0006-health-runtime` — VERIFIED |
| ancestry | +3 / −0; 0 merges; `e47679c..HEAD` = readiness `239bd48`, authority design `064ff21`, cross-plane review `c0acf6b` | `git log`, `git rev-list --merges` — VERIFIED |
| diff since remote | exactly the three H7 reports, +2217 lines, nothing else | `git diff --stat e47679c..HEAD` — VERIFIED |
| worktree / index / stash | clean / empty / none; 0 untracked | `git status --porcelain=v2`, `git stash list` — VERIFIED |
| H7 implementation files | none: `tools/health/` holds `conditions errors freshness hysteresis __init__ records store` only | `ls tools/health` — VERIFIED |
| `/var/lib/kyri/health` | **absent** | `ls -ld` → ENOENT — VERIFIED |
| host | `schai`, Linux `6.8.0-139-generic`, Ubuntu 24.04, root fs ext4 on LVM; `/opt` and `/var/lib` are one filesystem | `uname -r`, `findmnt` — VERIFIED |
| sudo package | `1.9.15p5-3ubuntu5.24.04.4`, upgraded `2026-10-08 06:28:50` | `dpkg-query`, `/var/log/dpkg.log` — VERIFIED |

All three unpublished H7 reports were read before the host assessment began.

---

## 2. Summary of findings

| # | Finding | Class | Consequence |
|---|---|---|---|
| **S-1** | `cschott` is in `docker`. `dockerd` is **rootful**, runs as root, has no `userns-remap`, and its socket is `root:docker 0660`. Docker group membership is root-equivalent | **VERIFIED** (configuration); escalation **not exercised** | any `cschott` process can obtain root **without `sudo`, without a password, and without an `auth.log` entry**. This defeats every "root-owned, therefore not agent-writable" control in the cross-plane design |
| **S-2** | Agents run as `cschott` (1000) with **every** supplementary group (`adm sudo lxd docker …`), `NoNewPrivs: 0`, no seccomp, no sandbox, and an empty capability set | **VERIFIED** | agents hold exactly the operator's OS authority |
| **S-3** | The repository's `.claude/settings.local.json` pre-approves `Bash(docker run *)`, `docker exec *`, `docker rm *` and `sudo -n true`. This session runs in bypass-permissions mode with `skipDangerousModePermissionPrompt: true` | **VERIFIED** | the agent tool layer adds no barrier in front of S-1. The settings file is itself `cschott`-writable |
| **S-4** | Every agent `sudo -n` on record was **refused** (`a password is required`, no TTY), including one **5 min 45 s** after the operator's own successful `sudo` on `pts/1` | **VERIFIED** (auth.log ↔ transcript, timestamps equal to the second) | ticket reuse by agent shell subprocesses was not observed |
| **S-5** | Agent shell subprocesses run in a **new session with no controlling TTY**. The agent CLI process itself sits on `pts/0` inside the operator's SSH login session | **VERIFIED** | a TTY-scoped `sudo` ticket created on `pts/0` would be keyed to the CLI's own session (§4.3) |
| **S-6** | `/etc/sudoers` and all of `/etc/sudoers.d/*` are `root:root 0440` and **unreadable** | **VERIFIED** | general `NOPASSWD` status and `timestamp_timeout` / `timestamp_type` are **NOT OBSERVABLE** |
| **S-7** | Root has executed `provisioning/execution/install-generation-2{3,4}.sh` **from the `cschott`-owned working tree**, and `python3 -c` with `PWD=/opt/schott-platform`. Both are agent-writable code paths into root | **VERIFIED** (auth.log); shadowing mechanism **VERIFIED** (unprivileged probe) | a privileged ceremony run from the repository runs whatever an agent last wrote there |
| **S-8** | The two installed `NOPASSWD` helpers are digest-matched to their reviewed grants and resolve imports only from root-owned `/usr/lib/kyri/python` | helper digests **VERIFIED**; grant text **INFERRED** | a good precedent for an approval helper, and **not** to be copied for approvals (§5.6) |
| **S-9** | YAML 1.1: `min_samples: 012` parses as **10**, `seconds: 2:00` as **120**, and `parse()` accepts both. A 393-byte aliased YAML expands to **46.9 MB** of canonical JSON | **VERIFIED** | the cross-plane review's YAML approval statement is withdrawn (§8) |
| **S-10** | `flock` is advisory. The kernel has no mandatory locking, and a same-UID writer committed a record while the lock was held | **VERIFIED** | the C1/C2 lock is prevention **for cooperating writers only** (§7) |
| **S-11** | The gateway store-mode denial (K-1) and the `HealthStore` non-exclusive section (K-8) are **reconfirmed** on the current tree. Neither file has changed since `87cc597` | **VERIFIED** | unchanged conclusions |

---

## 3. Operator account privilege findings

### 3.1 Identity

```
uid=1000(cschott) gid=1000(cschott)
groups=1000(cschott),4(adm),24(cdrom),27(sudo),30(dip),46(plugdev),101(lxd),988(docker)
```

`id`, `getent group` — **VERIFIED**. The `sudo`, `adm`, `docker` and `lxd`
groups each have `cschott` as their only human member (`adm` also lists
`syslog`). The service account `kyri-capability` (uid 999, gid 987, no
supplementary groups) exists and runs 4 processes. That is a **live precedent
for a dedicated, unprivileged Kyri service UID**.

### 3.2 Login context

One login: `cschott pts/0`, remote SSH (`loginctl`: `Remote=yes Type=tty
Active=yes`). `SSH_AUTH_SOCK` unset, so no agent forwarding. `SUDO_ASKPASS`
unset. — **VERIFIED**.

### 3.3 Privilege paths

| Path | Evidence | Class | Needs password? | Logged in `auth.log`? |
|---|---|---|---|---|
| `sudo`, general rules | membership of `sudo` (27). `/etc/sudoers` is 1800 B, its mtime is the package's (`2024-01-29 11:09:56`), and its ctime equals the dpkg upgrade instant (`2026-10-08 06:28:50`). That fits an **unmodified conffile** replaced by the upgrade. Stock Ubuntu grants `%sudo ALL=(ALL:ALL) ALL` | grant **INFERRED**; file content **NOT OBSERVABLE** | yes, if stock: **INFERRED** | yes |
| `sudo`, `kyri-exec-launch` | `root:root 0440`, 482 B, created `2026-09-04 18:21:39`. The reviewed text (`docs/development/reports/eng-0005/2026-09-03-g11-ba-sudoers-and-final-invoke-preflight.md:256-258`) is `cschott ALL=(root) NOPASSWD: sha256:0d9c8d8c…ede51a1 /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$`. The installed helper hashes to exactly `0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1` | helper **VERIFIED**; installed grant **INFERRED** | **no** (narrow) | yes |
| `sudo`, `kyri-exec-reconcile` | `root:root 0440`, 487 B. Reviewed text at the same report, lines 268-270. Installed helper hashes to `2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77` | helper **VERIFIED**; grant **INFERRED** | **no** (narrow) | yes |
| **Docker** | `/var/run/docker.sock root:docker 0660`; `dockerd` runs as `root`; `/etc/docker/daemon.json` declares only the `nvidia` runtime, with **no `userns-remap`**; no rootless unit under `~/.config/systemd/user` | **VERIFIED** | **no** | **no** |
| LXD | group `lxd` (101) held, but no LXD snap, no deb and no socket | **VERIFIED** dormant | — | — |
| polkit | `49-ubuntu-admin.rules` and `50-default.rules`: admin = `unix-group:sudo` (`auth_admin`, password). Password-free YES only for `packagekit.upgrade-system` / `trigger-offline-update` and `fwupd.update-internal`, and only for `subject.active && subject.local`, which this **remote** session is not. `/etc/polkit-1/rules.d` is `root:polkitd 0750` | packaged rules **VERIFIED**; site rules **NOT OBSERVABLE**; `pkexec` not installed (**VERIFIED**) | yes / n/a | journal |
| root-executed repo code | auth.log: `COMMAND=/usr/bin/bash /opt/schott-platform/provisioning/execution/install-generation-23.sh` (2026-10-05, ×4) and `…install-generation-24.sh` (2026-10-12, ×6); `COMMAND=/usr/bin/python3 -c 'import json,sys; …'` with `PWD=/opt/schott-platform` (2026-10-08, ×2) | **VERIFIED** | (operator's password) | yes, but not *what* the script contained |

### 3.4 S-1, stated plainly

Docker's own documentation treats the `docker` group as granting root-level
privileges, because a container can bind-mount `/` from the host. On `schai` that
group is held by `cschott`, and therefore by every agent process (§4.1). The
daemon is rootful and not user-namespace-remapped. **This was not exercised**, as
exercising it is outside this authorization. It is reported from configuration
alone, and that is sufficient: the property follows from the daemon's design, not
from a bug.

**Consequence for H7.** The cross-plane design separates P-health (`cschott`)
from P-root (root) and treats `sudo`'s password as the boundary. On this host
there is a second path from `cschott` to root, with no password, no `sudo` and no
`auth.log` entry. Any control of the form "only root can write X" is therefore
"only root **or any `cschott` process** can write X". **The root-controlled
approval ceremony cannot be made to exclude agents while S-1 holds.**

---

## 4. Sudo policy and credential-cache findings

### 4.1 Policy sources

| Source | Readable? | Content |
|---|---|---|
| `/etc/sudoers` | no | **NOT OBSERVABLE**; stock (INFERRED, §3.3) |
| `/etc/sudoers.d/kyri-exec-launch`, `kyri-exec-reconcile`, `README` | no | grants **INFERRED** from reviewed text and helper digests |
| `/etc/sudo.conf` | yes | no active (non-comment) directive: default plugins **VERIFIED** |
| `/etc/pam.d/sudo` → `common-auth` | yes | `pam_unix.so nullok` → `pam_deny` → `pam_permit` → `pam_cap` (optional). No `pam_ssh_agent_auth`, no `pam_succeed_if` bypass, no second factor — **VERIFIED** |
| `/run/sudo/ts` | metadata only | `root:root 0700`; contents **NOT OBSERVABLE** |
| `/var/log/installer/autoinstall-user-data` | no (`root 0400`) | whether autoinstall wrote a sudo rule is **NOT OBSERVABLE** |

### 4.2 NOPASSWD

- **Present, narrow, two commands:** INFERRED with strong support (§3.3).
- **General `NOPASSWD`: NOT OBSERVABLE.** It is *not* reported as absent. The
  positive evidence available is behavioural. Every agent `sudo -n` on record was
  refused with `a password is required` for `/usr/bin/sha256sum` (2026-10-05),
  `true` (10-06), `ls`, `find`, `cat` (10-09), `test` (10-12, 10-13) and `cat`
  (10-12). So **at those instants, for those commands, from a TTY-less context,
  no rule waived authentication**. VERIFIED for those observations only. That is
  not proof that no other rule, command or context is `NOPASSWD`.

### 4.3 Credential cache: timeout and scope

| Property | Finding | Class |
|---|---|---|
| `timestamp_timeout` | upstream default 15 min; the site value is in an unreadable file | **NOT OBSERVABLE**; default INFERRED |
| `timestamp_type` | upstream default `tty` since 1.8.x: a ticket is keyed to the terminal **and the session (leader and start time)**; with no TTY, sudo falls back to a parent-process record | **INFERRED** (site value unreadable) |
| agent shell subprocesses | `tty` → `not a tty`; `ps`: own session (`SID == PID`), `TT ?`, stdin `/dev/null` | **VERIFIED** |
| agent CLI process | `claude` pid 3214087, `TT pts/0`, `SID 3214017` = the operator's login `bash` | **VERIFIED** |
| observed reuse | 2026-10-12: operator `sudo` on `pts/1` at 09:33:53–09:34:12 (a Generation-24 installation); agent `sudo -n` at 09:39:39 from no TTY → **refused** | **VERIFIED** events; that the refusal was *because of* TTY scoping is **INFERRED**. 5 min 45 s is inside the default timeout, so either the scoping or a shorter timeout explains it |
| keystroke injection into the operator's TTY | `dev.tty.legacy_tiocsti = 0` | **VERIFIED** disabled |
| ptrace of the operator's shell | `kernel.yama.ptrace_scope = 1` (descendants only); the agent is a *child* of the login shell, not a parent; `sudo` is setuid | **VERIFIED** settings; inability **INFERRED** |

**What this means.** Ticket reuse by agent *shell commands* is **unlikely and was
not observed**, provided the site keeps the TTY default. The residual cache
exposure is narrower than the cross-plane review's RR-1 said: if the operator
authenticates `sudo` **on the same TTY and in the same session as the agent CLI**,
any process in that session holding that TTY could ride the ticket. The CLI
itself is such a process, and so is any child it spawns *without* `setsid`.
Running the ceremony in a **separate SSH login** (a separate session and TTY)
avoids even that. **All of this is secondary to S-1**, which needs no ticket at
all.

---

## 5. Agent execution boundary

### 5.1 The eight questions

| # | Question | Answer | Class |
|---|---|---|---|
| 1 | effective UID/GID | `1000/1000` (all four of real, effective, saved and fs) | **VERIFIED** (`/proc/$$/status`) |
| 2 | supplementary groups | `4 24 27 30 46 101 988 1000`, identical to the operator's | **VERIFIED** |
| 3 | shares the operator's login account? | **yes**: same UID, and the CLI is a child of the operator's SSH login shell on `pts/0` | **VERIFIED** |
| 4 | can invoke local shell commands? | **yes**, without per-command approval in this session (bypass mode). 107 standing allow rules exist in the repo settings, including `docker run *` | **VERIFIED** |
| 5 | can modify files a privileged ceremony consumes? | **yes**: `/opt/schott-platform` is `cschott:cschott 0750`, `provisioning/` `0775`, `.git` `0775`. Root has executed scripts from there (S-7). The agent can also edit its own permission file | **VERIFIED** |
| 6 | can reach `sudo` or privileged helpers? | can **invoke** `sudo` (setuid works, `NoNewPrivs 0`), and has done so 42 times historically, all refused when authentication was required. Can invoke the two `NOPASSWD` helpers (narrow). **Can reach the Docker socket**, which is root-equivalent | **VERIFIED** (invocation) / **INFERRED** (helper grants) |
| 7 | terminal or session reuse exposes credentials? | not observed for shell subprocesses; possible in principle for the CLI process itself (§4.3) | **INFERRED** |
| 8 | can agent code influence an approval ceremony? | **yes, today, three ways**: (a) edit a ceremony script or Python module that root later runs (S-7); (b) edit the input the operator is about to approve; (c) become root through Docker (S-1) and write the approval directly | **VERIFIED** preconditions; (c) not exercised |

### 5.2 Observed behaviour versus capability

| Observed (from logs and transcripts) | Capability (not exercised) |
|---|---|
| agents ran `sudo -n` for read-only checks, and all were refused | root via `docker run` with a host bind-mount |
| no agent `sudo` succeeded in the retained logs (2026-10-05 → 10-29) | editing a ceremony script between operator review and `sudo bash` |
| agents edited repository files, including provisioning scripts later run as root (the ordinary ENG-0005 workflow) | shadowing a stdlib module for `sudo python3 -c` run from the repository |
| — | editing `.claude/settings.local.json` to widen the agent's own permissions |

**Retention limit.** `auth.log*` covers 2026-10-05 onward; earlier rotations are
gone. Absence before that date is **NOT OBSERVABLE**.

---

## 6. Root-controlled approval ceremony feasibility

### 6.1 Verdict

**Not feasible as a separation of agents from approval while S-1 holds.**
**Feasible in mechanism**: every primitive the ceremony needs exists and is
verified on this host. Once prerequisites P-1 and P-2 (§13) remove the
sudo-free root path from agent processes, the ceremony below separates agents
from approval **to the strength of `sudo`'s password and the operator's
procedure, and no further**.

### 6.2 Evaluation

| Concern | Finding | Class |
|---|---|---|
| root-owned directory | precedent live: `/var/lib/kyri/evidence root:root 0755`; ancestors `/ /var /var/lib` root 0755, `/var/lib/kyri` `root:root 0711` | **VERIFIED** |
| traversal | `0711` lets `cschott` traverse `/var/lib/kyri` but not list it. Ingestion opens a known name and needs no listing | **VERIFIED** |
| ownership and modes | statements `root:root 0444`, directory `root:root 0755`: readable by the Health runtime, writable by no one but root | precedent **VERIFIED** |
| atomic publication | link-into-place: write a temporary in a root-only `0700` staging directory → `fsync` → `fchmod 0444` → `link()` to the final name, which refuses an existing name → unlink the temporary → `fsync` the directory | pattern **VERIFIED** in `immutable_store.write_atomic` and `install-host-evidence.sh` |
| approved-input containment | `trusted_source.open_trusted_regular_file` opens the root and every component `O_NOFOLLOW` via `openat`, checks owner, mode and file type through the **descriptor**, and enforces `nlink == 1` and a size bound (`tools/common/trusted_source.py:109-186`). **Caveat:** the approved root's *own ancestors* are resolved normally and not ownership-checked, so the ceremony must verify them (`namei -l`) | **VERIFIED** |
| symlinks | `O_NOFOLLOW` on every component; `fs.protected_symlinks = 1` | **VERIFIED** |
| hard links | `fs.protected_hardlinks = 1`: `cschott` cannot hard-link a root-owned `0444` file it cannot write; `require_single_link=True` refuses any second link; `fs.protected_regular = 2` | **VERIFIED** |
| TOCTOU, approval → ingestion | the statement is immutable once published; ingestion reads one descriptor that it checked | **closed** while root is not reachable by agents |
| TOCTOU, review → approval | **open by default**: the operator reviews a file in an agent-writable place, and the agent can swap it before the privileged read. **Closed by binding**: the operator computes `sha256sum` (coreutils, root-owned) over the bytes they reviewed and passes the hex to the helper, which refuses any mismatch | design; §6.3 |
| agent-controlled replacement of published evidence | impossible without root (directory and hard-link protections), **and possible today through S-1** | **VERIFIED** preconditions |
| safe reading by the Health runtime | yes: `0444` files under `0755`/`0711` directories, read through `trusted_source(expected_uid=0)` | **VERIFIED** precedent (`fabric/evidence_authority.py:108-190`) |
| operator approves agent-modified input | **inherent** if the operator approves bytes they did not read. Mitigation: the helper renders the decoded statement on the operator's TTY and requires typed confirmation of the digest prefix. Agents cannot type into that TTY (`legacy_tiocsti = 0`, VERIFIED) and have no TTY of their own | design; residual |
| helper abuse through arguments | mitigated by taking **no path argument**: statement bytes on stdin (opened by the operator's unprivileged shell), `request_id` matched against a regex, `sha256` matched against `^[0-9a-f]{64}$`, nothing else | design |
| helper abuse through writable dependencies | the S-7 pattern must not recur. Helper at `/usr/libexec/kyri-health-approve`, `root:root 0555`, `#!/usr/bin/python3 -I` (isolated: no cwd or `PYTHONPATH` on `sys.path`; VERIFIED by probe), **stdlib only** or `/usr/lib/kyri/python` only, installed from a pinned commit blob as the existing helpers were | precedent **VERIFIED** (S-8) |

### 6.3 Proposed directory and permission model — **NOT IMPLEMENTED**

```
/var/lib/kyri                              root:root  0711   (exists)
/var/lib/kyri/health-approvals             root:root  0755   NOT IMPLEMENTED
/var/lib/kyri/health-approvals/.staging    root:root  0700   NOT IMPLEMENTED
/var/lib/kyri/health-approvals/<request_id>.json
                                           root:root  0444  nlink=1   NOT IMPLEMENTED
/usr/libexec/kyri-health-approve           root:root  0555   NOT IMPLEMENTED
```

Ceremony, from a **separate SSH login** that hosts no agent:

1. Operator renders the candidate for reading with root-owned system tools only
   (`python3 -I -m json.tool < candidate.json`). Kyri code that an agent can edit
   is **not** in the review path.
2. Operator runs `sha256sum candidate.json` and records the hex.
3. `sudo /usr/libexec/kyri-health-approve <request_id> <sha256> < candidate.json`.
   The helper:
   - refuses without a controlling TTY;
   - reads stdin once, bounded;
   - refuses on digest mismatch;
   - refuses bytes that are not exactly canonical (§8.3);
   - shows the decoded subject, version, `supersedes` and per-dimension
     thresholds on `/dev/tty`;
   - requires the operator to type the first 12 hex digits;
   - publishes by link-into-place;
   - verifies by re-opening through the same rules ingestion uses.

   It **does not** write the Health store, call Kyri runtime code, or repair
   anything.
4. Unprivileged ingestion as in the cross-plane review §7.2, with
   `trusted_uid=0`.
5. **No sudoers rule is added.** The helper runs under the operator's general,
   password-authenticated `sudo`. A `NOPASSWD` grant would hand approval to every
   `cschott` process, which is the opposite of the purpose.

### 6.4 What the ceremony establishes

| Property | Established? |
|---|---|
| **filesystem-enforced approval** | **yes**: only root can create a statement. *Today root is reachable by agents (S-1)* |
| **OS-account attribution** | **partly**: `auth.log` records `cschott : TTY=pts/N ; COMMAND=/usr/libexec/kyri-health-approve REQ-…`. That names the account, not the person, and root can tamper with it |
| **human presence** | **weakly**: typed confirmation on a TTY that agents cannot write. It shows that something at that terminal typed it |
| **human identity authentication** | **no** |
| **cryptographic approval** | **no**: no key, no signature, nothing verifiable off-host |
| **Trust authorization** | **no**: Trust is not consulted (§7) |

These are five different properties, and none implies another.

---

## 7. Trust integration implications

**Gateway limitation reconfirmed.** Re-running the cross-plane probe on the
current tree gives the same results. Direct `evaluate_subject` with four
dimensions returns `True`. `gateway.query()` returns `allowed=False` in all six
domains, reason `no capability was supplied; every dimension must be named
because scope is deny-by-default`. Source: `tools/trust/gateway.py:152-155`,
`tools/trust/query.py:171-183`, `tools/trust/scope.py:138-150`, unchanged since
`87cc597`. **VERIFIED. Not modified.**

**Can H7 run with the root ceremony and Trust deferred?** **Yes, architecturally.**
O-4/T0 needs no Trust read. ADR-0013 R12 *permits* a read-only Trust adapter; it
does not *require* one. Nothing in the governing requirements makes Trust a
precondition of C1. Deferring Trust loses pre-ingestion revocation and the Trust
audit trail. It loses **no authentication**, because Trust provides none: its
write gate is the same `cschott 0700` filesystem ownership (cross-plane §4.3).
Under S-1 a Trust approval record would be forgeable by the same agents that can
forge a root-owned statement.

---

## 8. Health locking assessment

### 8.1 Cause of the reported finding

`HealthStore` (`tools/health/store.py:92-247`) does not override
`request_critical_section`, so it inherits
`tools/common/immutable_store.py:245-252`: a context manager whose body is
`yield`. **There is no lock.** A second caller entering while the first holds the
section is the specified behaviour of the base seam ("a behavioural no-op here").
Reconfirmed by probe on the current tree. **VERIFIED.**

### 8.2 The questions

| Question | Answer | Class |
|---|---|---|
| advisory or mandatory? | **advisory.** `fcntl.flock`; Linux 6.8 has no mandatory locking (`CONFIG_MANDATORY_FILE_LOCKING` absent from `/boot/config-6.8.0-139-generic`; upstream removed it in 5.15) | **VERIFIED** |
| can every H7 writer be required to participate? | **only by construction, not by enforcement.** The only CHENV write path will be `ingest_envelope`, and `write_record` stays public. A test can assert that no other in-tree module calls `write_record("capability-health-envelope", …)`. Nothing can make an out-of-tree process participate | design |
| is the Fabric mechanism reusable? | **yes, as a pattern**: `fabric/store.py:199-206,249-302`, a store-global, non-reentrant `LOCK_EX` on `sequences/request_identity.lock`, owner-checked, with a contention test seam. Not importable into Health (guard F-1, and it belongs to another plane), so it is restated in `HealthStore` or promoted to `ImmutableStore` as an opt-in | **VERIFIED** source |
| can a compromised same-UID process bypass it? | **yes.** A probe holding `LOCK_EX` while a second process created `CHENV-0002.yaml` with `O_EXCL` succeeded: "bypass writer committed a record while the lock was held" | **VERIFIED** |
| would filesystem controls materially improve it? | **yes, substantially**: a dedicated store UID (`kyri-health`, on the `kyri-capability` precedent) owning `/var/lib/kyri/health 0700`, with ingestion run as that UID. Same-UID bypass then needs that UID or root, rather than any `cschott` process. Only effective together with P-1 | design; precedent **VERIFIED** |

### 8.3 C1/C2 locking contract — **[PROPOSED]**

1. `HealthStore.request_critical_section(request_id)` acquires `LOCK_EX` on
   `<root>/sequences/request_identity.lock`. It is store-global, created `0600`,
   owner-checked, never read, never written and never deleted. `request_id` is
   never part of the lock name.
2. **Every** CHENV write, initial or replacement, holds it from replay lookup
   through head selection, allocation, write and readback (cross-plane §7.2
   V11–V16). Exactly one acquisition per operation; no nesting.
3. Directory state is re-read inside the section; nothing is cached across
   sections.
4. Refusals inside the section write nothing. A crash releases the lock with the
   descriptor.
5. `allocate_id`'s sequence `flock` is a different file, so the two never nest.
6. **Stated limit:** this prevents races between cooperating writers. Against a
   same-UID adversary it provides nothing, and detection falls to `verify` (forks
   W4, unapproved records W5).

### 8.4 Negative-test plan

| # | Test | Expected |
|---|---|---|
| L-1 | two threads replace one head, the first held at a named seam after head selection | exactly one accepted; the other `envelope-not-head`; one new file |
| L-2 | two processes, same | same; proves a cross-process lock, not a thread lock |
| L-3 | two concurrent `initial` envelopes for one subject | one accepted; other `envelope-subject-exists` |
| L-4 | same `request_id` + same digest, concurrently | one accepted; other `exact_replay` naming the same CHENV |
| L-5 | same `request_id`, different digest, concurrently | one accepted; other `request_identity_conflict` |
| L-6 | holder raises inside the section | lock released; next caller proceeds |
| L-7 | holder process killed (`SIGKILL`) inside the section | lock released by the kernel; next caller proceeds |
| L-8 | re-entrant acquisition attempt | refused or detected by a guard, never a silent deadlock (the Fabric documents the hang) |
| L-9 | lock file replaced by a symlink, or owned by another UID | store refuses |
| L-10 | static: no module other than ingest calls `write_record` for CHENV | AST assertion |
| L-11 | **bypass documented**: a direct `O_EXCL` write while the lock is held succeeds, and `verify` then reports the fork or the unapproved record | asserts *detection*, so the suite cannot be read as claiming prevention |
| L-12 | contention seam fires only when actually contended | positive-event synchronisation, no sleeps |

---

## 9. Canonical digest assessment

### 9.1 Existing implementations, exact differences

| Implementation | Non-ASCII | Floats | NaN/Inf | Integer range | Non-string keys | `datetime`/other | Fallback |
|---|---|---|---|---|---|---|---|
| `fabric/request_identity.py:232,403` | `\uXXXX` escaped | finite allowed | **refused** (`allow_nan=False` plus a pre-check) | unbounded | **refused** | **refused** | none |
| `trust/models.py:174-196` | escaped | allowed | **emitted as `NaN`** (default `allow_nan`) | unbounded | **coerced** `str(k)` | `isoformat()`, `Enum.value`, `.to_dict()` | coercion |
| `platform_model/evidence_fingerprint.py:98` | **literal UTF-8** | allowed | emitted as `NaN` | unbounded | int keys **silently stringified** by `json` | raises | none |
| `observation/evidence_builder.py:36` | escaped | allowed | emitted | unbounded | stringified | **`default=str`**: anything coerced | **coercion** |
| `integrity/snapshot_manager.py:81-82` | escaped | allowed | emitted | unbounded | keys pre-`str()`'d | **`default=str`** | **coercion** |
| `capability/execution/canonical_json.py:169-223` | **literal UTF-8**; U+0000 and lone surrogates refused | **refused** | **refused** | **signed 64-bit only** | **refused** | **refused** | none |

All sort keys; ordering by code point and by UTF-8 bytes agree. VERIFIED by
source and by `json.dumps` checks: `{"a":NaN}`, `{1:2}` → `{"1":2}`, and
`1.0` vs `1` encode differently.

### 9.2 Parsing hazards on the input side (YAML via `yaml_strict.loads_strict`)

| Hazard | Observed | Class |
|---|---|---|
| duplicate keys | refused | **VERIFIED** (H-series tests; `yaml_strict.py`) |
| YAML 1.1 octal | `012` → `10`; `parse()` **accepts** `min_samples: 012` as 10 | **VERIFIED** |
| sexagesimal | `1:20` → `80`; `seconds: 2:00` accepted as 120 | **VERIFIED** |
| boolean words | `yes` → `True`, `off` → `False` | **VERIFIED** |
| hex / underscores | `0x1F` → 31, `1_000` → 1000 | **VERIFIED** |
| floats | `.inf` → `inf`; `1e3` stays a *string* under YAML 1.1 | **VERIFIED** |
| timestamps | `2026-11-02` → `date`; refused by `_instant` (string required), but **accepted inside `provenance`** (cross-plane K-11) | **VERIFIED** |
| decimal-string spellings | `"2000"`, `"2000.0"`, `"2e3"`, `"+2000"`, `"02000"` all accepted as thresholds; `" 2000"` refused | **VERIFIED** |
| anchors / aliases | resolved. **393 B → 46,913,610 B** of canonical JSON at alias depth 6 (×119,373). The 64 KiB input bound does not bound the expansion | **VERIFIED** |
| non-canonical JSON | `canonical_json.parse` accepts `{"b":1,"a":2}` and `{ "a": 2 }`; only `serialise(parse(b)) == b` detects them | **VERIFIED** |

### 9.3 Recommendation — **one strict, versioned representation** — **[PROPOSED]**

**`kyri-strict-canonical-json/v1`, and the approval statement *is* that
encoding.** This revises the cross-plane review's §7.1 YAML statement, which is
withdrawn because of S-9.

- **Encoding:** exactly `canonical_json.serialise` (§9.1, last row), promoted to
  `tools/common` (O-3).
- **Statement file:** the canonical bytes of the statement object, with no
  `approval_digest` field inside it. **`approval_digest = "sha256:" + sha256(file
  bytes)`.** One digest, computable by `sha256sum` with no Kyri code involved.
  That is what lets the operator bind review to approval with a root-owned system
  tool (§6.3) rather than with agent-editable code. It also merges the
  cross-plane review's two digests (§8.3 there) into one.
- **Acceptance rule:** `canonical_json.parse(bytes, maximum_bytes=65536)` must
  succeed **and** `serialise(parsed) == bytes`. This refuses any second spelling.
  JSON has no anchors, aliases, implicit types, octal, sexagesimal or booleans by
  word.
- **Numbers:** integers only, signed 64-bit. Thresholds remain decimal
  **strings**. **Proposed tightening:** a canonical decimal grammar
  `^-?(0|[1-9][0-9]*)(\.[0-9]*[1-9])?$`, which refuses `+2000`, `02000`,
  `2000.0` and `2e3`, so each value has one spelling. That is a CHENV model
  change, so it needs a ruling (new O-12).
- **Included / excluded:** unchanged from the cross-plane review §8.2. The new
  record's `envelope_id` is excluded (generated after approval); `supersedes` is
  included; the statement's `request_id`, `actor`, `approving_authority`,
  `approved_at`, `operation` and `approval_domain` are included; versions are
  named.
- **Before allocation?** **Yes.** Every refusal (parse, canonical check, digest,
  schema, chain) happens before `allocate_id`. Readback reconstructs the
  statement object from the stored record and re-serialises it, and the digest
  must match.
- **Authoring:** operators may still *author* in YAML, but only into an
  unprivileged conversion tool. The converter is agent-editable, so its output is
  re-reviewed in canonical form (§6.3 step 1). **The YAML never reaches the
  privileged path.**

---

## 10. Threat matrix

P = prevention, D = detection, A = attribution, Au = audit evidence. "Today" =
current host configuration. "After" = with prerequisites P-1…P-5 (§13) and the
proposed contract.

| # | Threat | Preconditions | Existing controls (today) | Missing controls | Class today → after | Residual risk | Required mitigation | Verification evidence |
|---|---|---|---|---|---|---|---|---|
| T-1 | compromised `cschott` session | attacker code runs as 1000 | none against root (S-1) | P-1 | **none** → D (via `verify`), plus P for approvals | **high → medium** | P-1, P-3 | §3.3 Docker row; §5.1 |
| T-2 | agent invokes `sudo` | agent shell | password required: 14 refusals logged | general sudoers unreadable | P (observed) → P | low, if no general `NOPASSWD` | P-2: operator-assisted inspection | §4.2 auth.log |
| T-3 | agent reuses a cached ticket | operator authenticated in the same session and TTY as the CLI | TTY-scoped tickets (inferred); agent subprocesses have no TTY | separate login for ceremonies; `timestamp_timeout` unknown | P (inferred) → P, by procedure | low–medium | ceremony from a separate SSH login; read the timeout (P-2) | §4.3; S-4, S-5 |
| T-4 | `NOPASSWD` privilege | a rule covering a broad command | narrow digest-pinned rules only (inferred) | general rules NOT OBSERVABLE | unknown → P | unknown | P-2; never add `NOPASSWD` for approval | §3.3, §4.2 |
| T-5 | writable privileged helper | root runs code an agent can edit | the existing `/usr/libexec` helpers are root-owned with root-owned imports | repository scripts run as root (S-7) | **none** for repo scripts → P | **high → low** | P-4: helper root-owned, `python3 -I`, installed from a pinned blob; never `sudo bash <repo path>`, never `sudo python3 -c` from the repository | §3.3 auth.log; shadow probe |
| T-6 | agent-modified approval input | operator reviews a file in an agent-writable place | none | digest pin + TTY rendering + typed confirmation | **none** → P against a swap after review; **residual** if the operator approves unread bytes | medium (human factor) | §6.3 steps 1–3 | design |
| T-7 | root-owned approval evidence replaced | root write | dir and file modes; `protected_hardlinks`; `nlink == 1` | S-1 makes root reachable | **none** (S-1) → P against non-root; none against root | **high → low** | P-1 | §6.2 sysctls |
| T-8 | forged approval metadata (`actor`, `approving_authority`) | write access to a statement | — | identity authentication | A (claimed) → A (claimed) | **inherent** | Design A (crypto), out of scope | cross-plane §10.2 |
| T-9 | approval replay | resubmit a used statement | — (no H7 code) | `request_id` + digest rules | — → P (cooperating) + D | low | cross-plane V11; one CHENV per statement in `verify` | design |
| T-10 | duplicate envelope ingestion | second `initial` for a subject | — | subject-exists rule under the lock | — → P (cooperating) + D | low | cross-plane K-9, V12 | design; L-3 |
| T-11 | concurrent C1 submissions | two ingestions racing | **none**: the section is a no-op | lock override | **none** → P (cooperating) | low (cooperating), medium (bypass) | §8.3 | probe; L-1…L-5 |
| T-12 | concurrent C2 supersession | two replacements of one head | **none** | lock + head rule | **none** → P (cooperating) + D | as T-11 | §8.3; cross-plane §9.4 | probe; L-1, L-2, L-11 |
| T-13 | digest ambiguity | multiple encodings or spellings | strict encoder exists elsewhere | single representation; canonical-bytes rule; decimal grammar | **none** in Health → P | low | §9.3; O-3; O-12 | §9.1–9.2 probes |
| T-14 | missing approval evidence | CHENV without `approval` | none (`parse()` has no such field) | schema field required (O-2) | **none** → P at `parse()` + D in `verify` | low | O-2 | cross-plane §9.1 |
| T-15 | Trust verifier unavailable | T3 chosen and Trust unreadable | adapter fails closed (Fabric precedent) | n/a under T0 | n/a → P (refuse) | none under T0 | O-4 = T0 | `fabric/trust_adapter.py:409-456` |
| T-16 | compromised root account | root | none | none possible in-host | **none** → **none** | **accepted only by explicit ruling** | Design A with off-host key custody | — |

**No threat is classified as mitigated today** except T-2 (observed refusals) and
T-15 (not applicable under T0). Every "after" entry depends on unimplemented
controls and on the prerequisites.

---

## 11. Proposed mitigations

| # | Mitigation | Addresses | Owner | Reversible? |
|---|---|---|---|---|
| M-1 | **Separate agent execution from `cschott`'s privileges.** Preferred: run agents as a dedicated UID with none of `sudo`, `docker`, `lxd`, `adm`, and read/write only on a working copy. Alternative: remove `cschott` from `docker` and use rootless Docker or `sudo docker` | T-1, T-5, T-7 (S-1, S-2) | operator | yes |
| M-2 | remove the standing `docker run/exec/rm *` and `sudo -n true` allow rules from `.claude/settings.local.json`; consider a managed-settings deny for `docker` and `sudo` in agent sessions (**defence in depth only**: the file is agent-writable unless managed) | S-3 | operator | yes |
| M-3 | operator-assisted read of the effective sudo policy (§13 P-2) | T-2, T-3, T-4 | operator | n/a |
| M-4 | never execute repository-resident code as root: no `sudo bash /opt/schott-platform/…`, no `sudo python3 -c` from the repository. Privileged ceremonies run from root-owned installed copies of pinned blobs, with Python as `-I` | T-5 (S-7) | operator + future increments | yes |
| M-5 | approval helper and directory exactly as §6.3, with **no** sudoers grant | T-6, T-7 | future increment + operator ceremony | yes |
| M-6 | ceremonies only from a separate SSH login with no agent; optional `Defaults timestamp_timeout=0` scoped to the approval helper | T-3 | operator | yes |
| M-7 | `kyri-health` service UID owning the Health store; ingestion runs as it | T-1, T-11, T-12 bypass | H18-class ceremony | yes |
| M-8 | canonical JSON statement, canonical-bytes rule, decimal grammar | T-13, S-9 | future increment | yes |
| M-9 | `HealthStore` lock override, plus tests L-1…L-12 | T-11, T-12 | future increment | yes |
| M-10 | run `verify` as part of every ceremony and on a schedule chosen by the operator | T-1 detection | future increment | yes |

---

## 12. Operator rulings O-1 through O-10, revisited

| # | Previous recommendation | New host evidence | Still valid? | Ready for operator approval? | Remaining blocker |
|---|---|---|---|---|---|
| **O-1** root via `sudo` is the approval principal | root, with password, procedural ticket hygiene, never from an agent terminal | S-1: agents reach root **without `sudo`**. S-6: general policy unreadable. S-4/S-5: ticket reuse by agent shells not observed | **principal: yes; premise: no.** "Only root can approve" does not hold while agents can become root | **NO** | **P-1** (S-1/S-2) and **P-2** (policy read). Procedure: ceremony from a separate SSH login, helper per §6.3 |
| **O-2** `approval` required in CHENV | required | none host-specific | **yes** | **yes** | — |
| **O-3** promote `canonical_json` to `tools/common` | yes | S-9 strengthens it: JSON input removes the YAML hazards | **yes, strengthened** | **yes** | — |
| **O-4** T0 now, T3 later | T0 | §7: Trust adds no authentication, and under S-1 its records are forgeable by agents | **yes** | **yes** | T3 additionally blocked by S-1 |
| **O-5** ambiguous chain → refusal + `review_required`; recovery by an approved replacement | as stated | none | **yes** | **yes** | — |
| **O-6** no S2 succession claims | no | S-10: the lock is advisory; S2 would add same-UID-resistant uniqueness **only** together with M-7 | **yes for H7**; revisit after M-7 | **yes** | — |
| **O-7** accept RR-1…RR-7 | the operator's call | **RR-1 was understated**: the dominant path is S-1 (no password, no log), not ticket reuse. New risks: S-7 (repository code as root), S-3 (agent self-permissioning), S-9 (YAML misreading) | **the risk statement is invalid as written** | **NO** | restate the residual risk after P-1, P-2 and M-4. Accepting the current statement would accept a risk it does not describe |
| **O-8** report the gateway defect to Trust | yes | reconfirmed (§7) | **yes** | **yes** | — |
| **O-9** C1 + C2 in one increment | yes | none | **yes** | **yes** | — |
| **O-10** CHSTATE `superseded_by` | rule alongside CHENV | none | **yes** | **yes** | — |
| **O-11** *(new)* dedicated agent UID vs remove `docker` from `cschott` (M-1) | — | S-1, S-2 | — | **operator decision required** | — |
| **O-12** *(new)* canonical decimal-string grammar for thresholds | — | §9.2 | — | **yes, for ruling** | CHENV model change |
| **O-13** *(new)* `kyri-health` store UID (M-7) | — | S-10; `kyri-capability` precedent | — | **operator decision** | H18 scope |

**This report approves no residual risk on the operator's behalf.**

---

## 13. Remaining blockers and recommended implementation prerequisites

### 13.1 Blockers

| # | Blocker | Blocks |
|---|---|---|
| **B-P1** | S-1/S-2: agent processes hold a password-free, unlogged path to root | O-1, O-7, the ceremony, T3 |
| **B-P2** | S-6: effective sudoers policy (general `NOPASSWD`, `timestamp_timeout`, `timestamp_type`) is NOT OBSERVABLE | O-1 |
| **B-P3** | S-7: an established practice of running repository code as root | the ceremony's integrity |
| — | carried from the cross-plane review: schema amendment, `canonical_json` promotion, `HealthStore` lock, approval-authority provisioning | H7 implementation |

### 13.2 Prerequisites, in order

| # | Prerequisite | Kind | Verification |
|---|---|---|---|
| **P-1** | M-1: agents no longer hold the `docker` (and `sudo`) group, by separate UID or group removal | operator host change | `id` from an agent session shows neither 988 nor 27; `stat /var/run/docker.sock` is unchanged |
| **P-2** | operator-assisted policy read, run by the operator in their own terminal **without** an agent attached: `sudo -l -U cschott`; `sudo visudo -c`; `sudo grep -rnE 'NOPASSWD|timestamp|!authenticate|use_pty' /etc/sudoers /etc/sudoers.d`; and `sudo sha256sum /etc/sudoers.d/kyri-exec-*` compared with the reviewed text. Results pasted into the next report, with secrets redacted | operator inspection (escalates; **not run here**) | written into the next report |
| **P-3** | M-2: the standing agent allow rules for `docker` and `sudo` removed | operator | settings diff |
| **P-4** | M-4: ceremonies run only from root-owned installed copies; `python3 -I` | procedure + future increments | auth.log shows `/usr/libexec/…`, not `/opt/schott-platform/…` |
| **P-5** | cross-plane prerequisites, plus M-5, M-8, M-9 | implementation increments | their own reports |

---

## 14. GO / HOLD

**HOLD — H7 C1/C2 implementation.** Unchanged, and now for a host reason as well
as a design reason.

**HOLD — O-1 and O-7.** They cannot responsibly be approved on the observed
configuration. O-1's premise, that only root can publish an approval and agents
cannot reach root, is **false on this host** (S-1). O-7's risk statement
understates the actual residual risk (§12).

**GO — for operator rulings O-2, O-3, O-4, O-5, O-6, O-8, O-9, O-10 and O-12**,
none of which depends on host configuration, and **for operator decisions O-11
and O-13** and the operator-assisted inspection P-2.

**The honest summary.** The cross-plane design is sound in mechanism: every
primitive it needs exists on this host and behaves as specified. Its security
rests on one assumption, that root is a principal agents are not, and on `schai`
today that assumption is false. It is false not through `sudo`, which behaved
correctly in every logged agent attempt, but through rootful Docker, which needs
no password and leaves no `sudo` record. Until that path is closed, a
root-controlled approval proves only that *some* `cschott` process or the
operator acted, and that is what the platform already records without H7.

---

=== REVIEW PACKAGE ===

**Task:** ENG-0006-H7 operator authority security preflight. Read-only;
documentation only.

**Files Changed:**
`docs/development/reports/eng-0006/2026-10-29-eng-0006-h7-operator-authority-security-preflight.md`
(new). Nothing else.

**Tests Executed:** documentation and static validation suites, with counts in
the commit message and session handoff. The full 159-suite regression was
**not** run.

**Commands Run (read-only):**

- `git rev-parse`, `git status`, `git log`, `git ls-remote`, `git diff --stat`;
  `id`, `getent`, `who`, `loginctl show-session`, `tty`, `ps`, `/proc/<pid>/status`
- `stat`, `namei -l`, `getfacl`, `findmnt`; `/proc/sys` reads; `dpkg-query`,
  `snap list`, `systemctl is-active`
- reads of `/etc/sudo.conf`, `/etc/pam.d/{sudo,common-auth}`,
  `/etc/docker/daemon.json` and `/usr/share/polkit-1/rules.d/*`; `sha256sum`
  of `/usr/libexec/kyri-exec-{transition,reconcile}`
- `zcat`/`grep` over `/var/log/auth.log*` (via `adm`; summarised, arguments
  truncated) and `/var/log/dpkg.log`; transcript timestamp correlation (command
  heads only)
- unprivileged scratch probes (gateway, store section, YAML typing, alias
  expansion, canonical bytes, `flock` bypass, module shadowing)

**Not run:** no `sudo` in any form, no Docker or LXD API call, no service
change, no credential read.

**Known Risks:** §10 and §12; S-1 is the governing one.

**Architecture Decisions:** none taken. One revision **proposed**: the approval
statement becomes canonical JSON (§9.3).

**Questions for Reviewer:** O-1…O-13 (§12); P-2 (§13).
