# G11-BC-AU — the §36 criterion-by-criterion audit

**Date:** 2026-10-09
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `afced9d`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — all fifteen §36 criteria audited and classified, none BLOCKED. **`ENG0005_SECTION36_STATUS = PASS`, `G7_READY = YES`**, with one cheap item recommended before G7. Audit only: no source, test, lifecycle or production change.

**Audit document:** [`docs/development/audits/2026-10-09-eng-0005-section-36-closure-audit.md`](../../audits/2026-10-09-eng-0005-section-36-closure-audit.md)

---

## A. What was audited, and against what

§36 lives in the **first-adapter design**, not the baseline design, and states
fifteen numbered criteria. The implementation plan's §8 binds each to a task
(`1–3 → T10/T11 · 4 → T12 · 5 → T8/T20 · 6 → T2/T3 · 7 → T14 · 8–9 → T13 ·
10 → T6 · 11 → T6 · 12 → T5 · 13 → T21 · 14–15 → T22`). That mapping decided
which evidence counts, rather than my judgement about which suite looked
relevant — my first attempt at keyword-matching criteria to suites returned 46
files for criterion 13 and was discarded as useless.

Evidence was taken in the brief's preference order. Four criteria rest on
production records or the real kernel; four on real-container E2E; the rest on
unit and installed-runtime evidence.

---

## B. Result

| | count |
|---|---|
| criteria total | **15** |
| PASS | **11** |
| PASS_WITH_ACCEPTED_FINDING | **4** |
| BLOCKED | **0** |
| NOT_APPLICABLE | **0** |

