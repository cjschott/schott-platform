# ENG-0005 G11-BB-K — Generation 15 production install, authorization

**Status: prepared for operator execution. Generation 15 is NOT installed.**
The host is still Generation 14. Nothing in production was mutated by this
checkpoint. `CINV-000001` byte-identical, `CINV-000002` unspent, no `CRES`, no
sudoers change, no Fabric or Trust change.

Branch `arch/eng-0005-execution-transition`, HEAD `665c7bb`.

---

## 1. Authorities

```
predecessor (installed)   Generation 14
GEN14_COMMIT              946be553ab9f25542590eb908c42ce14a81d6ec3
GEN15_SOURCE_AUTHORITY    ef4f7446200b668f8dcbf34d180c5102270f19f6

installer                 provisioning/execution/install-generation-15.sh
GEN15_INSTALLER_DIGEST    dbf8ceac29acbd2c407683f49531e77a246b1654f6d7a5bc5b3f02abe8f9fac4
```

Repository verified independently: branch `arch/eng-0005-execution-transition`,
HEAD `665c7bb`, working tree clean, 0 ahead and 0 behind `origin`. The
installer's worktree bytes are **identical to the pushed commit**, so the
operator runs the reviewed artefact and not a local edit.

## 2. The matrix — 5 REPLACE, 2 CREATE, 0 REMOVE

Every row re-verified twice: source bytes against the authority commit, and
predecessor state against the live host.

| op | target | predecessor (live) | target (authority) | group |
| --- | --- | --- | --- | --- |
| REPLACE | `…/execution/verification.py` | `ed5b49ed…88bd2e73` | `7a792aaf…9e1efa952` | V |
| CREATE | `…/execution/result_content.py` | **absent** | `b1c5a89f…9bcd0bba` | V |
| CREATE | `…/execution/contract_outcome.py` | **absent** | `139b77b7…e4dd16a5` | V |
| REPLACE | `…/execution/recovery.py` | `a93819d1…0e59ab8f` | `f44ada7f…c0222a03` | R |
| REPLACE | `…/capability/cli.py` | `752951f7…3e3d295` | `7b4fac3e…54c6b1` | R |
| REPLACE | `…/execution/helpers.py` | `74b84015…125874` | `6dd93606…930b8b07` | H |
| REPLACE | `kyri_exec_launcher.py` | `269258f3…6c9fbb5d` | `78c6de90…93a5` | H |

```
GEN15_REPLACE 5   GEN15_CREATE 2   GEN15_REMOVE 0   GEN15_CARRYOVER 73
GEN15_OBJECTS 80 governed (81 flat, +1 helper-ceremony-published module)
```

## 3. Preinstall verification

```
GEN15_PREINSTALL_VERIFY    PASS
GEN15_PREDECESSOR_VERIFY   PASS
GEN15_UNKNOWN_BYTES        PASS
GEN15_CREATE_COLLISIONS    PASS   both CREATE targets absent
```

`--verify-source` passed against the reviewed bytes and **wrote nothing**:
library-root and `/usr/libexec` manifests identical before and after, no
bytecode created.

**The predecessor was verified independently**, object by object, because the
installer's own `--verify` needs root-owned evidence under `/root` that the
coordinator cannot read. All **79** installed objects were compared against the
accepted Generation-14 state — reconstructed from `946be55`, with
`verification.py` from `16f285e`, which is the one object whose accepted
installed bytes are not its own source authority's. **Zero unknown bytes.**

### 3.1 Before-manifest

```
library root aggregate   3dd951f569d7f5f050de5154c641ac1327834580a142fb3eb0a9707d842f27fd
libexec aggregate        489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86
sudoers aggregate        f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9
installed object count   79 flat
installed declaration    74b84015b18a6f38e88633e068cb9c4bdf2753804f3c336ca45aa9a577125874
helper compatibility     compatible, 8 declared, 0 blocking
```

Each path Generation 15 may touch, before:

```
file root:root 0444  13771 b  ed5b49ed…  …/execution/verification.py
ABSENT                          …/execution/result_content.py
ABSENT                          …/execution/contract_outcome.py
file root:root 0444   9259 b  a93819d1…  …/execution/recovery.py
file root:root 0444  39811 b  752951f7…  …/capability/cli.py
file root:root 0444   9476 b  74b84015…  …/execution/helpers.py
file root:root 0444  11508 b  269258f3…  kyri_exec_launcher.py
dir  root:root 0755  /usr/lib/kyri/python
dir  root:root 0755  /usr/lib/kyri/python/tools/capability/execution
```

