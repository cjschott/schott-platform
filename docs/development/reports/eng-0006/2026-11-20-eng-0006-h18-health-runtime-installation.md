# ENG-0006-H18 — Health Runtime Installation

**Status:** implemented and tested on schmain for development. **Not
deployed, not merged.** Nothing was installed on any host, and schai was not
contacted.
**Host / account:** `schmain` / `kyri-dev`. **Branch:** `arch/eng-0006-health-runtime`.
**Baseline:** `77042e8` (H7b, 176/176 validation, 6/6 workflows).

**Review record values for the ceremony** (§8). Keep these off the production
host, and check them against this report as published, not against a checkout
on schai:

| Value | |
|---|---|
| runtime commit (pinned inside the installer) | `5131dfcff560295d5d2c83d411255c0310de9911` |
| installer commit (`REVIEWED`) | `a1df5200d4eefb9e5bde6e7e130144bc35c51312` |
| installer SHA-256 (`EXPECTED`) | `85a12d07ed63361a939dbf747e95318e2ae11e5a669beb22b5fd8ecaefb9a41b` |

## 1. Authority applied

| Source | Applied as |
|---|---|
| H18 authorization, item 1 (and O-13) | `kyri-health`: system user, own group, no other group, `/usr/sbin/nologin`, `/nonexistent`, locked password, no sudoers entry. The store is `kyri-health 0700`, which is the change to ENG-0006-D:746-747 (store owner `cschott` → `kyri-health`) that O-13 names, effective when the ceremony runs |
| O-1, as conditioned in finalization §10 | (c) is implemented: the approve helper exists only as installed by the §4.3 workflow. (a), (b) and (d) are procedure and are in the runbook: no agent on the host, an agent-free session, filesystem attribution and not a signature |
| preflight §6.3, M-5 | the approval directory and staging layout, the helper interface `<request_id> <sha256> < candidate`, TTY-only typed confirmation, link-into-place, readback, **no sudoers rule** |
| finalization §4.3 | reviewed commit → git blob read as the owner → root-only stage → digest → root-owned install; `python3 -I`; explicit `PATH`; `cd /` |
| finalization §6 | ingestion as `sudo -u kyri-health …-ingest <request_id>`, with no path argument; `verify` as `kyri-health`; refusals to the journal |
| M-10 | `verify` on a systemd timer (daily), plus every ceremony |
| H7b rulings 1–3 (2026-11-20) | recorded in the H7b report §4 as R-H7b-1…3; behaviour unchanged |
| O-11 | development ran on schmain as `kyri-dev`. Whether any agent still executes on **schai** is not verifiable from here, and O-1's condition (a) depends on it (§8, step 0) |

No new operator authority decision was needed. The two optional sudoers
changes in finalization §6 (a `NOPASSWD` ingest grant and
`timestamp_timeout=0` for approve) are **not** made; each still needs its own
ruling.

## 2. Commits

| Commit | Scope |
|---|---|
| `5131dfc` | runtime: `tools/health/operator.py`; `ingest.examine_statement` (extracted, unchanged behaviour); three helpers, the drafting CLI, the verify unit and timer; `tests/test-health-operator.sh`; operator.py in the four Health allowlists and the pinned import-pair policy |
| `a1df520` | `provisioning/health/install-health-runtime.sh`, pinned to `5131dfc`; `tests/test-health-install.sh`; lint, syntax-check and validation registration |
| `628f91c` | fix: declared validation totals 153 quick / 178 full (the full run at `a1df520` executed 178 against a declared 176) |
| (this commit) | the runbook `provisioning/health/README.md`, this report, H7b rulings recorded |

The split is forced, not stylistic. An installer cannot pin a commit that
contains the installer, so the runtime lands first.

## 3. What was built

### 3.1 Components

