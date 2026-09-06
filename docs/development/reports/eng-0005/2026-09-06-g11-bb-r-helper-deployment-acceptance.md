# ENG-0005 G11-BB-R — helper deployment acceptance

**Status: the helper deployment is materially correct and accepted. Two
verifier/fixture consequences of it landing were found and fixed, and one
misleading line the ceremony printed is a real defect that is recorded, not
relied on.** Production was not mutated by this checkpoint.

```
HELPER_TRANSACTION           COMMITTED   (operator-reported; root-owned, see §1.1)
HELPER_PUBLICATION_COMPLETE  YES
HELPER_TARGETS               3/3 at reviewed target digests
HELPER_COHERENCE             COMPLETE
HELPER_COMPATIBILITY         compatible      HELPER_BLOCKING 0
SUPERVISION_READY            true
```

Branch `arch/eng-0005-execution-transition`.

---

## 1. The three objects, measured

Read-only, without privilege. Each is at the digest the reviewed authority
`ef4f744` declares as its target:

```
/usr/libexec/kyri-exec-worker.py                      2d320630aca559c747522bb528f87172e747f30a182db0fec70e31eca272ddf5
/usr/lib/kyri/python/kyri_exec_transition_action.py   b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315
/usr/lib/kyri/python/kyri_exec_quota.py               54a9b15c6c6e3b785218d75c91b896f0723d3bf2051ebfca1351c84aa9855ca7

transaction residue (*.axhelpers.* / *.bbhelpers.* / *.prepared / *.backup)   0 files
/usr/libexec aggregate   49d928fec0d0fa4fd5534722a7041a63c992bc3dba9b4ac347115c437724f3cd   (moved: worker.py)
library object count     81                                                   (unchanged)
```

### 1.1 What I could not read

`/root` is unreadable to the coordinator and `sudo` is password-gated
non-interactively, so **the helper transaction journal and
`/root/kyri-g11-bb-helper-digests.txt` were not read by me.** `state=COMMITTED`
and the evidence file are taken from the operator's console output, and are
marked as such. Everything else in this report is measured.

## 2. Readiness — executed, not inferred

The released calculation is `_supervision_outlook()` in the installed
`tools/capability/cli.py`, and `supervision_ready` is the conjunction of both
identity authorities with `verdict.compatible` — not compatibility alone. Run
against the installed Generation-15 runtime:

```json
{
  "coordinator_identity_authority": true,
  "execution_identity_authority": true,
  "execution_identity_account": "kyri-capability",
  "helper_compatibility": "compatible",
  "helpers_blocking": [],
  "launch_grant": "unobservable",
  "reconcile_grant": "unobservable",
  "supervision_ready": true
}
```

`SUPERVISION_READY = true`, for the first time in this workstream.

The two grants report `unobservable` by design — the coordinator cannot read
them, and the surface says so rather than claiming absence. They are confirmed
separately in §5 from their readable metadata.

## 3. The "no production CINV or CRES exists" line — a real defect

**The check is wrong, and the line it printed is false.** It is recorded here
and **not** relied on for acceptance; nothing about it was changed.

```
require_no_invocation_records()            install-g11-bb-helpers.sh:594
  for root in "${FABRIC_ROOT}" "${AUTHORITY_ROOT}"; do
    count += find "${root}" -maxdepth 4 \( -name 'CINV-*' -o -name 'CRES-*' \) | wc -l
  (( count == 0 )) || halt "...invocation record(s) exist; this ceremony expects none"
  ok "no production CINV or CRES exists"

FABRIC_ROOT     /var/lib/kyri/fabric
AUTHORITY_ROOT  /var/lib/kyri/implementation-authority
```

**It scans two stores that structurally cannot hold those records.** Invocations
and results live in the capability runtime store:

```
/data/kyri/capability-runtime/capability-invocations/CINV-000001.yaml
/data/kyri/capability-runtime/capability-results/          (empty)
```

The Fabric store holds `CADV`, `CAPDEF`, `CCON`, `CHOST`, `CINST`, `CPKG`,
`CROUTE`, `CSEL` and their sequence files. There is **no** capability-invocation
sequence and no invocation directory under it:

```
find /var/lib/kyri/fabric /var/lib/kyri/implementation-authority \
     -maxdepth 4 \( -name 'CINV-*' -o -name 'CRES-*' \)   ->   0
```

