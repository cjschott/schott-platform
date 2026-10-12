# ENG-0005 G11-BB-N — Generation 15 production installation, re-authorized

**Status: authorized for operator execution. Generation 15 is NOT installed by
this checkpoint.** The host is still Generation 14. Nothing in production was
mutated while producing this report: no privileged command was run and none
succeeded. `CINV-000001` byte-identical and `UNRESOLVED`, `CINV-000002` unspent,
no `CRES`, no sudoers change, no Fabric or Trust change, no helper installed.

```
GEN15_INSTALL_AUTHORISED    YES
HELPER_INSTALL_AUTHORISED   NO
PRODUCTION_INVOKE_AUTHORISED NO
```

Branch `arch/eng-0005-execution-transition`. Reconstructed against HEAD
`6734976` — working tree clean, 0 ahead / 0 behind
`origin/arch/eng-0005-execution-transition`. **This report adds no code**: it
commits one document, so the installer and ceremony bytes the operator runs are
`6734976`'s, unchanged by this checkpoint.

---

## 1. Why a new authorization, and what it supersedes

BB-K authorized an installation that refused twice at the console — both
refusals the installer's own, both before any journal existed, with nothing
published. BB-L root-caused them; BB-M fixed the two residuals that root-cause
exposed. **BB-K's authorization is superseded, not amended**: its operator block
is the one whose control flow BB-M's suite now keeps as a *negative control*, and
it must not be run.

This checkpoint re-authorizes the installation against the corrected installer
and the corrected, governed ceremony artefact. Everything below was
reconstructed from repository history, committed reports, live read-only
production measurement, and a local re-run of the proving suite — not carried
forward from any prior session's narrative.

## 2. Authorities

```
predecessor (installed)     Generation 14
GEN14_COMMIT                946be553ab9f25542590eb908c42ce14a81d6ec3
GEN15_SOURCE_AUTHORITY      ef4f7446200b668f8dcbf34d180c5102270f19f6

installer                   provisioning/execution/install-generation-15.sh
GEN15_INSTALLER_DIGEST      20d30dbc18a562b7fea34b3233fcc39da0378bf40a16cfce0296d4a78c025213

ceremony                    provisioning/execution/gen15-operator-ceremony.txt
GEN15_CEREMONY_DIGEST       0fc64100184dc51510ec90b159723da23f619d4188a039afd1d555784dc477b9
```

Both artefacts' worktree bytes are **identical to the pushed commit** — compared
against `git show origin/arch/eng-0005-execution-transition:<path>`, not against
the local index — so the operator runs the reviewed artefact and not a local
edit. `COMMIT` pinned inside the installer reads `ef4f744…`, and that commit is
an ancestor of HEAD.

## 3. The two BB-M fixes, verified from source rather than cited

### 3.1 Fail-closed-first publication — structural, not documentary

Read out of `install-generation-15.sh` directly:

```
MATRIX[0]   tools/capability/execution/helpers.py … group H     (line 189)
FAIL_CLOSED_FIRST="tools/capability/execution/helpers.py"        (line 879)

require_fail_closed_first()                                      (line 881)
  halts unless field 0 of MATRIX[0] == FAIL_CLOSED_FIRST
  halts unless field 6 of MATRIX[0] == "H"

invoked in --verify-source (1496), --verify (1530), --install (1575)
  -- in --install it runs BEFORE require_gates_closed and long before
     mkdir -p "${TRANSACTION_ROOT}", so a reordered matrix cannot open a
     transaction at all.

commit_targets()   for row in "${MATRIX[@]}"          forward order (line 1127)
rollback()         for (( index = ${#MATRIX[@]} - 1; index >= 0; index-- ))
                                                       reverse order (line 1221)
```

So "helpers.py publishes first" is a checked property of the artefact, and
"helpers.py is restored last" is the literal loop direction of the rollback, not
a comment above it. `GEN15_FAIL_CLOSED_FIRST_PUBLICATION = PASS`.

### 3.2 Fail-fast operator ceremony — read out of the committed artefact

