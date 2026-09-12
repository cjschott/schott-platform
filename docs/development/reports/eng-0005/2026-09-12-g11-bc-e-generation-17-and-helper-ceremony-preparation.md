# ENG-0005 G11-BC-E — Generation 17 and the helper ceremony, prepared

**Status: both ceremonies are built, tested and NOT installed. The required
production order was derived by measurement, not inherited from precedent — and
the reverse order turns out to be actively unsafe.**

```
REQUIRED_PRODUCTION_ORDER   Generation 17 (helpers.py FIRST within it) -> G11-BC-E helper ceremony
MIXED_RUNTIME_EXECUTABLE    NO
GEN17                       3 REPLACE, 0 CREATE, 0 REMOVE, 0 CARRYOVER, groups H and A
HELPER CEREMONY             1 REPLACE
SUDOERS_CHANGE_REQUIRED     NO
HANDOFF_SAME_CLASS          live 0  latent 0        CWD_SAME_CLASS  live 0  latent 0
CINV_000002_CONTINUITY      YES     RESUME_POSSIBLE YES     RESUME_AUTHORISED  NO
```

Two things changed since G11-BC-D accepted the corrections, both found by the
sweeps this checkpoint requires, and both change a digest the reviewer had
already seen. They are in §2.

Branch `arch/eng-0005-execution-transition`. Nothing was installed; no
execution, no recovery, no mutation of any production state.

---

## 1. Live baseline, proven before any ceremony design

```
HOST_GENERATION      16     recovery.py fdad3cec…, cli.py 7b4fac3e…
library objects      81
CINV-000002          923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
lifecycle            launch_authorized     INVOCATION_SEQ 2     CRES_COUNT 0
launch authorisation cimp CIMP-000001, commitment 58ef2481…, profile b707d433…
handoff              out/ still 0700 cschott:cschott — NOT touched by any diagnostic
Fabric 3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b   unchanged
Trust  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   unchanged
entrypoints          0d9c8d8c… / 2878fff0…      sudoers  two grants, verify absent
Root Authority       unmounted (no kyri mount)
```

**Helper compatibility reflects the INSTALLED state, not the corrected
checkout**, which is what the brief asks for:

```
helper_compatibility  compatible    blocking 0    supervision_ready true
```

That is state A of the matrix in §4 and is exactly what a Generation-16 host
with the predecessor helper should report.

`kyri-CINV-000002` container absence needs the execution identity's Podman
store, which requires operator sudo — carried as an operator check, unchanged
from G11-BC-C §2.4.

## 2. Two corrections to the accepted corrections

### 2.1 The safe working directory was already governed, and BC-D duplicated it

The policy module has carried this since T10:

```python
WORKING_DIRECTORY = "/"                      # kyri-exec-transition.py:65
working_directory: str                       # on TransitionPolicy
    working_directory=WORKING_DIRECTORY,     # populated in policy_for
```

**Nothing ever read it.** Declared and never wired — the same shape as the
output-leaf transfer, in the same file, found by the §3 sweep.

G11-BC-D added a *second* constant, `SAFE_WORKING_DIRECTORY`, in the action
layer. That would have put two copies of one decision in the two layers whose
entire separation is that one decides and the other performs. `drop_privilege`
now consumes `policy.working_directory` and the duplicate is gone.

```
action module   2bd86f3d…  (the BC-D value the reviewer saw)
             -> d40f5121a3a358ee4351ac760c2bcc7f259b229c4190635e832814672c0c21de
```

**The behaviour is identical.** What changed is provenance: a deployment that
ever needs a different safe directory now changes it in the layer allowed to
choose.

### 2.2 The last two inherited-cwd sites are closed

The brief requires `CWD_SAME_CLASS_LATENT_WRONG=0`. BC-D reported 2 and left
them: `kyri-exec-launcher.py` spawns both privileged helpers and stated argv,
environment, descriptors and shell — but not `cwd`. Those helpers start as root,
so no failure was reachable, which is why they were latent.

