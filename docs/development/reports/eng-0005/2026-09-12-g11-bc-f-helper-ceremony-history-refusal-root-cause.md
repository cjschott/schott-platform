# ENG-0005 G11-BC-F — the helper ceremony's invocation-history refusal, root-caused

**Status: the refusal was correct, the ceremony's reviewed-history declaration
was wrong, and nothing was published. Generation 17 stands; the corrected helper
is still not installed.**

The G11-BC-E ceremony halted at `--verify` against the real host:

```
STOP: the invocation history has moved past the reviewed one
      (2 invocation(s), 0 result(s) against 1 and 0 reviewed);
      re-review before installing
```

**That gate did exactly what it exists for.** It says "the host is the one the
reviewer looked at", and the host was not — because the declaration described a
review that happened for a *different ceremony*.

```
HELPER_INSTALL_ATTEMPT_PUBLICATION  NONE
HELPER_HISTORY_ROOT_CAUSE           reviewed-history declaration inherited verbatim from G11-BB
HISTORY_POLICY_OLD                  correct in shape, stale in data
HISTORY_POLICY_NEW                  unchanged policy, re-derived data
HISTORY_CHECK_LIVE_WRONG            1        LATENT  0
RUNTIME/HELPER BYTES CHANGED        NO / NO        SUDOERS_CHANGE_REQUIRED  NO
```

Branch `arch/eng-0005-execution-transition`. No execution, no recovery, no
deployment, no mutation of production state.

---

## 1. Current helper state, proven independently

The chained operator block was `verify-source && verify && install &&
verify-installed`, so the halt at `--verify` means `--install` was never
reached. Verified rather than assumed:

```
installed kyri_exec_transition_action.py
  b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315   THE PREDECESSOR
corrected checkout
  d40f5121a3a358ee4351ac760c2bcc7f259b229c4190635e832814672c0c21de   NOT installed

helper compatibility  incompatible      declared 8      blocking 1
blocking object       stale /usr/lib/kyri/python/kyri_exec_transition_action.py
supervision_ready     false
```

**Generation 17 is installed and intact:**

```
helpers.py            78da8519db99fa06e809755808397fe36bb8c83872deab142987c98308b38a4f
kyri_exec_launcher.py 152038b198c112c3f5f042114eb6e7f4ffa3a9caeb431908bfe7f208b136447d
kyri_exec_podman.py   04205c53ec0e10bef13099dd3a84c483e43ed9441335805665f957a5bbdd896b
```

**The invocation store is untouched:**

```
CINV-000001  1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV-000002  923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
INVOCATION_SEQ 2     CRES_COUNT 0     both lifecycles at launch_authorized
Fabric 3fa32b83…  Trust 53605e4e…  sudoers two grants + verify absent
handoff out/ still 0700 cschott:cschott
```

```
HELPER_TRANSACTION_STATE = NOT OBSERVABLE (operator check)
```

`/root` is not readable by the coordinator, so I cannot inspect
`/root/kyri-g11-bc-e-helper-transaction` directly. **A `--verify` refusal cannot
create one** — the transaction root is created by `--install`, which never ran,
and `--verify` calls `require_no_transaction_residue` rather than writing. The
operator check is in §8. Nothing was deleted.

## 2. Root cause

The refusal comes from `require_accepted_invocation_history` in the ceremony,
under its `reviewed` freshness mode:

```bash
if [[ "${freshness}" == "reviewed" ]]; then
  (( invocations == ${#ACCEPTED_INVOCATION_HISTORY[@]} && results == ${#ACCEPTED_RESULT_HISTORY[@]} )) \
    || halt "the invocation history has moved past the reviewed one …"
```

and the declaration it counts against was:

```bash
ACCEPTED_INVOCATION_HISTORY=(
  "CINV-000001 1dcef40d…"
)
ACCEPTED_RESULT_HISTORY=()
```

```
HELPER_HISTORY_EXPECTED_CINV  1, from ACCEPTED_INVOCATION_HISTORY in
                              install-g11-bc-e-helpers.sh — a compiled-in
                              reviewed-history declaration, NOT derived from
                              report authority, fixture generation, predecessor
                              evidence, or the runtime reader
HELPER_HISTORY_EXPECTED_CRES  0, from ACCEPTED_RESULT_HISTORY, same file
LIVE_HISTORY_CINV             2
LIVE_HISTORY_CRES             0
```