## 4. Expected post-install state — stated before execution

```
HOST_GENERATION                15
GEN15_VERIFY_INSTALLED         PASS
GEN15_OBJECTS                  80 governed (81 flat)
GEN15_REPLACE 5   GEN15_CREATE 2   GEN15_REMOVE 0
runtime imports                PASS
verification surface           installed and coherent; imports as a whole
verify entrypoint              STILL UNAUTHORISED
verify sudoers grant           ABSENT
launch/reconcile sudoers       UNCHANGED
launch/reconcile entrypoints   UNCHANGED
predecessor helpers            STILL INSTALLED
helper compatibility           INCOMPATIBLE
supervision_ready              FALSE
```

**The incompatibility is the point, not a fault.** Generation 15 moves
`helpers.py`, which is the rule that decides whether installed helper bytes are
current, and it moves it to declare the **corrected** helper digests. The
predecessor helpers are still installed when the installer finishes, so the
three of them read `stale` and the verdict is `incompatible`. That proves the
runtime moved first and that execution stays fail-closed until the separate
helper ceremony completes.

**If helper compatibility reports `compatible` immediately after Generation 15
while the predecessor helper bytes are still installed — STOP.** That would
contradict case B of the proven matrix and means something other than this
ceremony changed the helper surface.

## 5. Operator block — Generation 15 install only

Run as root, on `schai`, from the pinned checkout.

```bash
cd /opt/schott-platform

# 0. The installer requires root-owned Generation-14 evidence the coordinator
#    cannot read. Confirm both exist before starting.
sudo test -f /root/kyri-gen14-library-digests.txt \
  && sudo test -f /root/kyri-gen14-helper-digests.txt \
  && echo "gen14 evidence present" || echo "STOP: gen14 evidence missing"

# 1. Reviewed bytes only. Reads no installed state, writes nothing.
sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh \
     --verify-source

# 2. Is this host a Generation-14 host ready for it? Read-only.
sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh \
     --verify

# 3. The transaction. ONLY run this if step 2 passed.
sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh \
     --install
```

**This block installs Generation 15 and nothing else.** It invokes no helper
ceremony, changes no `/usr/libexec` object, writes no sudoers file, touches no
Fabric or Trust record, and invokes or recovers no capability.

## 6. Post-install verification block — read-only

Run **only after** the installer returns successfully. Every command reads.

```bash
cd /opt/schott-platform

echo "--- 1. the installer's own verdict ---"
sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh \
     --verify-installed

echo "--- 2. object count and the seven targets ---"
sudo find /usr/lib/kyri/python -type f -name '*.py' -not -path '*__pycache__*' | wc -l
sudo sha256sum \
  /usr/lib/kyri/python/tools/capability/execution/verification.py \
  /usr/lib/kyri/python/tools/capability/execution/result_content.py \
  /usr/lib/kyri/python/tools/capability/execution/contract_outcome.py \
  /usr/lib/kyri/python/tools/capability/execution/recovery.py \
  /usr/lib/kyri/python/tools/capability/cli.py \
  /usr/lib/kyri/python/tools/capability/execution/helpers.py \
  /usr/lib/kyri/python/kyri_exec_launcher.py

echo "--- 3. the runtime and the repaired verification surface import ---"
cd /usr/lib/kyri/python && sudo env PYTHONDONTWRITEBYTECODE=1 python3 -c \
  'from tools.capability import cli
from tools.capability.execution import recovery, helpers, verification, result_content, contract_outcome
print("runtime imports OK")'
cd /opt/schott-platform

echo "--- 4. helper compatibility MUST be incompatible, with three stale ---"
sudo env PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys; sys.path.insert(0, "/usr/lib/kyri/python")
from tools.capability.execution import helpers
c = helpers.compatibility()
print("verdict:", c.verdict, "| declared:", len(helpers.REQUIRED_HELPERS),
      "| blocking:", len(c.blocking))
for h in c.blocking: print("   ", h.state, h.path)'

echo "--- 5. the three helper targets are NOT yet installed ---"
sudo sha256sum /usr/libexec/kyri-exec-worker.py \
               /usr/lib/kyri/python/kyri_exec_transition_action.py \
               /usr/lib/kyri/python/kyri_exec_quota.py

echo "--- 6. the pinned entrypoints and both grants are untouched ---"
sudo sha256sum /usr/libexec/kyri-exec-transition /usr/libexec/kyri-exec-reconcile
sudo ls -la /etc/sudoers.d/
sudo find /etc/sudoers.d -maxdepth 1 -type f -printf '%f %u:%g %m %s\n' | sort | sha256sum
test -e /etc/sudoers.d/kyri-exec-verify && echo "STOP: verify grant present" \
  || echo "verify grant ABSENT"

echo "--- 7. no invocation, no result, no container ---"
find /data/kyri/capability-runtime/capability-invocations -mindepth 1 | wc -l
find /data/kyri/capability-runtime/capability-results     -mindepth 1 | wc -l
sha256sum /data/kyri/capability-runtime/capability-invocations/CINV-000001.yaml
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'

echo "--- 8. Fabric and Trust untouched ---"
find /var/lib/kyri/fabric -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
find /var/lib/kyri/trust  -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
```