They are closed anyway, for two reasons: the launcher's own contract is that it
states what it creates, and an inherited cwd is the one property that can make
`Popen` fail outright — a coordinator whose working directory has been removed
cannot spawn a helper at all, as root or otherwise.

```
kyri_exec_launcher.py  78c6de90…  ->  152038b198c112c3f5f042114eb6e7f4ffa3a9caeb431908bfe7f208b136447d
```

This adds a third object to Generation 17. It is a scope increase and it is
stated rather than folded in quietly.

## 3. Both sweeps at HEAD

### 3.1 Handoff children

Measured against the worker's own `EXPECTED_MODES` and open flags:

| child | mode | consumer needs | class |
| --- | --- | --- | --- |
| handoff root | `0711` | `O_PATH` anchor only | TRAVERSE_ONLY — SAFE |
| `<CINV>/` | `0555` | `O_RDONLY|O_DIRECTORY` | READ_REQUIRED — SAFE |
| `package/` | `0555` | `O_RDONLY|O_DIRECTORY` | READ_REQUIRED — SAFE |
| `payload` | `0444` | `O_RDONLY` | READ_REQUIRED — SAFE |
| `profile` | `0444` | root reads before the drop, then sealed | SAFE |
| `out/` | `0700` | owner rw as 999 | transferred by the privileged transition |

```
HANDOFF_SAME_CLASS_LIVE_WRONG    0
HANDOFF_SAME_CLASS_LATENT_WRONG  0
```

### 3.2 cwd at every process creation

Enumerated from the AST across `provisioning/execution/`,
`tools/capability/execution/` and `cli.py`:

```
kyri-exec-podman.py:275   subprocess.run     cwd STATED
kyri-exec-podman.py:430   subprocess.run     cwd STATED
kyri-exec-podman.py:510   subprocess.run     cwd STATED
kyri-exec-launcher.py:268 subprocess.Popen   cwd STATED
kyri-exec-launcher.py:288 subprocess.run     cwd STATED
transition-action execve x2                  the drop closes cwd before both

CWD_SAME_CLASS_LIVE_WRONG    0
CWD_SAME_CLASS_LATENT_WRONG  0
```

## 4. The cross-surface order, derived by measurement

`helpers.compatibility()` was evaluated against real bytes in each state, with
the action module redirected at a fixture holding each digest.

| state | declaration | installed action | verdict | blocking | ready |
| --- | --- | --- | --- | --- | --- |
| **A** current production | Gen16 | predecessor | `compatible` | 0 | true |
| **B** Gen17 first, mid-order | Gen17 | predecessor | `incompatible` | 1 | **false** |
| **C** helper first, mid-order | Gen16 | corrected | `incompatible` | 1 | **false** |
| **D** final | Gen17 | corrected | `compatible` | 0 | true |

Both surface-level intermediates fail closed, so the surface *pair* is safe in
either order. **The order is decided by partial publication inside
Generation 17**, which has three objects and only one that moves the
declaration.

Simulating every publication point:

```
ORDER 1  Gen17 first, helpers.py published FIRST within it
  0. start (Gen16 + predecessor helper)          OPEN    <- legitimate: production now
  1. Gen17: helpers.py                           closed
  2. Gen17: + kyri_exec_podman.py                closed
  3. Gen17: + kyri_exec_launcher.py              closed
  4. helper ceremony committed (FINAL)           OPEN    <- legitimate: complete and coherent
  UNSAFE POINTS: 0

ORDER 2  helper ceremony first
  1. helper ceremony committed                   closed
  2. Gen17: helpers.py                           OPEN    <- MIXED AND OPEN
  3. Gen17: + podman                             OPEN    <- MIXED AND OPEN
  4. Gen17: + launcher                           OPEN    <- MIXED AND OPEN
  UNSAFE POINTS: 3

ORDER 1-VARIANT  Gen17 first but helpers.py published LAST
  1. Gen17: podman                               OPEN    <- MIXED AND OPEN
  2. Gen17: + launcher                           OPEN    <- MIXED AND OPEN
  UNSAFE POINTS: 2
```