`provisioning/execution/gen15-operator-ceremony.txt` carries `set -Eeuo pipefail`
on line 11, the two `/root/kyri-gen15-transaction` refusals on lines 17–20 —
**before** the first mention of the installer on line 26 — and chains
`--verify-source && --verify && --install && --verify-installed` as a single
`&&` expression. `--install` is unreachable unless both preceding gates returned
zero. `GEN15_OPERATOR_FAILFAST = PASS`.

### 3.3 Re-proved locally, not taken from BB-M

The focused suite was re-run in this session against the pushed source:

```
tests/test-capability-execution-generation15-installer.sh
  85 PASS   0 FAIL
```

The assertions that carry the two fixes, reproduced verbatim from that run:

```
PASS: the readiness authority is declared first in the matrix
PASS: an installer whose matrix no longer publishes the readiness authority first refuses
PASS: order: after publication #1 .. #7 the host is incompatible
PASS: order: publishing kyri-exec-launcher.py / verification.py / result_content.py /
             contract_outcome.py / recovery.py / cli.py first would leave execution OPEN,
             so it may not be first
PASS: order: a complete Generation 15 with predecessor helpers stays incompatible
PASS: order: exactly 3 helpers block, so supervision_ready is false until the helper ceremony runs
PASS: ceremony: the operator block sets -Eeuo pipefail
PASS: ceremony: the journal check precedes every installer invocation
PASS: ceremony: --verify refused -> --install invocation count is 0
PASS: ceremony: --verify-source refused -> --verify and --install invocation counts are both 0
PASS: ceremony control: the superseded unchained block does reach --install after a refusal
PASS: ceremony: an unexpected transaction journal stops the ceremony before any installer runs
PASS: recovery at all ten publication boundaries (30 assertions)
```

The control assertion is what gives the rest teeth: the superseded BB-K shape,
run against the same stub with the same refusal, **does** reach `--install`. The
new assertions pass because of the chaining, not by accident.

The suite is unprivileged and fixture-bound: every path the installer touches is
rebound under `--fixture`. It read no production state for judgement and wrote
none.

## 4. Production, measured read-only in this session

Every value below was measured directly, without privilege and without
`sudo`. None is carried from a prior transcript.

```
library flat object count   79                                                        as accepted
runtime aggregate           5bf50db23f086364e594f15c8390e9aff198b2825e681ee2aca2a40b7c133b84   unchanged
libexec aggregate           489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86   unchanged
Generation-15 residue       0 files matching *.kyri-gen15.*
```

**The seven Generation-15 targets — five at predecessor bytes, two absent:**

```
ed5b49ed03add16c8ba7a233d53a8c5528e5ba4d0fc23f53cdd41bb788bd2e73  …/execution/verification.py
ABSENT                                                            …/execution/result_content.py
ABSENT                                                            …/execution/contract_outcome.py
a93819d1400d981097eab6e2f31413ea90bc094d5dfd09265a368ccc0e59ab8f  …/execution/recovery.py
752951f7688af9ced5b326ad5be6d690c47e0ddee89d6b511f31296683e3d295  …/capability/cli.py
74b84015b18a6f38e88633e068cb9c4bdf2753804f3c336ca45aa9a577125874  …/execution/helpers.py
269258f3a407aaea5269312dda2a3b3c78fa50c2512c8f32475840e76c9fbb5d  kyri_exec_launcher.py
```

Each matches the Generation-14 column of the installer matrix exactly; both
CREATE pathnames are free. `HOST_GENERATION = 14`, evidenced by the installed
declaration `74b84015…125874` being Generation 14's.

**The predecessor helper set is still installed, and the pinned entrypoints have
not moved:**

```
6d06695f433570070b15fc4a990b53dcbaa227001586d4062e254a08367723fd  /usr/libexec/kyri-exec-worker.py
7703231318f7a872f80abc0b033c2462c24ec63bd8669773d6643634af1d296a  …/kyri_exec_transition_action.py
4886d5b323c9dfdf46939c83424b087bb052f3fc90b8bd4a5ba2b4346bff9e9c  …/kyri_exec_quota.py
0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1  /usr/libexec/kyri-exec-transition
2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77  /usr/libexec/kyri-exec-reconcile
```