| Component | Where | Does |
|---|---|---|
| `operator.draft_statement` | library; CLI `provisioning/health/draft-health-approval.py` (unprivileged, never installed) | canonical statement bytes for one envelope; refuses whatever ingestion refuses before the store; JSON input only, with duplicate keys and non-integer numbers refused; every member supplied, `approved_at` included |
| `operator.publish_statement` | `/usr/libexec/kyri-health-approve` (root) | refuses unless: the publisher is the trusted UID; `sha256(bytes)` is the operator's digest; `examine_statement` passes; the name is free (identical bytes already published are accepted, idempotently, with no prompt); the 12 typed hex digits match. Then: write in `.staging` (`O_EXCL`, `0600`) → `fsync` → `fchmod 0444` → `link()` (never overwrites) → unlink the temporary → `fsync` the directory → re-open through `trusted_source` as ingestion does, and compare bytes |
| `operator.render_statement` | shown on `/dev/tty` | every member and dimension, **ASCII-escaped**, so a candidate cannot send terminal control sequences to hide what is being approved |
| `operator.ingest_command` | `/usr/libexec/kyri-health-ingest <request_id>` (kyri-health) | `HealthStore(root, initialize=False)` on a store this UID owns at `0700`, then `ingest_envelope`; exit 0/1/2/3 |
| `operator.verify_command` | `/usr/libexec/kyri-health-verify` (kyri-health) | `verify`; exit 0 clean, 1 findings, 2 refused; the report as JSON |
| `operator.identity_refusal` | ingest, verify | exactly the account's UID and GID, and no supplementary group |
| `kyri-health-verify.service` / `.timer` | systemd | oneshot as `kyri-health`; `ProtectSystem=strict`, `PrivateNetwork`, no capabilities, `NoNewPrivileges`; Fabric, Trust and implementation-authority stores inaccessible; daily at 04:30, `Persistent=true`. A finding fails the unit |
| `install-health-runtime.sh` | copied to `/root`, digest-checked | `--bootstrap-instructions`, `--verify`, `--install`, `--verify-installed`, `--uninstall`; test-only `--fixture` and `--repository` |

### 3.2 The helper bootstrap (requirement 6)

All three helpers carry one byte-identical bootstrap, which the suite asserts.

- **Interpreter.** `#!/usr/bin/python3 -IB`: no working directory, no
  `PYTHON*` variables and no user site on the path, and no bytecode written.
- **Pre-import check.** Before importing anything from the library, it walks
  `/usr/lib/kyri/health` and every ancestor up to `/`, and every entry beneath
  it, with `lstat`. Each must be a real directory or regular file, owned by
  UID 0, and writable by no one else. A symlink, FIFO, group-writable module or
  writable ancestor gives `library-untrusted`.
- **Import.** It then puts the library first on `sys.path` and imports
  `tools.health.operator`.
- **Post-import check.** It confirms that `tools`, `tools.common`,
  `tools.health` and the operator, ingest and store modules all resolved
  inside the library.
- **Privilege.** The approve helper observes root: its effective UID must be
  0. The service helpers check the account through `pwd`.

### 3.3 The installation boundary (requirement 5)

```
REVIEWED installer commit ──git cat-file blob (as cschott)──► sudo tee /root/kyri-health-install/…
                                         operator: sudo sha256sum == EXPECTED (from this report)
sudo bash /root/…/install-health-runtime.sh
   └─ for each of 19 pinned rows: git cat-file blob 5131dfc:<path> (runuser -u <owner>)
        → /root/kyri-health-stage.XXXXXXXX (0700) → sha256 == pinned → install
```

- **Library.** Built under `/usr/lib/kyri/.health-staging`, checked to be
  exactly the closure, then renamed into place in one step.
- **Helpers and units.** Each is written to a sibling staging name, checked,
  and moved with `mv -n -T`.
- **Ancestry.** Every ancestor of every destination must be root's and
  writable by no one else, with no symlink. `/var/lib/kyri` must also be
  traversable.
- **Existing objects.** Anything that already exists is compared exactly:
  owner, mode, link count, bytes, and, for the library, the full tree listing.
  A differing object is refused and never repaired.