So the check has printed `ok` on every host it has ever run on, regardless of
invocation state. **A check that cannot fail is not a check.** The message makes
a claim about production invocation state that the check does not establish.

### 3.1 Two defects that cancelled out

Had it been scoped to the store it names, it would have found `CINV-000001` and
halted — *"1 invocation record(s) exist; this ceremony expects none"* — and the
helper ceremony would have refused. So the second defect is the policy itself:
**"expects none" is a G11-AX-era statement about the host**, written when no
invocation had ever occurred, in exactly the shape as the sudoers gate BB-Q
corrected and the Generation-15 gate BB-L corrected before it.

`CINV-000001` is accepted, immutable, permanently `UNRESOLVED` history. BB-I §11
already ruled on this for Generation 15: *"nothing in this generation encodes
'production has never invoked'."* A ceremony that required zero invocation
records forever would be unrunnable from now on.

**The vacuity is why the ceremony was not blocked.** The deployment outcome is
correct — because tolerating historical `CINV-000001` is the correct policy —
but it succeeded by two errors cancelling, not by design.

```
HELPER_CINV_CHECK_MESSAGE_ROOT_CAUSE = require_no_invocation_records scans
FABRIC_ROOT and AUTHORITY_ROOT, which never hold CINV/CRES records; those live in
/data/kyri/capability-runtime. The check is therefore vacuous and its message
false. Its "expects none" policy is separately stale: correctly scoped it would
have refused for holding accepted history.
```

**Deliberately not changed here.** The ruling asked for classification before
change, and fixing it is a checkpoint of its own — the right correction is to
scope it at the runtime store *and* replace "expects none" with what the
ceremony actually requires, which is a question a reviewer should settle.

## 4. Capability runtime, read directly

```
CINV count                 1
CRES count                 0
CINV-000001                1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV-000002                absent — unspent
```

`CINV-000001` is byte-identical to its immutable digest, untouched by the helper
ceremony, and remains permanently `UNRESOLVED`.

## 5. Privileged surface

```
kyri-exec-launch      root:root 440 482
kyri-exec-reconcile   root:root 440 487
README                root:root 440 1068
metadata aggregate    f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9   unchanged
/etc/sudoers.d/kyri-exec-verify                                                          ABSENT

/usr/libexec/kyri-exec-transition   0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1   unchanged
/usr/libexec/kyri-exec-reconcile    2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77   unchanged

Root Authority mount                none
coordinator identity   3dec888c9efa4214d9cbc8a943818fbe21cd41fbf81ee252a1e38d5d25fd2811   accepted G11-AW
execution identity     891beeeb35bbf0e70dad9351825f34595875e8090f831c5db83ed8f66466e373   accepted G11-AW
```

Both entrypoint digests equal the constants the ceremony pins, so
`SUDOERS_PINS_MATCH = YES` and `SUDOERS_CHANGE_REQUIRED = NO`.

## 6. Container state — not verifiable from here

Listing the execution account's containers requires
`sudo runuser -u kyri-capability`, and its container store is `Permission
denied` to the coordinator. **I did not verify it and do not claim it.** The
operator command is in §10.

## 7. Runtime, Fabric and Trust

```
HOST_GENERATION      15
seven Gen-15 targets all still at their accepted target digests
fabric               7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96   unchanged
trust                53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   unchanged
```

The helper ceremony changed neither store. Fabric freshness is **not** asserted;
the chain is expected to need renewal before `CINV-000002`.

## 8. Two consequences of the ceremony landing — found and fixed

Both are the host-following class BB-P addressed, in places BB-P did not reach.
Neither is a fault in the deployment.

### 8.1 Generation-15 `--verify-installed` would now have refused

The helper ceremony moved two **library-root** objects, which Generation 15's own
carryover check judges. Its accepted-overlay chain named only G11-AX, so both
would have been reported as drift — proved in fixture before the fix:

```
FAIL  kyri_exec_quota.py is 4886d5b3…, the accepted helper ceremony records 54a9b15c…
FAIL  kyri_exec_transition_action.py is 7703231318f7…, … records b11a2f19…
```

**The correct model is not "the newest digest".** This check runs at two moments
that disagree: immediately after `--install` the helper surface has not moved, so
`kyri_exec_transition_action.py` is legitimately at G11-AX's target; after Phase 8
it is legitimately at G11-BB's. Both are accepted bytes. So the accepted set for
an object is

