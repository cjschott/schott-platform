# ENG-0005 G11-BB-M — the two final ceremony fixes

**Status: both fixes implemented, RED-first, and proved in fixture. Production
untouched.** Generation 15 is **not** re-authorized for production by this
report. `CINV-000001` untouched, `CINV-000002` unspent, no sudoers change, no
Fabric change, no helper installed.

Branch `arch/eng-0005-execution-transition`.

---

## 1. Fix 1 — the mid-transaction window is closed by publication order

The residual I recorded in BB-L §3 is now closed the way the ruling directed:
by making the runtime shut before anything else becomes observable, **not** by
removing the grants.

### The order

`helpers.py` is the rule that decides whether the installed helper bytes are
current. Generation 15 moves it to declare the **corrected** digests while the
predecessor helpers are still installed. Published first, execution closes on
the very first rename — before any other Generation-15 object exists on disk.

```
1  tools/capability/execution/helpers.py            H   <- readiness closes here
2  provisioning/execution/kyri-exec-launcher.py     H
3  tools/capability/execution/verification.py       V
4  tools/capability/execution/result_content.py     V   CREATE
5  tools/capability/execution/contract_outcome.py   V   CREATE
6  tools/capability/execution/recovery.py           R
7  tools/capability/cli.py                          R
```

Rollback now iterates the matrix in **reverse**, so `helpers.py` is restored
last: the predecessor declaration never returns while a Generation-15 object is
still published.

### It is a checked property, not a comment

The ruling said to stop rather than rely on operator exclusivity if the
framework could not guarantee the order. It can, and now does:

```
require_fail_closed_first()
  -> the first matrix row must be tools/capability/execution/helpers.py
  -> and it must be in coherence group H
```

Proved by running a **reordered copy** of the installer, which refuses:

```
PASS  an installer whose matrix no longer publishes the readiness authority first refuses
```

### RED-first evidence

With the pre-fix order restored, five publication positions leave the host
reporting `compatible` — the open window, reproduced:

```
FAIL  order: after publication #1 the host reports compatible
FAIL  order: after publication #2 the host reports compatible
FAIL  order: after publication #3 the host reports compatible
FAIL  order: after publication #4 the host reports compatible
FAIL  order: after publication #5 the host reports compatible
```

Under the corrected order, every position is closed:

```
PASS  order: before publication the host is compatible
PASS  order: after publication #1 .. #7 the host is incompatible
PASS  order: a complete Generation 15 with predecessor helpers stays incompatible
PASS  order: exactly 3 helpers block, so supervision_ready is false until the helper ceremony runs
PASS  order: kyri-exec-worker.py / kyri_exec_transition_action.py / kyri_exec_quota.py are named as blocking
```

Each verdict comes from the **real `compatibility()`**, using each fixture's own
`helpers.py` as the declaration and redirecting only paths. No rule was
reimplemented.

### Why the order is load-bearing rather than tidy

Every other Generation-15 object is invisible to the readiness rule, so any of
them published first would leave execution open. That is now asserted directly,
one row at a time, rather than argued:

```
PASS  publishing kyri-exec-launcher.py first would leave execution OPEN, so it may not be first
PASS  publishing verification.py     first would leave execution OPEN, so it may not be first
PASS  publishing result_content.py   first would leave execution OPEN, so it may not be first
PASS  publishing contract_outcome.py first would leave execution OPEN, so it may not be first
PASS  publishing recovery.py         first would leave execution OPEN, so it may not be first
PASS  publishing cli.py              first would leave execution OPEN, so it may not be first
```

### Interruption and rollback, re-run under the new order

All ten boundaries re-run, and each now answers the **operational** question as
well as the byte question:

```
stage staged prepared precommit committing publish verify
      -> 79 objects, exact Generation-14 library, verdict compatible
      PASS  reopens execution only against the complete Generation-14 runtime

postcommit evidence cleanup
      -> 81 objects, every matrix row at Generation-15 bytes, verdict incompatible
      PASS  leaves execution closed at the Generation-15 target
```

There is no interruption point that leaves execution open against a mixed
runtime. Execution reopens only when the complete predecessor is restored.

## 2. Fix 2 — the operator ceremony fails fast, and that is tested

`GEN15_OPERATOR_FAILFAST_DEFECT` is fixed at the level the defect actually lived
at: the ceremony text.

The block is now a governed artefact — `provisioning/execution/gen15-operator-ceremony.txt`
— so the suite can **execute it against a stub installer** that records every
invocation, instead of trusting that a fenced block in prose does what its prose
says. The text is reference material, not a script to run: the operator still
pastes it so every command and refusal is visible on the console.