- **What runs as root.** Root executes the installer copy (after its digest
  check), coreutils, `git` only through `runuser` as the owner, `useradd` and
  `systemctl`. Nothing from the payload runs during installation.

### 3.4 Rollback (requirement 8)

- **`--uninstall` order.** It first checks every installed runtime object. If
  any differs from the reviewed one, it removes nothing. Otherwise it disables
  and stops the timer, removes the units, runs `daemon-reload`, removes the
  helpers, renames the library away and deletes it, and clears residue.
- **What it keeps.** The identity, the store and the approvals are evidence
  and are never removed.
- **Repeat runs.** A second `--uninstall` is a no-op, and `--install`
  afterwards reinstalls over the kept evidence unchanged.
- **Upgrade.** A later release's installer pins its own commit. Because
  `--install` never replaces a differing object, an upgrade is this
  installer's `--uninstall` followed by the new one's `--install`.

## 4. Decisions taken within the contract

These can each be reversed.

1. **`examine_statement` is extracted from `ingest_envelope`**, covering V1
   and V3–V9, so that the approve helper refuses exactly what ingestion
   refuses before the store. A parity battery checks this against
   `ingest_envelope` over nine inputs. The 468 ingestion assertions are
   unchanged and pass.
2. **The library is installed at `/usr/lib/kyri/health`, not
   `/usr/lib/kyri/python`.** It is the import closure of
   `tools.health.operator`, 14 modules, and contains no Trust, Fabric or
   Capability module. The Capability library and the G5 manifest are
   untouched.
3. **The evaluators are installed** (conditions, freshness, hysteresis),
   because `tools/health/__init__.py` imports them. `yaml_strict` and
   `containment` are not installed.
4. **The publisher must be the trusted UID.** There is no own-UID opt-in for
   publication: a statement root did not create is one that ingestion
   refuses.
5. **The ceremony lays out the store.** `HealthStore` refuses to provision the
   production root (H6), so the installer creates the six record directories,
   `sequences/` and the lock file. The suite checks that this list equals what
   `HealthStore(initialize=True)` creates.
6. **`--install` enables the timer.** Its schedule is daily at 04:30 local
   time with `Persistent=true`. The operator overrides it with
   `systemctl edit`.
7. **A partial account is refused, not completed.** A `kyri-health` group
   without the user, or a user that differs from the contract, halts the
   ceremony. Production also checks NSS (`id -nG`) and `sudo -l -U`.
8. **Fixture mode is stated, not hidden.** Under `--fixture`:
   - the account database is the fixture's `/etc`, and ownership is the
     invoking user's;
   - systemd is not touched, and the branch name and the interpreter's
     isolated-mode `yaml` are not checked;
   - the system-UID range check is skipped.

   Each of these prints a `note` line. `--repository` is refused without
   `--fixture`.
9. **The approve helper logs `SUDO_USER`** to the journal. That is attribution
   which root can tamper with, not authentication.

## 5. Trust and Fabric isolation (requirement 9)

| Check | Result |
|---|---|
| `git diff 77042e8 HEAD -- tools/trust tools/fabric tools/capability` | empty |
| importing `tools.health.operator` loads no other plane | asserted in a subprocess |
| installed closure | `tools/{__init__,common/{__init__,canonical_json,immutable_store,trusted_source},health/*}.py`; derived from a real import and compared to the pinned rows |
| new cross-package import | one pair, `tools/health/operator.py:tools.common.canonical_json`, pinned by exact content in `test-capability-health.sh` with a moved-import battery (trusted_source, immutable_store, the package form and yaml_strict are each refused in `operator.py`) |
| systemd | `InaccessiblePaths=-/var/lib/kyri/fabric -/var/lib/kyri/trust -/var/lib/kyri/implementation-authority` |

## 6. Tests