**Helper-first is actively unsafe, and the reason is specific.** Generation 17
publishes `helpers.py` first; with the action module already corrected, that
publication *reopens* execution mid-transaction while the Podman backend and the
launcher are still predecessors.

```
REQUIRED_PRODUCTION_ORDER = GEN17_THEN_HELPER_CEREMONY,
                            with helpers.py as Generation 17's matrix row 1
```

The ceremony enforces its own half: `require_runtime_generation` halts unless
the Generation-17 readiness rule is installed. Generation 17 enforces the other:
`require_fail_closed_first` halts if `helpers.py` is not row one.

## 5. Generation-17 scope

```
GEN17_REPLACE    3        GEN17_CREATE  0    GEN17_REMOVE  0    GEN17_CARRYOVER  0
```

| repository path | installed path | predecessor | successor | group |
| --- | --- | --- | --- | --- |
| `tools/capability/execution/helpers.py` | `/usr/lib/kyri/python/tools/capability/execution/helpers.py` | `6dd936064f1c6d3813cbdbd9fb175b03902b18623493638cded55e3e930b8b07` | `78da8519db99fa06e809755808397fe36bb8c83872deab142987c98308b38a4f` | **H** |
| `provisioning/execution/kyri-exec-launcher.py` | `/usr/lib/kyri/python/kyri_exec_launcher.py` | `78c6de9093a535618b6fee54cd90c8eab388bc7ba6e4bd39d42de7f2e019bc83` | `152038b198c112c3f5f042114eb6e7f4ffa3a9caeb431908bfe7f208b136447d` | **H** |
| `provisioning/execution/kyri-exec-podman.py` | `/usr/lib/kyri/python/kyri_exec_podman.py` | `cf26b29810e4298000803f36481c4439d116b380df316262c2f8696b5e24ebe8` | `04205c53ec0e10bef13099dd3a84c483e43ed9441335805665f957a5bbdd896b` | **A** |

All three are `0444 root:root`. Library object count 81 → 81.

### 5.1 Are helpers.py and kyri_exec_podman.py in the same group? NO

They keep the assignments they already had, rather than being regrouped to make
the matrix look uniform:

- **H** — `helpers.py` and `kyri_exec_launcher.py` were both group H at
  Generation 15. H is the boundary between the coordinator and the privileged
  helpers: what the runtime expects of them, and what it hands them when it
  starts one. Both members move, so H is wholly at one generation at every
  committed state.
- **A** — `kyri_exec_podman.py` has been group A since Generation 13. It is the
  container-runtime binding, a different concern, and merging it into H because
  both happen to change here would destroy the only thing the group column is
  for.

There is no carryover: every member of both groups is a declared row. The
`CARRYOVER=()` list is kept rather than deleted so that adding one later is a
reviewable edit, and the ceremony still runs the collision check over it.

## 6. Helper ceremony scope

```
HELPER_REPLACE   1     HELPER_CREATE  0     HELPER_REMOVE  0
```

| repository path | installed path | predecessor | successor | closure |
| --- | --- | --- | --- | --- |
| `provisioning/execution/kyri-exec-transition-action.py` | `/usr/lib/kyri/python/kyri_exec_transition_action.py` | `b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315` | `d40f5121a3a358ee4351ac760c2bcc7f259b229c4190635e832814672c0c21de` | INSIDE |

**`kyri-exec-worker.py` and `kyri-exec-quota.py` do NOT change**, proven by
digest — G11-BB moved both and nothing in these corrections touches them.
Republishing an object to make a ceremony look symmetrical would change what
root executes for no stated reason.

### 6.1 Sudoers does not change, proven by digest

```
kyri-exec-transition-entrypoint.py  0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1
/usr/libexec/kyri-exec-transition   0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1  IDENTICAL

kyri-exec-reconcile-entrypoint.py   2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77
/usr/libexec/kyri-exec-reconcile    2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77  IDENTICAL
```