**Readiness, asked of the installed rule rather than inferred:**

```
helpers.compatibility()   verdict compatible, 8 declared, 0 blocking
```

That is the expected Generation-14 answer, and it is the value that must
**change to `incompatible`** the moment Generation 15's first object lands.

**Execution records and chain state:**

```
CINV count                 1
CRES count                 0
CINV-000001                1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   UNRESOLVED
CINV-000002                unspent (no record exists)
fabric                     7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96   unchanged
trust                      53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   unchanged
```

`CINV-000001` is byte-identical to its immutable digest. It is not resumed, not
re-executed, not mutated, and no synthetic `CRES` exists for it.

**Fabric freshness is deliberately not asserted.** The chain may be aged or
expired; that blocks nothing in this checkpoint. Renewal happens after the
runtime and helper surfaces are installed and accepted, not before.

**Non-mutation, checked rather than assumed.** Reading the installed rule was
done with `PYTHONDONTWRITEBYTECODE=1`. The four `__pycache__` directories under
the library root are root-owned and all predate this session — newest
`2026-09-04 18:18`, against a session clock of `2026-09-05 20:00`. Nothing was
created. `PRODUCTION_MUTATION = NONE`.

## 5. What I can and cannot see, stated exactly

BB-M recorded three facts it could not verify. This session narrowed that set
rather than repeating the claim, and the distinction matters because the
operator should spend privilege on what actually needs it.

**Established without privilege** (`/etc/sudoers.d` is `0755`, so its *metadata*
is readable even though the grant *contents*, at `0440 root:root`, are not):

```
kyri-exec-launch root:root 440 482
kyri-exec-reconcile root:root 440 487
README root:root 440 1068

sudoers metadata aggregate  f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9
                            -- reproduces the accepted BB-K/BB-L value exactly
/etc/sudoers.d/kyri-exec-verify   not present
undeclared kyri-* grants          0
```

**Still unverifiable from here, and therefore the operator's first job:**

1. `/root/kyri-gen15-transaction` — `/root` is `Permission denied` to the
   coordinator. No code path could have created it (BB-L §1 proved the BB-K
   refusal fired three lines before any `mkdir`), but *could not have* is not
   *is not*, and this is the one condition that must stop the ceremony.
2. **Grant contents** — the `sha256:` pin inside each grant. Metadata proves the
   files are the right size, owner and mode; it does not prove what they
   authorise. Only reading them does.
3. `visudo -c` — a parse verdict cannot be obtained unprivileged.

`sudo` is password-gated non-interactively on this host (`sudo -n true` →
*"a password is required"*), so no privileged read was attempted and none
succeeded. **Do not treat any of the three as settled by this report.**

## 6. Operator read-only precheck — the FIRST privileged action

Run this **before** the installation ceremony. Every command reads; nothing is
written, created, or removed. **If any line prints `STOP`, stop there** and
return the output — do not proceed to §7, and do not delete anything.