| Suite | Assertions | Covers |
|---|---|---|
| `test-health-operator.sh` (new) | 232 | drafting and the CLI; examine/ingest parity; publication including every refusal, a no-change check after each, the name appearing mid-confirmation, symlinked or writable roots and staging; ASCII-only rendering against control sequences; the service commands; all three helpers run from a fixture "installed" library; nine untrusted-library cases; the approve helper on a **real pty** (published, wrong confirmation, digest mismatch, stdin a terminal, no controlling terminal, not root); unit and timer content; import closure |
| `test-health-install.sh` (new) | 172 | the pin recomputed from git; library equal to the import closure; store layout; static rules (sources nothing; absolute binaries; no repository execution; no sudoers write); bootstrap text; accepted path and exact shapes; idempotence; the **installed** helpers doing approve → ingest → verify; rollback keeping evidence byte-identical; reinstall; nine tampered objects (verify-installed fails, install and uninstall refuse with no change); eighteen bad pre-states; residue; refused pins |
| `test-health-ingest.sh` | 468 | unchanged; passes after the extraction |
| guard suites | — | `test-capability-health` 758, `test-static` 883, `test-docs-static` 994, `test-capability-fabric`: pass |

**Mutation.** Eight installer mutants were run, one for each of these checks
disabled:

- supplementary groups
- the link count
- the installed-file digest
- the payload digest
- the locked password
- uninstall's pre-check
- ancestry writability
- the residue refusal

All eight were killed.

**Full validation.** `tools/dev/run-validation.sh` passed on schmain:
**153/153 steps in quick mode and 178/178 in full mode**. ShellCheck 0.9.0
came from a scratch venv on `PATH`, as in H7b §8; CI's pinned workflow is the
authority. The installer is now linted (`run-shellcheck.sh`) and
syntax-checked in CI (`bash -n provisioning/health/*.sh`).

## 7. Known limitations

| # | Limitation |
|---|---|
| L-a | **Never run as root.** The production-only branches are written but unexercised: `useradd`, `chown`, `systemctl` daemon-reload/enable/disable/is-enabled/is-active, `id -nG`, `sudo -l -U`, the shadow read, and `/usr/bin/python3 -I -c 'import yaml'`. The first ceremony on schai is their first run, and every one of them fails closed |
| L-b | **The unit's hardening is unvalidated on a host with the account.** `systemd-analyze verify` here reports only the missing executable. Run `systemd-analyze security` at acceptance |
| L-c | **A finding is a failed unit and a journal line.** Nothing routes an alert |
| L-d | **Root, or `cschott` through Docker, can rewrite everything** consistently: approvals, records, the library, the logs (R-3, R-4). `verify` and `--verify-installed` detect only a non-root forger |
| L-e | **Approval is attribution, not authentication** (R-1). A cached `sudo` ticket can run the helper without a fresh password; the typed digest is still required (R-6, since `timestamp_timeout=0` is not applied) |
| L-f | **The store lock is advisory.** A compromised `kyri-health` can forge records, which is detected and not prevented (R-7) |
| L-g | **Frozen subjects have no recovery** (O-5) |
| L-h | **`-I` keeps the system site-packages** (for PyYAML), including `/usr/local/lib/python3*/dist-packages`. These are root-controlled, and the library comes first on the path |
| L-i | **An upgrade has a gap.** It is uninstall, then install, so the timer is off between the two |
| L-j | **The installer pins `arch/eng-0006-health-runtime`.** A merge to another branch needs a re-reviewed pin |
| L-k | **The fixture account takes the invoking user's UID.** Ownership separation between root and `kyri-health` cannot be shown without privilege; it is shown as the checks that would refuse it |

## 8. Operator actions (not executed)

The full procedure, with acceptance, is in `provisioning/health/README.md`. In
order:

0. Confirm on schai that no agent executes there (O-1(a) / O-11(A)), and run
   the ceremony from a session you have checked: `ps -u "$(id -un)" -o pid,comm`.