- the one state it holds **before** this generation installs — the last ceremony
  accepted before Generation 15 that governs it, or Generation-14 evidence when
  none does — **plus**
- the target of every ceremony accepted **after** Generation 15 that governs it.

That is deliberately not "any digest it ever had": a pre-G11-AX state is
superseded and still refuses, because G11-AX ran before this generation and is
not optional. Verified against production's real bytes:

```
object                          installed       accepted states               verdict
kyri_exec_transition_action.py  b11a2f19bc46    7703231318f7  b11a2f19bc46    ACCEPTED
kyri_exec_quota.py              54a9b15c6c6e    54a9b15c6c6e                  ACCEPTED
kyri_exec_verify.py             f49c29571a4e    f49c29571a4e                  ACCEPTED
kyri_exec_transition.py         de264c6490e0    de264c6490e0                  ACCEPTED
kyri_exec_reconcile.py          29175d5a7175    29175d5a7175                  ACCEPTED
```

### 8.2 Three fixtures whose "predecessor" followed the host

The same coupling, in three places, all now resolved by finding the declared
predecessor **by digest in reviewed history** instead of copying the host:

- **`bb-helper-ceremony`** — `publish_helpers … pre` took predecessor bytes from
  the live host. True only until this ceremony was accepted; after it,
  "predecessor" and "successor" were the same bytes and cases A, D and E
  silently inverted.
- **`generation15-installer`** — its fixture copied the declared `/usr/libexec`
  helper set from the live host, so a Generation-14 fixture carried G11-BB's
  successors and the fail-closed-first section reported the predecessor fixture
  as not compatible.
- **`helper-ceremony` (G11-AX)** — carried the quota pair from the live host, so
  a fixture whose runtime declaration predates G11-BB held G11-BB's quota object
  and called the complete AX target set incompatible.

Each is the class BB-P removed elsewhere, surfacing wherever a fixture still
reached for the host to answer "what did the predecessor look like".

## 9. Acceptance

```
HELPER_DEPLOYMENT_ACCEPTED = YES
```

The deployment is materially correct: three objects at reviewed targets,
coherence complete, readiness compatible with zero blocking, `supervision_ready`
true from the released calculation, both grants and both pinned entrypoints
unchanged, verify grant absent, Fabric and Trust untouched, `CINV-000001`
byte-identical and still `UNRESOLVED`.

**Two things are accepted with a stated caveat**, not silently:

1. The ceremony's `"no production CINV or CRES exists"` line is false and must
   not be cited as evidence for anything (§3). Fixing it is a separate
   checkpoint.
2. `state=COMMITTED` and the helper evidence file are operator-reported, not
   measured here (§1.1).

## 10. Validation

Host-only results are separate from CI, which exercises none of them.

```
HOST-ONLY SUITES     26 PASS   3 SKIP   0 FAIL     (clean serial run)
LOCAL_QUICK          PASS   109/109
LOCAL_FULL           PASS   134/134
bb-helper-ceremony   PASS   52 assertions
generation15         PASS   103 assertions
helper-ceremony (AX) PASS   103 assertions
shellcheck           clean
```

One suite, `test-capability-execution-reconciliation.sh`, failed once during a
sweep that overlapped another validation run — it drives Podman and the two runs
collided on container names. It passes standalone and in the clean serial sweep;
recorded because the transient failure is in the logs and should not be mistaken
for a regression.

## 11. Operator items I could not verify

Both need privilege the coordinator does not have. **Neither is claimed above.**

```bash
# 1. Generation 15 still verifies, now that the helper surface has moved.
#    This is the check §8.1 repairs -- it should pass, and its carryover line
#    should name Generation 14 plus 5 ceremony-published objects.
sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify-installed

# 2. The helper transaction is COMMITTED and its evidence exists.
sudo sed -n 's/^state=/journal state: /p' /root/kyri-g11-bb-helper-transaction/journal
sudo ls -la /root/kyri-g11-bb-helper-digests.txt

# 3. No kyri-CINV-* container exists. Historical trackb-* may remain; leave them.
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
```

## 12. Next

A fresh Fabric chain — `CADV` → `CINST` → `CROUTE` → `CSEL` — before
`CINV-000002`. **No Fabric record was written by this checkpoint** and none is
authorized by it.

```
FABRIC_RENEWAL_AUTHORISED      NO
PRODUCTION_INVOKE_AUTHORISED   NO
CINV_000001_RESUME_AUTHORISED  NO
```