```bash
set -Eeuo pipefail
cd /opt/schott-platform

echo "=== P1. no Generation-15 transaction exists ==="
if sudo test -e /root/kyri-gen15-transaction; then
  echo "STOP: /root/kyri-gen15-transaction exists. Do NOT delete it."
  sudo ls -la /root/kyri-gen15-transaction
  sudo cat /root/kyri-gen15-transaction/journal 2>/dev/null || true
  exit 1
fi
echo "OK  transaction root ABSENT"
if sudo test -e /root/kyri-gen15-transaction/journal; then
  echo "STOP: a Generation-15 journal exists. Do NOT delete it."; exit 1
fi
echo "OK  transaction journal ABSENT"

echo "=== P2. the Generation-14 evidence the installer verifies against ==="
sudo test -f /root/kyri-gen14-library-digests.txt || { echo "STOP: gen14 library evidence missing"; exit 1; }
sudo test -f /root/kyri-gen14-helper-digests.txt  || { echo "STOP: gen14 helper evidence missing";  exit 1; }
echo "OK  both Generation-14 evidence files present"

echo "=== P3. full /etc/sudoers.d inventory ==="
sudo ls -la /etc/sudoers.d/
sudo find /etc/sudoers.d -maxdepth 1 -type f -printf '%f %u:%g %m %s\n' | sort
echo "-- metadata aggregate (expect f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9) --"
sudo find /etc/sudoers.d -maxdepth 1 -type f -printf '%f %u:%g %m %s\n' | sort | sha256sum

echo "=== P4. the verification grant must be ABSENT ==="
if sudo test -e /etc/sudoers.d/kyri-exec-verify; then
  echo "STOP: the verification grant exists. Nothing authorised it."; exit 1
fi
echo "OK  /etc/sudoers.d/kyri-exec-verify ABSENT"

echo "=== P5. no undeclared Kyri grant ==="
undeclared="$(sudo find /etc/sudoers.d -maxdepth 1 -type f -name 'kyri-*' \
                ! -name kyri-exec-launch ! -name kyri-exec-reconcile)"
if [ -n "${undeclared}" ]; then
  echo "STOP: undeclared Kyri grant(s): ${undeclared}"; exit 1
fi
echo "OK  only kyri-exec-launch and kyri-exec-reconcile exist"

echo "=== P6. both grants present, and each pins the entrypoint THIS host carries ==="
sudo cat /etc/sudoers.d/kyri-exec-launch
sudo cat /etc/sudoers.d/kyri-exec-reconcile
for pair in "kyri-exec-launch:/usr/libexec/kyri-exec-transition" \
            "kyri-exec-reconcile:/usr/libexec/kyri-exec-reconcile"; do
  grant="/etc/sudoers.d/${pair%%:*}"; entrypoint="${pair##*:}"
  sudo test -e "${grant}" || { echo "STOP: ${grant} is missing"; exit 1; }
  # Both substitutions tolerate failure explicitly: under `set -Eeuo pipefail` a
  # grep that matches nothing would otherwise end the precheck SILENTLY, with
  # the refusal below never printed. That is the exact defect BB-L §2 recorded.
  pinned="$(sudo grep -oE 'sha256:[0-9a-f]{64}' "${grant}" | head -1 || true)"; pinned="${pinned#sha256:}"
  installed="$(sudo sha256sum "${entrypoint}" | cut -d' ' -f1 || true)"
  if [ -z "${pinned}" ] || [ "${pinned}" != "${installed}" ]; then
    echo "STOP: ${grant} pins '${pinned:-nothing}' but ${entrypoint} is ${installed}"; exit 1
  fi
  echo "OK  ${grant} pins the installed ${entrypoint} (${installed})"
  sudo grep -q -- "${entrypoint}" "${grant}" \
    || { echo "STOP: ${grant} does not name ${entrypoint} as its command"; exit 1; }
  echo "OK  ${grant} pins the command path ${entrypoint}"
done

echo "=== P7. the pinned entrypoint bytes are the accepted ones ==="
sudo sha256sum /usr/libexec/kyri-exec-transition /usr/libexec/kyri-exec-reconcile
echo "-- expect 0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1  …kyri-exec-transition"
echo "-- expect 2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77  …kyri-exec-reconcile"

echo "=== P8. the sudo policy itself parses ==="
sudo visudo -c

echo "=== PRECHECK COMPLETE ==="
```

### Required precheck results

| # | expectation |
| --- | --- |
| P1 | `/root/kyri-gen15-transaction` and its journal both **ABSENT** |
| P2 | both `/root/kyri-gen14-*-digests.txt` present |
| P3 | exactly `kyri-exec-launch`, `kyri-exec-reconcile`, `README`; aggregate `f837d592…495da1a9` |
| P4 | `kyri-exec-verify` **ABSENT** |
| P5 | no undeclared `kyri-*` grant |
| P6 | each grant pins the installed entrypoint's digest **and** names its command path |
| P7 | `0d9c8d8c…ede51a1` and `2878fff0…db75798f77`, unchanged |
| P8 | `visudo -c` reports the policy parses |