```
ROOT_CAUSE = The G11-BC-E ceremony was derived from install-g11-bb-helpers.sh.
             Everything identifying it was re-derived -- reviewed commit,
             required runtime generation, matrix, transaction namespace,
             namespace-isolation guard -- but ACCEPTED_INVOCATION_HISTORY was
             carried over verbatim. It named CINV-000001 alone, which was the
             entire invocation history when G11-BB was reviewed on 2026-09-06.
             CINV-000002 has existed since 2026-09-09, so the freshness gate
             correctly reported a host the G11-BC-E reviewer had not described.
```

**This is not a stale constant in the naive sense.** It is *production data*
that must be re-derived per ceremony, and it was the one field of that kind that
the derivation missed.

### 2.1 verify versus verify-installed — the split was already right

The two call sites ask different questions, and both were correct before this
checkpoint:

| mode | freshness | rule |
| --- | --- | --- |
| `--verify` (preflight) | `reviewed` | the history must be **exactly** the reviewed one |
| `--verify-installed` | `installed` | reviewed records intact and the store sound; **later governed history tolerated** |

The `installed` branch performs no count comparison at all, which is why the
already-accepted G11-BB deployment still attests today against a host that has
since gained `CINV-000002`.

## 3. Why no test caught it

**The production declaration is structurally unreachable from every fixture
case.** Under `--fixture` the ceremony empties both arrays and reads the
fixture's own declaration file instead:

```bash
ACCEPTED_INVOCATION_HISTORY=()
ACCEPTED_RESULT_HISTORY=()
ACCEPTED_HISTORY_DECLARATION="${FIXTURE}/root/kyri-accepted-invocation-history.txt"
```

and the suite builds its host with `build_invocation_store … 1 0 1 0` — one
record, declared as one. Every history case passed because the fixture supplied
*both* halves of the comparison.

**That is the G11-BB-Z shape exactly**: a fixture that provides its own version
of the thing under test cannot see the real one being wrong. There it was a
`invocation_id` set equal to the `CINV`; here it is a reviewed-history
declaration set equal to the fixture's own store.

## 4. What the ceremony must protect — policy, decided rather than adjusted

The brief asks whether the invariant should be A (exact reviewed history), B
(reviewed records intact, later history tolerated), C (no active execution), or
a combination. Answered from what the ceremony actually does:

- **There is no container or lifecycle check anywhere in the ceremony.** The
  freshness gate is a *review-currency* gate, not container safety. Execution is
  already closed by the compatibility rule (`incompatible` →
  `supervision_ready false`), which is what prevents a new execution starting
  during the swap.
- So the answer is **D — a combination, and the ceremony already implements
  it**: A at the preflight, B at the post-install attestation, both on top of
  per-record digest pinning and counter/record agreement.

```
HISTORY_POLICY_OLD  preflight: exact reviewed history (counts + per-record digests)
                    post-install: reviewed records intact, later history tolerated
                    -- correct in shape, but the reviewed data named one record

HISTORY_POLICY_NEW  IDENTICAL POLICY. The reviewed history is re-derived for THIS
                    ceremony: CINV-000001 and CINV-000002 by identity and digest,
                    no results.
```

**The gate was not relaxed and "accept whatever exists" was not adopted.** Both
records are immutable pre-execution evidence, so pinning their digests stays
durable — neither can legitimately change again.

```bash
ACCEPTED_INVOCATION_HISTORY=(
  "CINV-000001 1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa"
  "CINV-000002 923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa"
)
ACCEPTED_RESULT_HISTORY=()
```

The empty result history is load-bearing: it is what asserts that Stage 3 wrote
nothing.

## 5. RED-first, against the production shape

```
RED   fixture: 2 invocations, 0 results, declared 1 and 0
      -> STOP: the invocation history has moved past the reviewed one
               (2 invocation(s), 0 result(s) against 1 and 0 reviewed)
      PASS: the production refusal reproduces exactly, word for word

GREEN same host, declared 2 and 0
      PASS: the same host is accepted once the reviewed history names both records

CONTROL a THIRD invocation, declared 2 and 0
      PASS: an unreviewed third invocation still refuses -- freshness is intact
```

The third case is the one that proves the correction is a data fix and not a
weakening.

### 5.1 The guard that would have caught it, added

A host-only case now reads the **shipped** declaration and compares it against
the live store — the only case in the suite that can fail for the reason
production failed:

```
PASS: production: the shipped invocation history is exactly the live store
PASS: production: the shipped result history is exactly the live store (both empty)
PASS: production: the invocation counter (2) agrees with the declared record count
```

Proven to work by reverting the declaration to its stale form:

```
FAIL: production: the shipped invocation history is not the live store.
FAIL: production: the counter is 2 against 1 declared record(s)
```

## 6. Negative controls

The existing nine still pass, and five more run against a **two-record** host,
because controls that only ever perturb the first record would leave half the
reviewed history unguarded:

```
an invocation record nobody reviewed              refused
a result record nobody reviewed                   refused
the reviewed CINV rewritten                       refused
the reviewed CINV removed                         refused
the next invocation identity spent                refused
a malformed invocation record                     refused
a partial write left in the record store          refused
an unexpected object in the record store          refused
declared history with no runtime store            refused

CINV-000002 rewritten                             refused   <- new
CINV-000002 removed                                refused   <- new
CINV-000001 rewritten on a two-record host         refused   <- new
the counter behind the durable history             refused   <- new
a synthetic CRES-000001 nobody produced            refused   <- new
```

```
HISTORY_REGRESSION = PASS      HISTORY_NEGATIVE_CONTROLS = PASS
```

## 7. Same-defect-class sweep

Every deployment surface that reads invocation history:

| surface | check | class |
| --- | --- | --- |
| `install-generation-10` … `-17` | **none** — no generation installer gates on invocation history at all | SAFE (not applicable) |
| `install-g11-ax-helpers.sh:553` | `count == 0 \|\| halt "expects none"` | **HISTORICAL_ONLY** — accepted and completed on a host with zero invocations. BB-R already recorded this model as superseded. Re-running it today would refuse, and it is not re-runnable. |
| `install-g11-bb-helpers.sh` | declares `CINV-000001` only | **HISTORICAL_ONLY** — accepted and completed 2026-09-06, when that *was* the history. Its `--verify-installed` uses the `installed` branch, which performs no count comparison, so the accepted deployment still attests correctly today. Only its preflight would refuse, and that ceremony is finished. |
| `install-g11-bc-e-helpers.sh` | declared `CINV-000001` only | **LIVE_AND_WRONG → fixed** — this ceremony has not run and must run against today's host. |

```
HISTORY_CHECK_LIVE_WRONG    1
HISTORY_CHECK_LATENT_WRONG  0
```

No unrelated surface was changed. The G11-BB declaration is deliberately left
alone: rewriting a completed ceremony's record of what its reviewer saw would
destroy the evidence, and its post-install attestation is already correct.

### 7.1 A second class surfaced, and it is the known one

Full validation then failed at `generation13-packaging`:

```
AssertionError: ('objects in neither declared state',
  [('kyri_exec_podman.py', '04205c53…'),
   ('kyri_exec_launcher.py', '152038b1…'),
   ('tools/capability/execution/helpers.py', '78da8519…')])
```

**This is the succession-staleness class, for the fourth time**, and it is
caused by Generation 17 being *installed* rather than by anything in this
correction. Seven suites enumerate the ceremonies they account for; each list
stopped at Generation 16, so the three objects Generation 17 moved were in no
declared state.

`tests/lib/succession.sh` exists for exactly this and records the first two
occurrences; G11-BC-C recorded the third and extended the same seven lists to
Generation 16. All seven now name Generation 17:

```
generation12-packaging      creates enumeration
generation13-packaging      superseded_by_successor, helper_creates, fixture rewind
generation13-installer      fixture rewind
generation14-installer      succession_rewind
helper-ceremony             succession_rewind
```

All five suites pass after the change. This is separate from the history
defect and is reported rather than folded into it.

## 8. Cross-surface order, reconfirmed

```
HOST_GENERATION       17
helper compatibility  incompatible    blocking 1    supervision_ready false
blocking object       /usr/lib/kyri/python/kyri_exec_transition_action.py
```

Unchanged by this correction, and it must be: **the history fix touches no
compatibility semantics.** The only ceremony that can move the action module to
its corrected target is still the helper ceremony — `install-generation-5`,
`install-g11-ax-helpers` and `install-g11-bb-helpers` also name that path, but
all three are completed historical ceremonies.

Stage 3 is not reopened. Nothing about this checkpoint changes the execution
gate, and `supervision_ready` stays false until the helper ceremony completes.

## 9. Deployment impact