```
PASS  ceremony: the operator block sets -Eeuo pipefail
PASS  ceremony: the journal check precedes every installer invocation
PASS  ceremony: with every stage passing, the ceremony completes
PASS  ceremony: the stages run in the declared order
PASS  ceremony: --verify refused -> --install invocation count is 0
PASS  ceremony: --verify refused -> --verify-installed invocation count is 0
PASS  ceremony: --verify-source refused -> --verify and --install invocation counts are both 0
```

**The control that gives those teeth.** The superseded BB-K shape — unchained
stages, no preamble — run against the same stub with the same refusal:

```
PASS  ceremony control: the superseded unchained block does reach --install after a refusal
```

So the assertions pass because of the chaining, not by accident.

### The unexpected-transaction stop

```
PASS  ceremony: an unexpected transaction journal stops the ceremony before any installer runs
PASS  ceremony: the refusal tells the operator to preserve the transaction for inspection
PASS  ceremony: the unexpected transaction is left untouched
```

Nothing is deleted, and the ceremony says so on the console rather than exiting
silently.

## 3. The authorization block — for the reviewer, not for now

**This report does not re-authorize the installation.** The text below is the
tested artefact; it is reproduced here so the correction is reviewable.

```bash
set -Eeuo pipefail
cd /opt/schott-platform

sudo test ! -e /root/kyri-gen15-transaction/journal \
  || { printf 'STOP: a Generation-15 transaction journal exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }
sudo test ! -e /root/kyri-gen15-transaction \
  || { printf 'STOP: Generation-15 transaction residue exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }

sudo test -f /root/kyri-gen14-library-digests.txt
sudo test -f /root/kyri-gen14-helper-digests.txt

sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify-source \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --install \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify-installed
```

## 4. Negative controls

The boundaries that were not weakened, re-run and still holding:

```
ok  an installer whose matrix no longer publishes the readiness authority first is refused
ok  an AX-governed object at undeclared bytes is still refused
ok  an ungoverned extra library-root object is refused
ok  the verification grant is still refused
ok  a grant pinning bytes the host does not carry is refused
ok  an undeclared Kyri grant is refused
ok  a pinned entrypoint whose bytes moved is refused
ok  unknown bytes at a REPLACE baseline are refused
ok  a pre-existing CREATE pathname is refused
```

## 5. One correction the fixture forced

The production-shape fixture carried only two `/usr/libexec` objects, because
Generation 15 moves none of them and nothing had needed to ask it a readiness
question before. Asking the real rule required the **declared** helper set to be
present, so the fixture now carries every path in `REQUIRED_HELPERS` as the host
holds it — derived from the installed declaration, so a helper added later
cannot quietly fall out of the simulation.

The suite also restated the Generation-15 source authority; it now reads it out
of the installer, so the two cannot drift.

## 6. Validation

```
Gen-15 focused suite   PASS   85 assertions, 0 failures
shellcheck             clean
provisioning suite     PASS
developer-experience   PASS
LOCAL_FULL             PASS   133/133
GITHUB_CI              PASS   6/6 at 08085fe
CLEAN_CLONE_VERIFY     PASS   clone of the pushed commit FROM THE REMOTE, 85/85
working tree           clean; HEAD == pushed branch head
```

The clean clone is taken from `origin`, not from the local repository, so it
proves what the remote actually carries rather than what this working copy
believes it pushed.

## 7. Production state

Verified read-only, without privilege:

```
library objects        79                unchanged
runtime aggregate      5bf50db23f086364e594f15c8390e9aff198b2825e681ee2aca2a40b7c133b84   unchanged
libexec aggregate      489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86   unchanged
transaction residue    0 files matching *.kyri-gen15.*
```

**Three facts could not be verified in this session and are not claimed.**
`sudo` is password-gated non-interactively here, so the absence of
`/root/kyri-gen15-transaction`, the sudoers aggregate, and the absence of the
verify grant were **not** read. An earlier probe printed `ABSENT` for two of
them; that output came from `sudo` failing, not from the files being absent, and
it is disregarded. This is precisely why the ceremony's first two commands are
the operator's own transaction checks, run with the privilege required to answer
them.

Nothing in this checkpoint wrote to production, and no privileged command
succeeded.

## 8. Next

Reviewer acceptance of both fixes, then a fresh authorization checkpoint for the
Generation-15 production installation. Still prohibited until separately
authorized: installing Generation 15, installing helpers, modifying sudoers,
renewing Fabric, touching `CINV-000001`, spending `CINV-000002`.

```
HOST_GENERATION 14   HELPER_INSTALL_AUTHORISED NO   PRODUCTION_INVOKE_AUTHORISED NO
GEN15_PRODUCTION_REAUTHORISATION  NOT REQUESTED BY THIS REPORT
```