**If any result differs from the table: STOP.** Do not run §7. Return the
complete output for a reviewer ruling.

### 6.1 The precheck's own control flow, dry-run rather than trusted

This block is the first privileged action of the authorization, so it was held
to the standard BB-M set for the ceremony rather than being reasoned about in
prose. `shellcheck` is clean, and it was executed against a stub `sudo` that
rebinds `/root` and `/etc/sudoers.d` into a fixture — the real `/usr/libexec`
entrypoints are world-readable, so the digest-pin comparison runs against the
**actual production bytes**:

```
PASS  clean host: the precheck completes, 9 OK lines
PASS  transaction-root  -> STOP: /root/kyri-gen15-transaction exists. Do NOT delete it.
PASS  journal           -> STOP: /root/kyri-gen15-transaction exists. Do NOT delete it.
PASS  verify-grant      -> STOP: the verification grant exists. Nothing authorised it.
PASS  undeclared-grant  -> STOP: undeclared Kyri grant(s): …/kyri-exec-something
PASS  pin-mismatch      -> STOP: …kyri-exec-launch pins 'aaaa…' but …kyri-exec-transition is 0d9c8d8c…
PASS  missing-pin       -> STOP: …kyri-exec-launch pins 'nothing' but …kyri-exec-transition is 0d9c8d8c…
PASS  missing-command   -> STOP: …kyri-exec-launch does not name …kyri-exec-transition as its command
PASS  gen14-evidence    -> STOP: gen14 helper evidence missing
PASS  visudo -c refused -> the precheck exits non-zero before P9
```

The harness is a throwaway and is **not** committed; it proves the block that
is. It found one real defect, which is fixed above: `pinned="$(sudo grep -oE …)"`
without `|| true` would, on a grant that pins nothing, have ended the precheck
**silently** under `set -Eeuo pipefail` — the refusal below it never printed.
That is the same errexit trap BB-L §2 recorded, and the `missing-pin` case now
proves the message reaches the console.

## 7. The installation ceremony — extracted, not retyped

Reproduced **verbatim** from `provisioning/execution/gen15-operator-ceremony.txt`
at digest `0fc64100…4dc477b9`, the artefact BB-M's suite executes against a stub
installer. It is reference text: the operator pastes it into a root-capable
shell so every command and every refusal is visible on the console.

Paste it as a single block. Its `set -Eeuo pipefail` and `&&` chaining are the
fix — running the four stages as separate commands re-creates the BB-K defect
that the suite keeps as a negative control.

```bash
#!/usr/bin/env bash
# The Generation-15 operator ceremony, exactly as it is to be typed.
#
# This file is reference text, not a script to run: the operator pastes it into
# a root-capable shell so every command and every refusal is visible on the
# console. It lives here rather than only in a report so the test suite can
# execute it against a stub installer and prove the control flow, instead of
# trusting that a fenced block in prose does what its prose says.
#
# The property under test: no later stage can run after an earlier one refused.
set -Eeuo pipefail
cd /opt/schott-platform

# An unexpected transaction is the one condition that must stop everything
# before any installer runs. It would mean a previous ceremony did not finish,
# and the correct response is inspection, not cleanup.
sudo test ! -e /root/kyri-gen15-transaction/journal \
  || { printf 'STOP: a Generation-15 transaction journal exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }
sudo test ! -e /root/kyri-gen15-transaction \
  || { printf 'STOP: Generation-15 transaction residue exists. Do not delete it. Report to the reviewer.\n' >&2; exit 1; }

# The predecessor evidence the installer verifies against.
sudo test -f /root/kyri-gen14-library-digests.txt
sudo test -f /root/kyri-gen14-helper-digests.txt

sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify-source \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --install \
  && sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify-installed
```