1. Fetch the branch into `/opt/schott-platform` and check it out at or after
   `a1df520`. Make sure `/usr/bin/python3 -I -c 'import yaml'` succeeds; if
   it does not, install `python3-yaml`.
2. Bootstrap and install:

   ```bash
   REVIEWED=a1df5200d4eefb9e5bde6e7e130144bc35c51312
   EXPECTED=85a12d07ed63361a939dbf747e95318e2ae11e5a669beb22b5fd8ecaefb9a41b
   sudo install -d -o root -g root -m 0700 /root/kyri-health-install
   git -C /opt/schott-platform cat-file blob "${REVIEWED}:provisioning/health/install-health-runtime.sh" \
     | sudo tee /root/kyri-health-install/install-health-runtime.sh >/dev/null
   sudo sha256sum /root/kyri-health-install/install-health-runtime.sh     # == EXPECTED, or stop
   sudo bash /root/kyri-health-install/install-health-runtime.sh --verify
   sudo bash /root/kyri-health-install/install-health-runtime.sh --install
   sudo bash /root/kyri-health-install/install-health-runtime.sh --verify-installed
   ```

3. Run the acceptance commands in the runbook and paste their output into the
   next report.
4. Optional rulings: a `NOPASSWD` ingest grant, and `timestamp_timeout=0` for
   the approve helper.

## 9. Reproducing the validation

```bash
cd ~/Projects/schott-platform
git log --oneline 77042e8..HEAD
bash tests/test-health-operator.sh | tail -2
bash tests/test-health-install.sh | tail -1
bash tests/test-health-ingest.sh | tail -2
for t in test-capability-health test-static test-docs-static test-capability-fabric; do
  bash "tests/${t}.sh" >/dev/null 2>&1; echo "$? $t"; done
git diff --stat 77042e8 HEAD -- tools/trust tools/fabric tools/capability   # expect empty
test ! -e /var/lib/kyri/health && echo absent
# a manual fixture run of the ceremony:
F="$(mktemp -d)"; chmod 755 "$F"
for d in etc etc/sudoers.d etc/systemd/system usr/lib usr/libexec var/lib root; do mkdir -p "$F/$d"; done
chmod -R 755 "$F"; chmod 700 "$F/root"; : > "$F/etc/passwd"; : > "$F/etc/group"; : > "$F/etc/shadow"
bash provisioning/health/install-health-runtime.sh --install --fixture "$F" --repository "$PWD"
bash provisioning/health/install-health-runtime.sh --verify-installed --fixture "$F"
bash provisioning/health/install-health-runtime.sh --uninstall --fixture "$F"
# full validation needs shellcheck 0.9.0 on PATH (e.g. a venv with shellcheck-py==0.9.0.6):
tools/dev/run-validation.sh
```

## REVIEW PACKAGE

```
Task:                   ENG-0006-H18 Health runtime: identity, approval and store roots,
                        approve/ingest/verify helpers, verify timer, pinned installer,
                        rollback, runbook
Files Changed:          tools/health/{operator.py (new), ingest.py, __init__.py};
                        provisioning/health/{install-health-runtime.sh, kyri-health-approve.py,
                        kyri-health-ingest.py, kyri-health-verify.py, draft-health-approval.py,
                        kyri-health-verify.service, kyri-health-verify.timer, README.md} (new);
                        tests/{test-health-operator.sh, test-health-install.sh} (new);
                        tests/{test-capability-health,test-capability-fabric,test-static,
                        test-docs-static}.sh (allowlists, import pair);
                        .github/workflows/ci.yml; tools/dev/{run-validation,run-shellcheck}.sh;
                        H7b report (rulings recorded); this report
Tests Executed:         §6 and §9
Commands Run:           §9; 8 installer mutants; fixture ceremonies
Known Risks:            §7
Architecture Decisions: §4
Questions for Reviewer: the two optional sudoers rulings (§1); whether daily at 04:30 is
                        the schedule wanted; whether a failed unit is enough signal (L-c)
```