Neither entrypoint is a row in either ceremony. Both grants keep matching by
digest.

```
SUDOERS_CHANGE_REQUIRED = NO
```

## 7. The widened privileges are narrow, proven by refusal

The accepted ruling permits `os.fchown` on an already-opened, no-follow-verified
descriptor, and `os.chdir` as privilege-transition sanitisation. Eight new cases
assert what those capabilities still **cannot** do:

```
fchown: only the descriptor form exists, never a pathname          PASS
        (os.chown, lchown, chmod, fchmod, fchownat all absent; exactly ONE call site)
fchown: the transfer refuses before it has verified the object     PASS
        (S_ISDIR and S_IMODE both precede the transfer; both re-checked after)
fchown: a symlinked leaf is refused, not followed                  PASS
        (driven against a real symlinked out/ -- no fchown is issued at all)
fchown: a leaf at the wrong mode is refused rather than corrected  PASS
        (0755 out/ -- the transfer is not a repair)
fchown: the identity comes from the policy, and nowhere else       PASS
        (no getuid/getenv/argv/pwd/grp in the transfer; the leaf name is compiled in;
         the signature is exactly (policy, backend))

chdir:  exactly two call sites, both taking the governed value     PASS
chdir:  no caller-, environment- or payload-derived directory      PASS
chdir:  the safe directory is traversable by every identity        PASS
        (/ is root-owned with the other-execute bit set -- the whole requirement)
```

```
FCHOWN_BACKSTOP = PASS      CHDIR_BACKSTOP = PASS
```

**One of these guards initially failed on the drop's own docstring**, which
names the deployment path the incident happened on. That is the mistake BC-D
corrected in the Podman coupling check, repeated: it tested commentary rather
than derivation. It now strips the docstring and asserts against the executable
body — so the accepted bytes did not have to change to satisfy a guard about
prose.

## 8. RED-first evidence, preserved

Both corrections were reverted one at a time against the finished suite:

```
WITHOUT the ownership transfer
  FAIL  the accepted credential sequence runs in exactly the accepted order
  FAIL  descriptors are closed before any credential change
  FAIL  the output leaf is transferred to the execution identity
  FAIL  the transfer happens while privilege is still held
  FAIL  a refused transfer prevents the drop and the exec

WITHOUT the cwd closure
  FAIL  the accepted credential sequence runs in exactly the accepted order
  FAIL  the credential drop closes cwd as well as credentials
  FAIL  cwd is closed before the identity changes, so no step runs unreachable
```

The pinned sequence is the evidence that ordering, not just presence, is
correct:

```
fchown -> close_extra_descriptors -> chdir -> setgroups -> setgid -> setuid
  -> credentials -> set_no_new_privs -> get_no_new_privs -> credentials -> execve
```

The transfer needs root, so it precedes every credential step; the chdir sits
inside the drop, before the identity changes. A failure at either prevents the
drop and the exec.

**The transfer is verified, not merely issued.** An unprivileged fixture cannot
hand the leaf to 999:987, and the production post-transfer check refuses when
the transfer does not take effect — which the suite asserts. The same path is
then driven to completion with a policy naming an identity the fixture *can*
transfer to, so the refusal is proven to be the verification working rather than
the transfer being unimplemented.

## 9. The cross-surface interruption matrix

Generation 17's suite walks all ten publication boundaries and, at each,
requires the host to be either fail-closed or complete and coherent:

```
every point:  three rows at exactly one of their two declared digests, never between
              residue only where cleanup itself failed
              execution CLOSED, or rolled back to the complete Generation-16 runtime

MIXED_RUNTIME_EXECUTABLE = NO
```

The helper ceremony's suite does the same over its own ten boundaries and
requires a whole helper set at each, never a mixture.

## 10. CINV-000002 continuity

```
CINV_000002_CONTINUITY_ACROSS_DEPLOYMENT = YES
```