**This block installs Generation 15 and nothing else.** It invokes no helper
ceremony, changes no `/usr/libexec` object, writes no sudoers file, touches no
Fabric or Trust record, and invokes or recovers no capability. There is no
helper installation in this block and none may be added to it.

## 8. Expected post-install state — stated before execution

```
HOST_GENERATION                15
GEN15_VERIFY_INSTALLED         PASS
governed objects               80          flat library 81
                               (+1 separately helper-published module, kyri_exec_reconcile.py)
GEN15_REPLACE 5   GEN15_CREATE 2   GEN15_REMOVE 0   GEN15_CARRYOVER 73
transaction journal            state=COMMITTED, retained under /root/kyri-gen15-transaction
Generation-15 evidence         /root/kyri-gen15-{library,helper}-digests.txt written
Generation-14 evidence         preserved, not overwritten
runtime imports                PASS
verification surface           installed and coherent; imports as a whole
verify entrypoint              STILL UNAUTHORISED
verify sudoers grant           ABSENT
launch/reconcile sudoers       UNCHANGED
launch/reconcile entrypoints   UNCHANGED bytes
predecessor helpers            STILL INSTALLED, all three at predecessor bytes
helper compatibility           INCOMPATIBLE, 8 declared, 3 blocking
supervision_ready              FALSE
```

The seven targets must read exactly:

```
7a792aaf3c59ed0bb4bd32cb55267e6fc26dfae06f5da1b8b36efff9e1efa952  …/execution/verification.py
b1c5a89fd5b8b2a368bb8908394052c18475a36adae1b4d88d2f65cb9bcd0bba  …/execution/result_content.py    CREATE
139b77b7065f88d05ed472bbf9de0c2665a74b29d21f132445848b0ee4dd16a5  …/execution/contract_outcome.py  CREATE
f44ada7f3272d6f231fa05a99d30f04ec820385e0c4c92a1d31f680dc0222a03  …/execution/recovery.py
7b4fac3e8543829b5e5fa7e8041d29be8bb53083c9b87b09df5cb7beb254c6b1  …/capability/cli.py
6dd936064f1c6d3813cbdbd9fb175b03902b18623493638cded55e3e930b8b07  …/execution/helpers.py
78c6de9093a535618b6fee54cd90c8eab388bc7ba6e4bd39d42de7f2e019bc83  kyri_exec_launcher.py
```

**The incompatibility is required, not tolerated.** Generation 15 moves
`helpers.py` — the rule that decides whether installed helper bytes are current
— to declare the **corrected** digests, and publishes it **first**. Execution
closes on the first rename and stays closed. The predecessor helpers are still
installed when the installer finishes, so exactly three read `stale`.

**Two stop conditions, both meaning something other than this ceremony changed
the host:**

- If helper compatibility reports **`compatible`** immediately after Generation
  15 while the predecessor helper bytes are still installed — **STOP.** That
  contradicts case B of the proven compatibility matrix.
- If **`supervision_ready` is true** — **STOP.**

The three blocking helpers must be exactly:

```
/usr/libexec/kyri-exec-worker.py
/usr/lib/kyri/python/kyri_exec_transition_action.py
/usr/lib/kyri/python/kyri_exec_quota.py
```

A different count means the two ceremonies disagree about the delta between
them. **STOP** on any other number.

## 9. Post-install read-only verification block

Run **only after** the ceremony in §7 returns successfully. Every command reads.

