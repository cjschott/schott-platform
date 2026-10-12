# G11-BC-AX — the ceremony's F7 verdict now runs the installed library

**Date:** 2026-10-12
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `fe25285`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — the ceremony's post-install F7 check now runs `/usr/lib/kyri/python` and asserts all three conditions; proved by running it today, where it correctly refuses. **No runtime source changed, no matrix digest moved, Generation 24 NOT installed.**

---

## A. The defect, measured

The ceremony opens `cd /opt/schott-platform`, and its final F7 check was a bare
module invocation. From that directory it resolves the **repository** copy —
which already carries the Generation-24 fix. Both copies, read-only, today:

| invoked from | resolves | findings | exit |
|---|---|---|---|
| `/opt/schott-platform` | `/opt/schott-platform/tools/capability/cli.py` | **`[]`** | **0** |
| `/usr/lib/kyri/python` | `/usr/lib/kyri/python/tools/capability/cli.py` | `CINV-000002`, `CINV-000003` | **1** |

So the old block would have printed `{"findings": [], "status": "reported"}` and
`exit=0` **before anything was installed**, and an operator would reasonably have
read that as proof the fix had landed. The closure-blocking finding is in the
installed runtime; only the installed runtime can retire it.

**A second defect in the same four lines.** The old block read:

```bash
python3 -m tools.capability.cli validate …
echo "exit=$?"
```

Under `set -Eeuo pipefail` a non-zero exit aborts the ceremony on the previous
line, so that `echo` could **never** have printed a failure. It could only ever
report success — which is what it did.

---

## B. The correction

```bash
installed_validate_rc=0
installed_validate_out="$(
  cd /usr/lib/kyri/python
  python3 -m tools.capability.cli validate \
    --store-root /data/kyri/capability-runtime \
    --expected-uid 1000 \
    --expected-gid 1000
)" || installed_validate_rc=$?
```

The subshell makes resolution unambiguous; `|| rc=$?` keeps `set -e` from
aborting before the assertions. All three conditions are then **asserted**, each
with its own `STOP`:

- `exit = 0` — otherwise *"the INSTALLED validator exited N; F7 is not retired."*
- `findings = []` — otherwise the findings are named
- `status = reported` — otherwise the status is named

### Proved by running it today

The new block, executed before installation:

```
{"findings": ["CINV-000002: result-without-execution-authority",
              "CINV-000003: result-without-execution-authority"],
 "status": "reported"}
installed validate exit=1
STOP: the INSTALLED validator exited 1; F7 is not retired.
block exit=1
```

It refuses, which is the whole point: the ceremony is now honest about the
installed state. `--verify-installed` remains the independent structural and
digest proof; this is the behavioural one.

---

## C. The self-test, and why it is structural

`tests/test-capability-execution-generation24-installer.sh` — **78 PASS / 0
FAIL** (was 77).

The check does **not** grep the ceremony for `/usr/lib/kyri/python`: a ceremony
that merely *mentioned* the path in a comment would pass. It parses the file,
finds every validator invocation, and walks back over the enclosing block
requiring an explicit `cd /usr/lib/kyri/python` — or an explicit installed
`PYTHONPATH` — before the call and inside the same subshell. Reaching the
subshell's opening, or a `cd /opt/schott-platform`, without finding one is a
refusal.

Sabotaging the installed-resolution line out of the ceremony is caught:

```
caught: repository resolution -- the validator invocation at line 137 does not
explicitly resolve the installed library
```

### Three defects in my own checker, found by building it

**The sabotage was vacuous.** Its heredoc lost a newline escape, the Python died
with a `SyntaxError`, and the function returned **without calling `pass` or
`fail`** — so the suite reported 78 PASS / 0 FAIL with the case silently absent.
A broken sabotage that produces no verdict is worse than a failing one, and this
is the second time in three checkpoints I have written one. Every failure path is
now guarded and reports `BROKEN SABOTAGE`.

**A character class closed the string it was inside.** `r"PYTHONPATH=["']?…"`
carried both quote characters; the double quote terminated the Python literal.

**The exit-code check matched the ceremony's own comment** explaining the old
defect. Narrowed to non-comment lines — the same distinction the installer's
identity gate draws for exactly the same reason.

---

## D. Scope

| object | digest | moved? |
|---|---|---|
| `tools/capability/execution/state.py` | `87abff5bdde4ad295f605df2f39bac3a2e028f833dc53e6f2725cd2d457bba53` | **no** |
| `tools/capability/inspection.py` | `1c2d27d7f003e70ee4fcc4ede004530b0587dfcd65f7180a59caaa03b2d3b99b` | **no** |
| `tools/capability/cli.py` | `211cf173e780d7031ec78180c9890b046ae0ec70fdcddd9e479eaa3e6fad3095` | **no** |

**Matrix digest lines changed: 0.** The only installer edit is the comment
corrected under §E.

### §E — the stale group statement

```
-# this generation only moves L. The names outlive the generation that
+# this generation only moves E. The names outlive the generation that
```

I audited for the same statement elsewhere: it appears **once**. No general prose
rewrite was opened, and the edit moves no digest.

---

## D-BIS. Validation

| run | result |
|---|---|
| Generation-24 installer suite | **78 PASS / 0 FAIL** |
| F7 result-authority suite | 14 PASS / 0 FAIL |
| Generation-24 `--verify-source` | PASS — 3 REPLACE, 0 CREATE |
| `run-validation.sh --quick` | **142/142**, 0 FAIL, 0 skips |
| `run-validation.sh` (full) | **167/167**, 0 FAIL, **0 host-only skips** |
| clean clone of `4c91e04` | **167/167**, 0 FAIL, **18 pinned-checkout skips** |
| GitHub CI on `4c91e04` | **6/6 green** |

Both resolution checks run inside the clean clone, including the sabotage.
Fabric, runtime and Trust byte-identical throughout.

---

## E. Production state

| store | aggregate |
|---|---|
| `/var/lib/kyri/fabric` | `7e2a4ed0e9c11cf1f3790360542232649946a9bf31400e9dd442d8c2ad2f376b` |
| `/data/kyri/capability-runtime` | `7dfb34e6270a2f67292b90cdefcc829a19c94ece99a0ed24779b7059c5382e99` |
| `/var/lib/kyri/trust` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` |

**Generation 24 is NOT installed** — the installed validator still reports both
findings, which is what makes §B's refusal the correct outcome today. No
production mutation, G7 not re-entered, no closure ceremony run.

---

## F. Questions for the reviewer

1. **This is the third defect in Generation 24's publication surface** — the
   transaction identity, the generation diagnostics, and now the ceremony's
   resolution path — and none was in the F7 implementation, which has been
   byte-stable since G11-BC-AV. The runtime change was the small part; the
   publication around it is where the mistakes were. Worth considering whether
   the next generation's ceremony should be derived from the installer rather
   than written alongside it.
2. **I have now written two vacuous sabotages in three checkpoints** — one caught
   by `the working tree is not clean`, one that died silently and contributed no
   verdict. Both were caught by reading the output rather than the summary count.
   A harness-level rule that a sabotage must produce exactly one verdict would
   catch the class; I did not add one, because it is a change to shared test
   infrastructure rather than to this generation.
3. **The authority window closes `2026-10-13T06:25:00-05:00`** — under 24 hours
   from this report. Installation, the G7 re-entry and the closure decision all
   sit behind it, and after it the Stage-3 matrix masks again and O3's live
   evidence would need the renewal ceremony re-run first.