Neither ceremony reads or writes a capability record. The Generation-17 matrix
names three library objects; the helper matrix names one; neither touches
`/data/kyri/capability-runtime`, `/data/kyri/capability-handoff`,
`/var/lib/kyri/fabric` or `/var/lib/kyri/trust`. Both installers fingerprint the
authority namespace and the privileged surface before and after and report any
change.

What Stage 3 binds to is unchanged by both: the launch authorisation, the
published handoff bytes, the profile digest, the commitment, the package, and
the selection binding are all durable records neither ceremony can reach. No
`authorise_launch` runs, no CINV is allocated, no CRES is written, and the
lifecycle stays at `launch_authorized` with its two journal records.

The Generation-17 suite asserts the invocation-history invariant the G11-BB
ceremony established, and the helper suite asserts that a legitimately advanced
history is accepted while a rewritten reviewed record is refused.

## 11. Resume semantics, reconfirmed after both corrections

```
command_execute lifecycle guard         NONE — it reads the record and the
                                        published authorisation, and consults
                                        no state machine
authorise_launch at LAUNCH_AUTHORIZED   accepted, `resumed = True`
result collision on retry               record_terminal_result refuses a second
                                        attempt_number == 1 — and none exists
```

A future `execute --cinv CINV-000002` would therefore:

- **not allocate CINV-000003.** It takes the CINV as an argument and allocates
  nothing; only `record_terminal_result` allocates, and it allocates a `CRES`.
- **not require another authorise-launch.** The published authorisation is read
  back by `supervised_binding`; nothing re-runs the Stage-2 decision.
- **not overwrite the immutable CINV.** `record_terminal_result` never touches
  the invocation record, by design and by assertion.
- **handle the previous failed attempt safely.** That attempt wrote nothing —
  `result_recorded: false` — so there is no partial record to collide with.
- **need no prior recovery**, because no container survived: the refusal
  happened before one existed, `worker_reaped` was true, and no `kyri-CINV-*`
  container is present.

```
CINV_000002_RESUME_POSSIBLE   YES, after both ceremonies
CINV_000002_RESUME_AUTHORISED NO
```

## 12. The exact operator ceremonies

**Stage one — Generation 17** (`provisioning/execution/gen17-operator-ceremony.txt`):

```bash
set -Eeuo pipefail
cd /opt/schott-platform

sudo test ! -e /root/kyri-gen17-transaction/journal \
  || { printf 'STOP: a Generation-17 transaction journal exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }
sudo test ! -e /root/kyri-gen17-transaction \
  || { printf 'STOP: Generation-17 transaction residue exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }

sudo test -f /root/kyri-gen16-library-digests.txt
sudo test -f /root/kyri-gen16-helper-digests.txt

sudo bash /opt/schott-platform/provisioning/execution/install-generation-17.sh --verify-source \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-17.sh --verify \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-17.sh --install \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-17.sh --verify-installed
```

**EXPECTED INTERMEDIATE STATE, and it is not a fault:**

```
helper compatibility  incompatible
helpers blocking      1   (kyri_exec_transition_action.py)
supervision_ready     false
```

**Stage two — the helper ceremony**
(`provisioning/execution/g11-bc-e-helper-operator-ceremony.txt`), only after
stage one is returned and accepted:

```bash
set -Eeuo pipefail
cd /opt/schott-platform

sudo test ! -e /root/kyri-g11-bc-e-helper-transaction/journal \
  || { printf 'STOP: a G11-BC-E helper transaction journal exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }
sudo test ! -e /root/kyri-g11-bc-e-helper-transaction \
  || { printf 'STOP: G11-BC-E helper transaction residue exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }

sudo test ! -e /etc/sudoers.d/kyri-exec-verify \
  || { printf 'STOP: the verification grant exists. This ceremony does not authorise it. Report to the reviewer.\n' >&2; exit 1; }

sudo test -f /root/kyri-gen17-library-digests.txt

sudo bash /opt/schott-platform/provisioning/execution/install-g11-bc-e-helpers.sh --verify-source \
  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bc-e-helpers.sh --verify \
  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bc-e-helpers.sh --install \
  && sudo bash /opt/schott-platform/provisioning/execution/install-g11-bc-e-helpers.sh --verify-installed
```