```bash
set -Eeuo pipefail
cd /opt/schott-platform

echo "=== 1. the installer's own verdict ==="
sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify-installed

echo "=== 2. the transaction journal is COMMITTED, and the evidence was written ==="
sudo sed -n 's/^state=/journal state: /p;s/^transaction=/transaction: /p;s/^commit=/commit: /p' \
     /root/kyri-gen15-transaction/journal
sudo ls -la /root/kyri-gen15-library-digests.txt /root/kyri-gen15-helper-digests.txt
sudo ls -la /root/kyri-gen14-library-digests.txt /root/kyri-gen14-helper-digests.txt

echo "=== 3. no transaction residue in the library root ==="
sudo find /usr/lib/kyri/python -name '*.kyri-gen15.*' | wc -l

echo "=== 4. object count and the seven targets ==="
sudo find /usr/lib/kyri/python -type f -name '*.py' -not -path '*__pycache__*' | wc -l
sudo sha256sum \
  /usr/lib/kyri/python/tools/capability/execution/verification.py \
  /usr/lib/kyri/python/tools/capability/execution/result_content.py \
  /usr/lib/kyri/python/tools/capability/execution/contract_outcome.py \
  /usr/lib/kyri/python/tools/capability/execution/recovery.py \
  /usr/lib/kyri/python/tools/capability/cli.py \
  /usr/lib/kyri/python/tools/capability/execution/helpers.py \
  /usr/lib/kyri/python/kyri_exec_launcher.py

echo "=== 5. the runtime and the repaired verification surface import ==="
cd /usr/lib/kyri/python && sudo env PYTHONDONTWRITEBYTECODE=1 python3 -c \
  'from tools.capability import cli
from tools.capability.execution import recovery, helpers, verification, result_content, contract_outcome
print("runtime imports OK")'
cd /opt/schott-platform

echo "=== 6. helper compatibility MUST be incompatible, with exactly three stale ==="
sudo env PYTHONDONTWRITEBYTECODE=1 python3 -c '
import sys; sys.path.insert(0, "/usr/lib/kyri/python")
from tools.capability.execution import helpers
c = helpers.compatibility()
print("verdict:", c.verdict, "| declared:", len(helpers.REQUIRED_HELPERS),
      "| blocking:", len(c.blocking))
for h in c.blocking: print("   ", h.state, h.path)'

echo "=== 7. the three helper targets are NOT yet installed ==="
sudo sha256sum /usr/libexec/kyri-exec-worker.py \
               /usr/lib/kyri/python/kyri_exec_transition_action.py \
               /usr/lib/kyri/python/kyri_exec_quota.py

echo "=== 8. the pinned entrypoints and both grants are untouched ==="
sudo sha256sum /usr/libexec/kyri-exec-transition /usr/libexec/kyri-exec-reconcile
sudo ls -la /etc/sudoers.d/
sudo find /etc/sudoers.d -maxdepth 1 -type f -printf '%f %u:%g %m %s\n' | sort | sha256sum
sudo test -e /etc/sudoers.d/kyri-exec-verify \
  && echo "STOP: verify grant present" || echo "verify grant ABSENT"
sudo visudo -c

echo "=== 9. no invocation, no result, no container ==="
find /data/kyri/capability-runtime/capability-invocations -mindepth 1 | wc -l
find /data/kyri/capability-runtime/capability-results     -mindepth 1 | wc -l
sha256sum /data/kyri/capability-runtime/capability-invocations/CINV-000001.yaml
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'

echo "=== 10. Fabric and Trust untouched ==="
find /var/lib/kyri/fabric -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
find /var/lib/kyri/trust  -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
```

### Required results

| # | expectation |
| --- | --- |
| 1 | `--verify-installed` passes. It independently re-checks the seven targets against `ef4f744`, every carried-over object against the accepted baseline, group coherence, the excluded privileged surface, the gates, the journal state and both evidence pairs — so *"all carryover exact"*, *"no unknown bytes"* and *"CREATE objects exact"* are its verdict, not a separate command |
| 2 | `journal state: COMMITTED`; both Gen-15 evidence files present; **both Gen-14 evidence files still present** |
| 3 | `0` residue files |
| 4 | **81** objects; the seven digests equal §8's target list exactly |
| 5 | `runtime imports OK`, including all three group-V modules |
| 6 | **`incompatible`**, 8 declared, **3 blocking**, each `stale`, and exactly the three named in §8 |
| 7 | still `6d06695f…`, `7703231318f7…`, `4886d5b3…` — the predecessor helper bytes, unmoved |
| 8 | `0d9c8d8c…ede51a1` and `2878fff0…db75798f77` unchanged; aggregate still `f837d592…495da1a9`; **verify grant ABSENT**; `visudo -c` passes |
| 9 | CINV count **1**, CRES count **0**, `CINV-000001` still `1dcef40d…d6cfaaa`, **no `kyri-CINV-*` container** |
| 10 | Fabric `7c53efcd…aa6c8e96`, Trust `53605e4e…7828b63f` |