### Required results

| # | expectation |
| --- | --- |
| 1 | `--verify-installed` passes |
| 2 | **81** objects; the seven digests equal the §2 target column |
| 3 | `runtime imports OK` — including all three group-V modules |
| 4 | **`incompatible`**, 8 declared, **3 blocking**, each `stale`: worker.py, transition_action.py, quota.py |
| 5 | the three still at `6d06695f…`, `7703231318f7…`, `4886d5b3…` |
| 6 | `0d9c8d8c…` and `2878fff0…` unchanged; sudoers aggregate still `f837d592…495da1a9`; verify grant ABSENT |
| 7 | CINV count 1, CRES count 0, `CINV-000001` still `1dcef40d…d6cfaaa`, no `kyri-CINV-*` container |
| 8 | Fabric `7c53efcd…aa6c8e96`, Trust `53605e4e…7828b63f` |

**Fabric freshness is not part of this proof.** The chain may be aging or
expired by then; that is expected and blocks nothing here.

## 7. Failure boundary

If the installer fails or reports an unresolved transaction:

- **STOP.** Do not install helpers.
- Do **not** manually copy runtime files, delete CREATE targets, or restore
  predecessor bytes by hand.
- Use only the governed recovery already proven by the preparation matrix:
  `sudo bash …/install-generation-15.sh --recover`.
- Return the complete failure output, including the journal state, for a
  reviewer ruling.

The preparation exercised interruption at all ten publication boundaries; each
left either the exact Generation-14 library or every matrix row at its
Generation-15 bytes, never a mixture.

## 8. After success — stop

```
HELPER_INSTALL_AUTHORISED = NO
```

**Do not proceed into the helper ceremony.** The intentionally incompatible
state is a reviewer checkpoint. `install-g11-bb-helpers.sh` exists and is
proven, and it will refuse to run before Generation 15 is installed — but it
must not be run after it either, until a separate explicit authorization.

Also still prohibited: renewing Fabric, invoking, authorising a launch,
executing, recovering `CINV-000001`, and modifying sudoers, Trust or Fabric.

## 9. One correction made during this checkpoint

Both ceremony artefacts were ported from their predecessors and both had kept
the predecessor's header. The Generation-15 installer described the G11-AS/AT
supervised execution path and claimed "twenty-one objects"; the helper ceremony
claimed ten. No logic depended on either, but an operator reads these
immediately before running them as root, so a header describing a different
ceremony is a defect in the artefact.

Both now describe what they actually deploy. The Generation-15 header states
plainly that it leaves the host execution-not-ready and why. No matrix, digest
or source authority changed; the installer's own digest did, and §1 records the
current one.

## 10. Validation

```
LOCAL_FULL          PASS   133/133 at 665c7bb
GITHUB_CI           PASS   6/6 at 665c7bb
CLEAN_CLONE_VERIFY  PASS   full clone of the pushed commit, Gen-15 suite green
working tree        clean; HEAD == pushed branch head
```

## 11. Current production state

```
HOST_GENERATION      14
runtime declaration  74b84015…125874 (Generation 14)
helper compatibility compatible, 8 declared, 0 blocking
libexec              489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86
sudoers              f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9
verify grant         ABSENT
CINV-000001          1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV count           1        CRES count 0        CINV-000002 unspent
Fabric               7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96
```

`PRODUCTION_MUTATION = NONE`. `PRODUCTION_INVOKE_AUTHORISED = NO`.

**Generation 15 is not installed.** This report authorizes an operator to
install it; it does not claim it was.