**EXPECTED FINAL STATE:**

```
installed helpers.py                    78da8519…
installed kyri_exec_launcher.py         152038b1…
installed kyri_exec_podman.py           04205c53…
installed kyri_exec_transition_action.py d40f5121…
helper compatibility  compatible    blocking 0    supervision_ready true
library object count  81            both entrypoints and both grants unchanged
CINV-000002 923ff0d7… launch_authorized, seq 2, CRES 0
```

Stage 3 is **still not authorised** at that point.

## 13. Validation

```
FOCUSED
  transition-action     PASS  (48 cases, incl. the 8 narrowing proofs)
  podman-backend        PASS   launch-bridge       PASS
  handoff               PASS   worker-binding      PASS
  supervision           PASS   helper-coherence    PASS
  recovery-discovery    PASS   reconciliation      PASS
  g5 preflight          PASS
  generation 17 installer   PASS
  BC-E helper ceremony      PASS  (62 cases)
  reconcile entrypoint  PASS
  shellcheck            clean

LOCAL_FULL   PASS  137/137 steps
LOCAL_QUICK  PASS  112/112 steps
```

### 13.1 Two governed refusals had to be resolved, not suppressed

**The G5 preflight refused `helpers.py`** at `78da8519` as an undeclared
successor — exactly the refusal G11-BC-D §8.3 predicted when it probed this.
Resolved the governed way, by declaring: `6dd93606` joins the BASELINE list
because it is what Generation 15 installed and is therefore a legitimate
predecessor to move from, and `78da8519` joins the SUCCESSOR list because it is
the reviewed bytes to move to. No check was relaxed and nothing is derived from
git. The other two Generation-17 objects need no row: the drift loop walks
`tools/` only, and both are flattened library-root modules governed by their
ceremony's matrix.

**The reconcile-entrypoint suite failed** because `drop_privilege` gained a
backend primitive its recorder did not implement. That is the correct
consequence of widening a backend interface, and it was fixed by teaching the
recorder `chdir` and pinning the new order — so the reconciliation path now
proves the cwd closure too, which is the path the failure actually came from.
Every other suite driving an injected backend was checked; four more name
credential primitives but never reach the drop, and all four pass unchanged.

## 14. Production non-mutation

```
HOST_GENERATION 16                       nothing installed
CINV-000002     923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa
lifecycle       launch_authorized        INVOCATION_SEQ 2     CRES_COUNT 0
handoff         ownership and modes untouched — out/ still 0700 cschott:cschott
installed runtime bytes  unchanged       installed helper bytes  unchanged
Fabric 3fa32b83…  Trust 53605e4e…        sudoers unchanged
```

```
NO EXECUTE. NO RECOVER. NO DEPLOYMENT. NO CONTAINER. NO CRES.
NO FABRIC, TRUST, SUDOERS OR HANDOFF MUTATION.
```

Every ceremony run in this checkpoint used `--fixture` against a temporary tree,
or `--verify-source`, which reads no installed state.

## 15. Reviewer gates

Two things need explicit acceptance before the operator is asked to run
anything:

1. **The action-module digest moved from the value G11-BC-D presented.**
   `2bd86f3d…` → `d40f5121…`, because the drop now consumes the governed
   `policy.working_directory` instead of a duplicate constant (§2.1). Behaviour
   is identical; provenance is corrected.
2. **Generation 17 carries a third object** that G11-BC-D did not propose:
   `kyri_exec_launcher.py`, closing the last two latent inherited-cwd sites
   because the brief requires `CWD_SAME_CLASS_LATENT_WRONG=0` (§2.2).

The backstop widening itself was accepted at G11-BC-D and is unchanged; §7 is
the proof that it stayed narrow.
