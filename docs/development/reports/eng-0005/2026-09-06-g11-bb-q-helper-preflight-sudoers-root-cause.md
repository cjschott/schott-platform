# ENG-0005 G11-BB-Q — the helper preflight refusal, root-caused and fixed

**Status: the refusal was the ceremony's, not the host's. Two defects, both
mine, both fixed. Production was never touched.** No transaction was opened, no
helper was published, and the three helper targets are byte-identical to their
predecessors. Generation 15 remains installed and accepted; execution remains
fail-closed.

```
HELPER_TRANSACTION          ABSENT
HELPER_PUBLICATION          NONE
HELPER_PRODUCTION_MUTATION  NONE
```

Branch `arch/eng-0005-execution-transition`.

---

## 1. Transaction state, established before anything was changed

The ceremony refused during `--verify`. **`--verify` has no code path that can
open a transaction**, proved from source rather than asserted:

- `mkdir -p "${TRANSACTION_ROOT}"` appears exactly twice — inside
  `journal_write()` (line 263) and in the `--install` branch (line 1057).
- The `--verify` branch (line 1008) calls neither. It runs eleven read-only
  checks and exits.
- In `--install`, `require_gates_closed` runs **before** line 1057, so even that
  path would have refused before a journal could exist.

Read-only from the host, without privilege:

```
/usr/libexec/kyri-exec-worker.py                6d06695f433570070b15fc4a990b53dcbaa227001586d4062e254a08367723fd
/usr/lib/kyri/python/kyri_exec_transition_action.py  7703231318f7a872f80abc0b033c2462c24ec63bd8669773d6643634af1d296a
/usr/lib/kyri/python/kyri_exec_quota.py         4886d5b323c9dfdf46939c83424b087bb052f3fc90b8bd4a5ba2b4346bff9e9c
```

All three are the **predecessor** bytes. Staging or residue matching
`*.axhelpers.*`, `*.bbhelpers.*`, `*.prepared`, `*.backup` or `*kyri-g11-bb*`:
**0 files**. The `/usr/libexec` aggregate is `489f108d…952bea86`, unchanged since
Generation 14; the library aggregate is `dcf41d3b…f088e8c7`, unchanged since the
Generation-15 install.

`/root` is unreadable to the coordinator and `sudo` is password-gated
non-interactively, so `/root/kyri-g11-bb-helper-transaction` was **not** read.
The source argument above is why no code path could have created it, and the
operator's own console showed no PREPARE and no COMMIT line. The ceremony's
first two commands check exactly this with the privilege required to answer it.

## 2. Root cause 1 — the stale "all grants closed" model

```
require_gates_closed()                       install-g11-bb-helpers.sh
  [[ ! -e "${SUDOERS}" ]]           || halt "the launch grant is installed"
  [[ ! -e "${VERIFY_SUDOERS}" ]]    || halt "the verification grant is installed"
  [[ ! -e "${RECONCILE_SUDOERS}" ]] || halt "the reconcile grant is installed"
```

**It predates G11-BA.** At G11-AX that was a true statement about the host:
nothing had ever been granted, so "absent" and "not installed by anybody" were
the same claim. G11-BA then installed the launch and reconcile grants, and this
check — inherited unchanged — refused the production host for holding exactly
the grants the accepted deployment plan says it should hold.

**This is the same defect BB-L root-caused in the Generation-15 ceremony, in the
other copy of it.** BB-L corrected `require_gates_closed` there and left this
one, exactly as BB-O found the post-install verifier left behind by a fix
applied to its pre-install twin. Three times now, the same shape: one idea
written in two places, corrected in one.

**Does anything require their absence?** No. This ceremony moves three helper
**objects** and neither digest-pinned entrypoint — `require_entrypoints_unmoved`
asserts that, and the suite proves it for both. A grant is permission to ask;
readiness is permission to proceed, and readiness stays shut until the last
helper lands. The BB-P authority is explicit that the launch and reconcile
grants remain installed through Phase 8.