The four with findings: **1** (the sudoers layer's installed text is unread),
**5** (production field-by-field observation is not re-derivable after disposal),
**11** (inversion *raises* rather than being structurally impossible), **13**
(three of nine boundaries by real injection, six by constructed condition).

---

## C. The strongest evidence found

- **Criterion 12 is proven exhaustively by production records.** All 12 mutation
  records carry both an `intent` and an `outcome`; none is partial; the counter
  matches the record count.
- **The credential drop is proven on the real kernel, in production.**
  `/data/kyri/capability-handoff/CINV-000003/out` is owned
  `kyri-capability:kyri-capability` 0700 inside a `cschott`-owned tree, and the
  coordinator identity is **refused by the kernel** when it tries to read it. Only
  root can chown across users, so the ownership transfer happened under privilege;
  and the writer held neither the operator's identity nor root's.
- **Criterion 5 has real-container evidence despite T20's suite not existing.**
  The invoke E2E's failure matrix *is* field-by-field verification:
  `extra-mount`, `socket-mount` and `wrong-user-mapping` each yield
  `adapter-error`, `CINV` spent, `orphan=NO`.
- **The published production profile hashes to its launch authorisation's pin**
  (`f6696e0d…05ee`), carrying `cap_drop_all`, `dropped_capabilities: [ALL]`,
  `no_new_privileges: true`, `privileged: false`, `read_only_rootfs: true`,
  `network: none`, `pids_limit: 64`, `execution_uid/gid: 65532`.
- **All 8 declared helpers are installed with matching digests**, root-owned,
  none setuid, no file capabilities.

---

## D. Two findings this audit raised

**F5 — two plan-named suites do not exist.**
`tests/test-capability-execution-integration.sh` (T20) and
`tests/test-capability-execution-failure-injection.sh` (T21) are named by the
plan — T20's as a `**GREEN:**` gate command — and are absent. I checked the
plan's whole file list before auditing any criterion, which is how this surfaced.
Their substance is covered elsewhere at an equal or higher tier, so it does not
block; but a plan naming a non-existent acceptance command is a trap for the next
auditor.

**F6 — the installed sudoers grants were not read.**
The reviewed example names `/etc/sudoers.d/kyri-exec`; what is installed is
`kyri-exec-launch` and `kyri-exec-reconcile`, both root:root 0440 and unreadable
without escalation. So criterion 1's *sudoers* half rests on the repository
example. It does not block — the helper revalidates the grammar independently and
the helper binary is root-owned and non-writable — but **this is the one item I
would do before G7**: one `sudo cat`, one `visudo -c`, one `sha256sum`. I did not
do it because the brief forbids production changes and I would not treat "I could
not read it" as "it is correct".

---

## E. F1–F4 disposition, in brief

| | defect or limitation | mitigated by | unsafe mutation without ceremony? | blocking |
|---|---|---|---|---|
| **F1** `create-route` accepts impossible instants | defect in depth of enforcement, not in authority | **ceremony only** | yes in principle; grants no new authority | no |
| **F2** `select` accepts while resolving null | **the most serious** — a durable record asserting a decision that resolves to nothing | **ceremony only** | **yes, with a measured consequence** | no |
| **F3** digest excludes `request_id` | acceptable limitation, correctly scoped | **both** runtime and ceremony | no | no |
| **F4** kind-specific assumptions in suites | **test-quality defect, all mine** | fixed, kind-aware | no, but most likely to let one through unnoticed | no |

F1 and F2 together mean **two of the four renewal verbs enforce no temporal
ordering**, and the protection is entirely artifact text. They belong to one
Fabric-engine increment with F2 ranked first. Full reasoning in the audit §4.

---

## F. Honest limits of this audit

- **Real quota application is NOT proven.** The mechanism is installed and
  `/data` is mounted `prjquota`, but the applied project id on `out/` is
  unreadable at this privilege level — `lsattr -dp`, `xfs_quota -x -c report` and
  `repquota` all refused. The quota suite itself states *nothing was installed and
  no quota was established*. Classified unproven rather than inferred. It does not
  block: an unapplied quota widens a *resource* bound, not an authority bound.
- **F4's sweep was not performed.** I fixed the four instances a new record kind
  exposed; I do not claim they are the only prose-satisfied checks.
- **O3's closure is wall-clock-bounded** — authority is live for ~95 hours. If G7
  is entered after `2026-10-13T06:25:00-05:00`, the matrix evidence must be
  re-taken.
- **One correction to my own process.** I began by probing invented helper paths
  (`/usr/lib/kyri/kyri-capability-transition`), found them absent, and was close
  to recording the privileged helper as uninstalled. The design names
  `/usr/libexec/kyri-exec-*`. Recorded in the audit, because an audit that guesses
  paths can manufacture a blocker as easily as miss one.

---

## G. Production state

| store | aggregate | moved? |
|---|---|---|
| `/var/lib/kyri/fabric` | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` | no |
| `/data/kyri/capability-runtime` | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` | no |
| `/var/lib/kyri/trust` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | no |

Re-measured after every executable group. No Fabric record written, no capability
executed, no lifecycle or evidence mutation, nothing renewed, G7 not entered,
nothing merged or tagged, ENG-0006 not begun.

---

## H. Validation

| run | result |
|---|---|
| `tools/dev/run-validation.sh` (full) | **165/165**, 0 FAIL, 0 FAILED, **0 host-only skips** |
| clean clone of `61a8f1d` | **165/165**, 0 FAIL, **18 pinned-checkout skips** |
| GitHub CI on `61a8f1d` | **5/6 — Semgrep could not start** |

**CI is not green, and I am not reporting it as green.** Semgrep failed twice —
the original run and a re-run I triggered — with the same annotation both times:

```
failure: Docker pull failed with exit code 1
warning: Docker pull failed with exit code 1, back off 5.231 seconds before retry
warning: Docker pull failed with exit code 1, back off 4.105 seconds before retry
```

The action could not pull its own container image, so **the scan never ran and
produced no findings**. Static validation, ShellCheck, CodeQL, Gitleaks and Trivy
all passed. Semgrep was `success` on each of the three preceding commits
(`afced9d`, `316e6af`, `c089a84`), and this commit adds two Markdown files and
nothing else, so the failure is registry infrastructure rather than anything about
this change.

That is a conclusion about the *cause*, not a substitute for the verdict: Semgrep
has no verdict on this commit. If the reviewer wants one before G7, the job needs
re-running when the registry is reachable.