```
RUNTIME_BYTES_CHANGED_BY_HISTORY_FIX   NO
HELPER_BYTES_CHANGED_BY_HISTORY_FIX    NO
SUDOERS_CHANGE_REQUIRED                NO
```

Two files changed, and neither is a deployed object:

```
provisioning/execution/install-g11-bc-e-helpers.sh      operator tooling
tests/test-capability-execution-bc-e-helper-ceremony.sh test only
```

No generation or helper matrix declares the ceremony script as an installed
target — Generation 17 references it only in
`CEREMONIES_AFTER_THIS_GENERATION`, which reads its `MATRIX` block for the
accepted-overlay model, and **the `MATRIX` block is untouched** by this fix. The
four digests the deployment turns on are unchanged:

```
kyri-exec-transition-action.py  d40f5121…    kyri-exec-podman.py    04205c53…
kyri-exec-launcher.py           152038b1…    helpers.py             78da8519…
```

So the prepared Generation-17 and helper ceremonies remain exactly as reviewed;
this checkpoint corrects only what the helper ceremony believes it was reviewed
against.

## 10. What the next `--verify` will and will not prove

The operator's run halted **at** the history gate, so everything before it
passed on the real host: repository, source digests, namespace isolation, Root
Authority unmounted, runtime generation, identity authorities, and the sudoers
gates.

**The checks after it have never run against production.** They are
`require_predecessor_state`, `require_no_transaction_residue`,
`require_same_filesystem`, the ceremony-coherence report, and the two readiness
verdicts. The fixture suite exercises all of them, but the next `--verify` is
the first time they meet the real host.

I am not predicting they pass. The known blocker is removed; if another gate
refuses, that refusal is information and the ceremony should stop again.

## 10.1 Validation

```
FOCUSED
  BC-E helper ceremony   PASS   BB helper ceremony    PASS
  generation 17 installer PASS  helper coherence      PASS
  supervision            PASS
  generation12-packaging PASS   generation13-packaging PASS
  generation13-installer PASS   generation14-installer PASS
  helper-ceremony        PASS   shellcheck            clean

LOCAL_FULL   PASS  137/137 steps
LOCAL_QUICK  PASS  112/112 steps
GITHUB_CI    PASS  6/6 — CI, ShellCheck, Semgrep, CodeQL, Trivy, Gitleaks
CLEAN_CLONE  PASS  the corrected declaration and both files reproduce
                   byte-identically; the suite passes from a fresh clone, and
                   the four deployment digests are unchanged
HOST_ONLY    the helper-ceremony suite is host-only and reports HOST_ONLY_SKIP
             in CI, so the local host run is the authority for it -- including
             the new production-declaration case, which CI cannot execute
```

## 11. Production non-mutation

```
HOST_GENERATION 17                     corrected helper NOT installed
installed kyri_exec_transition_action.py  b11a2f19…  (the predecessor)
helper compatibility incompatible      blocking 1     supervision_ready false
CINV-000002  923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
CINV-000001  1dcef40d…                 INVOCATION_SEQ 2      CRES_COUNT 0
lifecycle    both at launch_authorized, four journal records, unchanged
handoff      ownership and modes untouched
Fabric 3fa32b83…   Trust 53605e4e…     sudoers two grants, verify absent
```

```
NO EXECUTE. NO RECOVER. NO HELPER DEPLOYMENT. NO CONTAINER. NO CRES.
NO FABRIC, TRUST, SUDOERS OR HANDOFF MUTATION.
```

Every ceremony invocation in this checkpoint used `--fixture` or
`--verify-source`.

## 12. Next — a fresh helper-ceremony reauthorisation

The operator should, in order:

1. **Return the transaction-residue check** (the one thing I cannot read):

```bash
sudo test ! -e /root/kyri-g11-bc-e-helper-transaction \
  && echo "no G11-BC-E transaction residue (expected)" \
  || { echo "STOP: residue exists. Do not delete it. Report it."; }
```

2. Re-run the **unchanged** stage-two operator block from G11-BC-E §12, which
   now meets a ceremony whose reviewed history matches the host.

3. Return the full output. If any gate after the history check refuses, stop
   there — §10 explains why those are the first-run gates.

```
HELPER_INSTALL_AUTHORISED  NO      STAGE3_AUTHORISED  NO
CINV_000002_RESUME_AUTHORISED  NO  PRODUCTION_INVOKE_AUTHORISED  NO
```