**Fabric freshness is not part of this proof.** The chain may be aged or expired
by then; that is expected and blocks nothing here.

## 10. Failure boundary

If the installer fails, or reports an unresolved transaction:

- **STOP.** Do not install helpers.
- Do **not** manually copy runtime files, delete CREATE targets, remove the
  journal, or restore predecessor bytes by hand.
- Use only the governed recovery, and only after a reviewer has inspected the
  journal and state: `sudo bash …/install-generation-15.sh --recover`.
- Return the complete failure output, including the journal, for a ruling.

The preparation exercised interruption at all ten publication boundaries, and
BB-M re-ran every one of them under the corrected order. Each leaves either the
exact Generation-14 library or every matrix row at its Generation-15 bytes,
never a mixture — and, now, never an *executable* mixture: execution reopens
only against the complete Generation-14 runtime.

## 11. After success — stop

```
HELPER_INSTALL_AUTHORISED = NO
```

**Do not proceed into the helper ceremony.** The intentionally incompatible
state is a reviewer checkpoint, and it is the whole point of the proven
`GEN15_THEN_HELPERS` order. `install-g11-bb-helpers.sh` exists and is proven, and
it will refuse to run before Generation 15 is installed — but it must not be run
after it either, until a separate explicit authorization.

Also still prohibited: renewing Fabric, invoking, authorising a launch,
executing, recovering or mutating `CINV-000001`, spending `CINV-000002`, and
modifying sudoers, Trust or Fabric.

Return the complete output of §6, §7 and §9 for acceptance.

## 12. Validation

```
Gen-15 focused suite   PASS   85 assertions, 0 failures   re-run in this session at 6734976
installer bytes        identical to origin/arch/eng-0005-execution-transition
ceremony bytes         identical to origin/arch/eng-0005-execution-transition
source authority       ef4f744 is an ancestor of HEAD
working tree           clean; HEAD == pushed branch head; 0 ahead, 0 behind
production             read-only only; no privileged command run or succeeded
```

## 13. Summary

```
RECONSTRUCTION                        PASS
HOST_GENERATION                       14
GEN15_SOURCE_AUTHORITY                ef4f7446200b668f8dcbf34d180c5102270f19f6
GEN15_FIRST_PUBLISHED_OBJECT          tools/capability/execution/helpers.py
GEN15_FAIL_CLOSED_FIRST_PUBLICATION   PASS
GEN15_OPERATOR_FAILFAST               PASS
GEN15_INSTALL_AUTHORISED              YES
HELPER_INSTALL_AUTHORISED             NO
CINV_000001_SHA256                    1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV_000001_FINAL_CLASSIFICATION      UNRESOLVED
CINV_NEXT                             CINV-000002
CINV_000002_SPENT                     NO
CRES_COUNT                            0
VERIFY_GRANT_EXPECTED                 ABSENT
SUDOERS_CHANGE_REQUIRED               NO
PRODUCTION_MUTATION                   NONE
PRODUCTION_INVOKE_AUTHORISED          NO
```

**Generation 15 is not installed.** This report authorizes an operator to
install it; it does not claim it was.

## 14. Next

Operator runs the §6 precheck, then the §7 ceremony, then the §9 verification,
and returns the complete output. Reviewer acceptance of the intentionally
incompatible intermediate state comes next, and only then the helper ceremony —
followed, separately, by a fresh Fabric chain (`CADV` → `CINST` → `CROUTE` →
`CSEL`) before `CINV-000002`.