```
HELPER_SUDOERS_ROOT_CAUSE = require_gates_closed required all three grants ABSENT,
a G11-AX-era statement about the host that G11-BA made false; the accepted plan
keeps the launch and reconcile grants through this ceremony.
```

## 3. Root cause 2 — the launch grant was being read at a pathname that never existed

This is the part the operator's output pointed at, and it is why the refusal
named the **reconcile** grant rather than the launch grant:

```
SUDOERS="/etc/sudoers.d/kyri-exec"            <- no ceremony ever created this
```

G11-BA installed the launch grant as `/etc/sudoers.d/kyri-exec-launch`. The
Generation-15 installer names it correctly; this one did not. So the first check
tested a pathname that has never existed on any host, passed vacuously, and the
second check fired — which is exactly the shape of the console output:

```
STOP: /etc/sudoers.d/kyri-exec-reconcile exists: the reconcile grant is installed
```

Had only the model been corrected and not the pathname, the launch grant would
have been judged **missing** and the ceremony would have refused for a new wrong
reason. Both had to move together.

## 4. The corrected gate — precise, not permissive

Not "grants may exist". The accepted state is checked exactly, and by Phase 8
both grants **must be present**, because a host missing them is not the accepted
host this ceremony was derived against:

```
/etc/sudoers.d/kyri-exec-launch      MUST exist
                                     MUST pin the installed kyri-exec-transition digest
                                     MUST name that command path
/etc/sudoers.d/kyri-exec-reconcile   MUST exist
                                     MUST pin the installed kyri-exec-reconcile digest
                                     MUST name that command path
/etc/sudoers.d/kyri-exec-verify      MUST be absent
any other kyri-* grant               refuses
```

The command path is checked as well as the digest, because a grant pinning the
right bytes at the wrong command is a grant nobody reviewed. The grant text
names the production path even under `--fixture`, so the fixture prefix is
stripped before that comparison.

```
HELPER_EXISTING_GRANTS_ALLOWED  PASS
VERIFY_GRANT_ABSENT_REQUIRED    YES
LAUNCH_GRANT_EXACT              PASS
RECONCILE_GRANT_EXACT           PASS
UNDECLARED_GRANTS_REFUSED       PASS
```

**Neither pinned entrypoint moves.** The helper delta re-derives to three
REPLACE rows and neither entrypoint is among them:

```
/usr/libexec/kyri-exec-transition   0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1
/usr/libexec/kyri-exec-reconcile    2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77
SUDOERS_CHANGE_REQUIRED = NO
```

## 5. The fixture never modelled the accepted host

The suite was green while production refused, for one reason: `build_runtime`
created an **empty** `/etc/sudoers.d`. Every gate assertion in this suite has
been passing against a host shape that has not existed since G11-BA, which is
precisely how a G11-AX-era check survived to a production console.

The fixture now carries both accepted grants, each pinning the entrypoint bytes
the fixture actually holds, with the verify grant absent.

### 5.1 RED-first

With the fixture corrected and the installer untouched, the suite reproduces the
production console **exactly**:

```
STOP: …/etc/sudoers.d/kyri-exec-reconcile exists: the reconcile grant is installed
```

Same grant, same message, and — like production — the launch grant went unread.

### 5.2 Mutation

Both halves of the fix are load-bearing:

```
restore the all-grants-absent model  -> STOP: …/kyri-exec-launch exists: the launch grant is installed
restore the kyri-exec pathname       -> STOP: …/kyri-exec is not a grant this ceremony can account for
```

The first now names the **launch** grant, where production named reconcile —
which is the pathname defect showing itself from the other side, and confirms
the two are independent.

## 6. Negative controls — the boundary that was not weakened

Ten cases, each perturbing one thing about the accepted state and requiring
`--verify` to refuse:

```
PASS  gates: the accepted two-grant production state is accepted
PASS  gates: a missing launch grant is refused
PASS  gates: a missing reconcile grant is refused
PASS  gates: a launch grant pinning bytes the host does not carry is refused
PASS  gates: a reconcile grant pinning bytes the host does not carry is refused
PASS  gates: a grant naming a command the host does not run is refused
PASS  gates: the verification grant present is refused
PASS  gates: an undeclared kyri-* grant is refused
PASS  gates: a pinned entrypoint whose bytes moved is refused
PASS  gates control: an unmutated copy of the accepted state still verifies
```

Carried over and still holding: `unknown bytes at a REPLACE predecessor are
refused`, and `the ceremony refuses a Generation-14 runtime and names the
reason`.

**One real bug these controls caught in my own fix.** The undeclared-grant sweep
used `SUDOERS_DIR`, which the fixture-prefix block did not rewrite — so under
`--fixture` it scanned the **real** `/etc/sudoers.d` and the control passed
while proving nothing. The Generation-15 installer prefixes it; this one now
does too.

## 7. The fail-closed deployment model, unchanged

The Phase-8 matrix was not altered, and still holds:

```
A  Gen 14 + predecessor helpers        compatible
B  Gen 15 + predecessor helpers        incompatible     <- current production
C  Gen 14 + successor helpers          incompatible
D  Gen 15 + partial subsets            000 001 010 011 100 101 110  all refuse
E  Gen 15 + complete successor set     compatible       111 compatible
```

```
HELPER_PREINSTALL_COMPATIBILITY     incompatible
HELPER_PREINSTALL_BLOCKING          3
HELPER_PREINSTALL_SUPERVISION_READY false
HELPER_PARTIAL_DEPLOYMENT_REFUSAL   PASS
HELPER_FIXTURE_INSTALL              PASS
HELPER_FIXTURE_VERIFY_INSTALLED     PASS
```

Both pinned entrypoints are asserted unmoved across the fixture install.

## 8. Operator ceremony fail-fast, reconfirmed

Not from prose — the suite executes the committed artefact against a stub
installer that records every invocation:

```
PASS  ceremony: the operator block sets -Eeuo pipefail
PASS  ceremony: the journal check precedes every installer invocation
PASS  ceremony: with every stage passing, the ceremony completes
PASS  ceremony: the stages run in the declared order
PASS  ceremony: --verify refused -> --install invocation count is 0
PASS  ceremony: --verify refused -> --verify-installed invocation count is 0
PASS  ceremony: --verify-source refused -> --verify and --install counts are both 0
PASS  ceremony: an unexpected helper transaction stops it before any installer runs
PASS  ceremony: the unexpected transaction is left untouched
PASS  ceremony: absent Generation-15 evidence stops it before any installer runs
PASS  ceremony: a present verification grant stops it before any installer runs
```

The ceremony text is unchanged by this checkpoint; only the installer it calls
moved.

## 9. Validation

Host-only results are reported separately, because `tests/host-only.manifest` is
explicit that *"the local validator is the authority for everything listed here,
and GitHub CI proves none of it."*

```
bb-helper-ceremony suite   PASS   52 assertions, 0 failures   (42 -> 52)
HOST-ONLY SUITES           26 PASS   3 SKIP   0 FAIL
LOCAL_QUICK                PASS   109/109
LOCAL_FULL                 PASS   134/134
shellcheck                 clean
```

The three skips are unchanged and pre-existing — `g61-verification`,
`profile-transport` and `transition-action`, each reporting *"runs as uid 1000,
not the coordinator identity"*.

## 10. Production, read-only

Re-measured after the fix. Nothing was written; no privileged command was run
and none succeeded.

```
HOST_GENERATION         15
helper compatibility    incompatible, 8 declared, 3 blocking, supervision_ready false
three helper targets    6d06695f… / 7703231318f7… / 4886d5b3…     predecessor bytes
pinned entrypoints      0d9c8d8c…ede51a1 / 2878fff0…db75798f77     unchanged
sudoers metadata        f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9
verify grant            ABSENT
CINV count 1            CRES count 0        CINV-000002 unspent
CINV-000001             1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   UNRESOLVED
```

`PRODUCTION_MUTATION = NONE`.

## 11. What happens next

**This report does not install helpers and does not authorize them.** The
corrected gate has never been run against the real host — only against a fixture
that now models it. The next privileged action is the same governed ceremony,
re-run read-only up to `--verify`, so the corrected gate is proved against
production before anything is published.

```
HELPER_INSTALL_AUTHORISED = NO
```

The ceremony below is unchanged and is reproduced verbatim from the committed
artefact. **Its `--verify` stage is the one to watch**: it must now report

```
ok  both accepted execution grants are present, each pinning the installed
    entrypoint by digest and command; the verification grant is absent
```

and reach the readiness report. If `--verify` passes, return the complete output
for a fresh authorization checkpoint — **do not let the chain continue into
`--install` on this pass.** Run only the first two stages:

```bash
set -Eeuo pipefail
cd /opt/schott-platform

sudo test ! -e /root/kyri-g11-bb-helper-transaction/journal \
  || { printf 'STOP: a helper transaction journal exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }
sudo test ! -e /root/kyri-g11-bb-helper-transaction \
  || { printf 'STOP: helper transaction residue exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }

sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --verify-source \
  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --verify
```

### 11.1 The full governed ceremony, for the authorization after this one

Extracted byte-for-byte from `provisioning/execution/helper-operator-ceremony.txt`.
**Not authorized to run yet** — it is reproduced so the reviewer can see exactly
what a later checkpoint would authorize.

```bash
#!/usr/bin/env bash
# The corrected privileged-helper ceremony, exactly as it is to be typed.
#
# This file is reference text, not a script to run: the operator pastes it into
# a root-capable shell so every command and every refusal is visible on the
# console. It lives here rather than only in a report so the test suite can
# execute it against a stub installer and prove the control flow, instead of
# trusting that a fenced block in prose does what its prose says -- which is the
# defect that let the Generation-15 block reach --install after a refusal.
#
# The property under test: no later stage can run after an earlier one refused.
#
# ORDER. This ceremony is second. It must run only against an installed and
# accepted Generation 15: the installer refuses otherwise, because Generation
# 15 carries the readiness rule that declares these corrected helper digests.
set -Eeuo pipefail
cd /opt/schott-platform

# An unexpected transaction is the one condition that must stop everything
# before any installer runs. It would mean a previous ceremony did not finish,
# and the correct response is inspection, not cleanup.
sudo test ! -e /root/kyri-g11-bb-helper-transaction/journal \
  || { printf 'STOP: a helper transaction journal exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }
sudo test ! -e /root/kyri-g11-bb-helper-transaction \
  || { printf 'STOP: helper transaction residue exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }

# The runtime this ceremony is judged by. Generation 15 must already be
# installed and accepted; the installer checks it too, and refuses.
sudo test -e /root/kyri-gen15-library-digests.txt \
  || { printf 'STOP: Generation-15 evidence is absent. Install and accept Generation 15 first.\n' >&2; exit 1; }

# The verification entrypoint stays unauthorised through this ceremony.
sudo test ! -e /etc/sudoers.d/kyri-exec-verify \
  || { printf 'STOP: the verification grant exists. Nothing authorised it.\n' >&2; exit 1; }

sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --verify-source \
  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --verify \
  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --install \
  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --verify-installed
```

Still prohibited: installing helpers, `--recover`, modifying sudoers, removing
the launch or reconcile grants, renewing Fabric, invoking, touching
`CINV-000001`, spending `CINV-000002`.

```
CINV_000001_FINAL_CLASSIFICATION  UNRESOLVED    CINV_000001_RESUME_AUTHORISED  NO
PRODUCTION_INVOKE_AUTHORISED      NO
```
