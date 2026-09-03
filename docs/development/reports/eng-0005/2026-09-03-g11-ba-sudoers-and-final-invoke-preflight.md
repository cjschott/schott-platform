# ENG-0005 G11-BA — narrow sudoers grants and the final invoke preflight

**Status: prepared, and one finding is referred to the reviewer before any grant
is installed.** Nothing was installed. No `CINV` or `CRES` was allocated. The
production Fabric and capability-runtime manifests are byte-identical before and
after every check.

Follows **[G11-AZ-D](2026-09-03-g11-az-d-csel-000002-production-write.md)**,
which accepted `CSEL-000002` and completed the Fabric chain renewal.

Branch `arch/eng-0005-execution-transition`, HEAD `f4a3ee2`.

---

## 1. Summary

Everything G11-BA set out to prepare is prepared and validated: two narrow,
independently withdrawable sudoers candidates, and a released invoke preflight
that passes against live production without mutating anything.

**One finding stops short of handing over the install blocks as authorised.**
The installed runtime carries a stale `tools/capability/execution/verification.py`
that cannot be imported against the `worker.py` beside it. It is **not** on the
supervised launch path and it is **not** one of the eight declared helpers, so
`compatibility()` reports `compatible` and is right to. It is inherited from the
Generation-13 baseline, and it is latent because the entrypoint that loads it
has no grant either. Details in §7. The reviewer should rule on it before the
grants go in.

## 2. Privileged surface, from installed bytes

Re-read from disk, not from remembered values.

| object | mode | SHA-256 |
| --- | --- | --- |
| `/usr/libexec/kyri-exec-transition` | `0555` | `0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1` |
| `/usr/libexec/kyri-exec-reconcile` | `0555` | `2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77` |
| `/usr/libexec/kyri-exec-worker.py` | `0444` | `6d06695f433570070b15fc4a990b53dcbaa227001586d4062e254a08367723fd` |
| `/usr/libexec/kyri-exec-reconcile-worker.py` | `0444` | `b0e3c047f689ad5d1e4ef2979f771ca4acdbc80cf8109df8a7cf59a790eb8d2a` |
| `kyri_exec_transition.py` | `0444` | `de264c6490e08f6b7dc5f0bcddd15ffdde50278c183161fba04bf4cf1440f5a6` |
| `kyri_exec_transition_action.py` | `0444` | `7703231318f7a872f80abc0b033c2462c24ec63bd8669773d6643634af1d296a` |
| `kyri_exec_reconcile.py` | `0444` | `29175d5a71759336cc869007c83f0c13cb093023ea4bd77344b4f62cd4275a46` |
| `kyri_exec_quota.py` | `0444` | `4886d5b323c9dfdf46939c83424b087bb052f3fc90b8bd4a5ba2b4346bff9e9c` |
| `kyri_exec_verify.py` | `0444` | `f49c29571a4e1f8724a7826d14f58b8b45af7662e11155318f5e40fbe33be51f` |
| `/usr/libexec/kyri-exec-verify` | `0555` | `1c87788c655922121ca352f27fc7508553e437480562a6f2edac4c52e68e81a0` |
| `/usr/libexec/kyri-exec-verify-worker.py` | `0444` | `c747c6d0c306b852bb990a7ede6a9b05e84fea34c3e0ea930ff2385b2a745774` |

All owned `root:root`. **The ten-object G11-AX ceremony is coherent**: every
post-state digest recorded in
[G11-AX-2 §matrix](2026-09-02-g11-ax-2-coherent-helper-production.md) matches the
bytes installed today, all ten.

**Launch and reconcile are separate entrypoints and are kept separate
throughout.** They are distinct executables with distinct digests, and §5 gives
them distinct files.

## 3. Helper and identity coherence

Installed Generation-14 `compatibility()`, run from the installed tree:

```
verdict   : compatible
declared  : 8
blocking  : 0

current  /usr/libexec/kyri-exec-transition
current  /usr/libexec/kyri-exec-worker.py
current  /usr/libexec/kyri-exec-reconcile
current  /usr/libexec/kyri-exec-reconcile-worker.py
current  /usr/lib/kyri/python/kyri_exec_transition.py
current  /usr/lib/kyri/python/kyri_exec_transition_action.py
current  /usr/lib/kyri/python/kyri_exec_reconcile.py
current  /usr/lib/kyri/python/kyri_exec_quota.py
```

Identity authorities, exact:

```
/etc/kyri/coordinator-identity.json  root:root 0444  3dec888c…5fd2811
    coordinator_account cschott            uid 1000   (system: uid=1000)
/etc/kyri/execution-identity.json    root:root 0444  891beeeb…466e373
    execution_account   kyri-capability    uid 999 gid 987
                                            (system: uid=999 gid=987)
```

`COORDINATOR_IDENTITY = PASS`, `EXECUTION_IDENTITY = PASS`.

**Protocol FD topology, checked across the boundary** — runtime side against the
installed privileged module, not against a constant repeated here:

```
runtime  tools.capability.execution.worker.PROFILE_FD   = 3
helper   /usr/lib/kyri/python/kyri_exec_transition.PROFILE_FD = 3
runtime  EXPECTED_DESCRIPTORS = [0, 1, 2, 3]   == {0,1,2,PROFILE_FD}
```

The entrypoints name the modules root loads after elevating —
`kyri-exec-transition` declares `POLICY_MODULE`, `ACTION_MODULE`, `QUOTA_MODULE`;
`kyri-exec-reconcile` declares `POLICY_MODULE`, `ACTION_MODULE`. All are among
the eight declared helpers above, so the by-name load after elevation is covered
by the compatibility table rather than assumed.

## 4. sudo capability, verified on this host

```
Sudo version 1.9.15p5
Sudoers policy plugin version 1.9.15p5
Sudoers file grammar version 50
```

Regex argument support was **read from this host's own `sudoers(5)`**, not
assumed from a version number:

> *"If the arguments in a Cmnd begin with the '^' character, they will be
> interpreted as a regular expression and matched accordingly."*
>
> *"Starting with version 1.9.10, it is possible to use regular expressions for
> path names and command line arguments … POSIX extended regular expressions …
> regular expressions must start with a '^' character and end with a '$'."*

1.9.15p5 ≥ 1.9.10, and the manual on this host documents the behaviour. The
anchors in the candidates are therefore load-bearing: `^CINV-[0-9]{6}$` is a
regex, not a literal.

**Arguments are matched as one joined string**, so a second argument cannot slip
past an anchored single-token pattern — the manual's own `passwd ^[a-zA-Z0-9_]+$`
example relies on exactly this.

## 5. The two candidates

The principal is **derived**, not typed: read from
`/etc/kyri/coordinator-identity.json` → `coordinator_account: cschott`. The
digests are the installed bytes from §2.

Two files, so either authority can be withdrawn alone by deleting one file.

**`/etc/sudoers.d/kyri-exec-launch`**

```
# Kyri capability execution — LAUNCH authority only.
# Grants one exact executable, pinned by digest, taking exactly one CINV
# identifier. No shell, no wildcard path, no arbitrary arguments, no Podman.
# Withdraw by removing this file; the reconcile authority is unaffected.
Cmnd_Alias KYRI_EXEC_LAUNCH = sha256:0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1 \
    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$
cschott ALL=(root) NOPASSWD: KYRI_EXEC_LAUNCH
```

**`/etc/sudoers.d/kyri-exec-reconcile`**

```
# Kyri capability execution — RECONCILE authority only.
# Grants one exact executable, pinned by digest, taking exactly one CINV
# identifier. No shell, no wildcard path, no arbitrary arguments, no Podman.
# Withdraw by removing this file; the launch authority is unaffected.
Cmnd_Alias KYRI_EXEC_RECONCILE = sha256:2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77 \
    /usr/libexec/kyri-exec-reconcile ^CINV-[0-9]{6}$
cschott ALL=(root) NOPASSWD: KYRI_EXEC_RECONCILE
```

**`visudo -cf`**: both `parsed OK`.

**Structural assertions, made mechanically against the `cvtsudoers -f json`
parse** rather than by reading the text — all PASS for both files:

```
exactly one command                          no ALL command grant
command path exact                           no shell granted
digest pinned to installed bytes             no podman granted
argument is anchored regex                   no unqualified/relative path
no wildcard in path                          runas is exactly root
caller is exactly the coordinator identity
```

**Argument shapes, evaluated against the POSIX ERE `^CINV-[0-9]{6}$`:**

| joined argument vector | verdict |
| --- | --- |
| `CINV-000001` | **ALLOW** |
| `CINV-123456` | **ALLOW** |
| `CINV-000001 extra` | REFUSE |
| `CINV-000001 --privileged` | REFUSE |
| `CINV-1` | REFUSE |
| `CINV-0000001` | REFUSE |
| `cinv-000001` | REFUSE |
| `CINV-00000A` | REFUSE |
| `../../etc/shadow` | REFUSE |
| `; /bin/sh` | REFUSE |
| `CINV-000001; rm -rf /` | REFUSE |

**A limit worth stating plainly.** `sudo -l` cannot be run against an
uninstalled policy, so the *runtime* refusals above are established by the
regex and by the parsed policy structure, not by exercising sudo's dispatch.
Wrong-executable, wrong-caller, broad-sudo and direct-Podman refusals are
established structurally: the policy contains exactly one command per file, one
user, one runas, and no other rule. **The operator should confirm at install
time** with:

```bash
sudo -l -U cschott | sed -n '/kyri/p'      # exactly the two commands, nothing else
sudo -n /usr/libexec/kyri-exec-transition CINV-00000A   # must be refused
sudo -n /usr/libexec/kyri-exec-transition CINV-000001 x # must be refused
sudo -n /usr/bin/podman ps                              # must be refused
```

`LAUNCH_SUDOERS_CANDIDATE = READY`, `RECONCILE_SUDOERS_CANDIDATE = READY`.
**Neither installed.**

## 6. Final invoke preflight

Released `invoke --preflight` against live production, `--operation execute`,
against `CSEL-000002` / `CINST-000003` / `CPKG-0001`:

```
outcome                          preflight
would_accept                     true
would_refuse_reason              null
current_eligibility              true
eligibility_reasons              []
scope_permits_operation          true
supervision_ready                true
helper_compatibility             compatible
helpers_blocking                 []
coordinator_identity_authority   true
execution_identity_authority     true
execution_identity_account       kyri-capability
selection_id                     CSEL-000002
instance_id                      CINST-000003
capability_package_id            CPKG-0001
implementation_id                CIMP-000001
execution_image_id               5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
execution_backend                python-podman-v1
argv_contract                    fixed-python-entrypoint-v1
package_tree_sha256              sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
payload_digest                   sha256:740d6416858561a5fae1f639b5432cf11209f4540b5186442f920d6efc19b562
binding_digest                   sha256:9e8719cff713eb54f05bc087c5e81d09ddbcfa04505ffb0073e0b3fbd88a59fd
predicted_invocation_record_id   CINV-000001
privileged_helper_required       true
launch_grant                     unobservable
reconcile_grant                  unobservable
adapter_authorised               false
execution_image_available        false
would_stage_at                   …/staging/tree-sha256-6f2282c5…
```

`INVOKE_PREFLIGHT = PASS`.

**Execution binding resolves end to end**, and the image identity is the
approved one, unchanged:

```
CSEL-000002 → CINST-000003 → CPKG-0001 → CIMP-000001
            → 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
```

**Non-mutation, proved by manifest:**

```
Fabric  before/after   7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96   identical
runtime before/after   f7f5c181f1bf4557ac68157335459d1c36e7c03911308a2b9a4066dd0715650f   identical
runtime entries        17  →  17
CINV / CRES            0 / 0        no record of either kind exists
staging material       none created
handoff entries        0
```

`PREFLIGHT_MUTATES = NO`. No identifier was allocated — `CINV-000001` is
*predicted*, not taken. No privileged helper ran and no container was created.

**Disclosure — an earlier command in this checkpoint did mutate the store, and
it was not the preflight.** While reconstructing state, this checkpoint ran

```
python3 -m tools.capability.cli inspect --store-root /data/kyri/capability-runtime …
```

`inspect` opens the store through the **writing** constructor, which creates the
record and sequence directories before looking at any evidence. At
`18:16:41` it created, under `/data/kyri/capability-runtime`:

```
d  capability-invocations/                 cschott:cschott 0700   empty
d  capability-results/                     cschott:cschott 0700   empty
d  sequences/                              cschott:cschott 0700
f  sequences/invocation_identity.lock      cschott:cschott 0600   0 bytes
```

**No governed record was created and no sequence counter exists** — there is no
`capability-invocation.seq`, both record directories are empty, and
`PRODUCTION_CINV_COUNT` / `PRODUCTION_CRES_COUNT` remain `0`. The store would
create these same objects for itself on its first write.

This is precisely the distinction `command_preflight` documents about itself:
*"The store is only ever read. It is opened through `open_for_read`, so an absent
store is reported as absent rather than built and then described — which matters
here, because the writing constructor creates the record directories and the
sequence directory before any evidence is looked at."* The preflight honoured
that; `inspect` does not, and this checkpoint should have used a read-only
surface to enumerate the store. The four objects above were already present when
the preflight ran, which is why its own before/after manifests are identical.

**Left in place rather than removed.** Deleting them would be a second
unrequested mutation of production state; they are inert and correctly owned.
The operator may remove them with
`rmdir …/capability-invocations …/capability-results` and
`rm …/sequences/invocation_identity.lock && rmdir …/sequences` if a pristine
store is wanted before the first invoke.

**Two `false` fields that are correct, and are not failures:**

- `adapter_authorised: false` — `command_invoke` supplies neither `adapter` nor
  `execution_binding`, so preparation stops before execution by construction.
- `execution_image_available: false` — **this is the observation point, not the
  image.** `RootlessImageStore()` with no arguments reads `$HOME` of the calling
  process. Run as the coordinator that is
  `/home/cschott/.local/share/containers/storage`; the execution identity's
  store is `/data/kyri/capability/.local/share/containers/storage`, which the
  coordinator **cannot read** (`Permission denied`) — correctly, by the identity
  boundary. The field is meaningful only inside the transitioned worker, whose
  `HOME` is the execution home. **The preflight therefore cannot vouch for image
  presence**, and the operator should confirm it as the execution identity
  before the first invoke.

## 7. Finding — stale `verification.py` in the installed runtime

**What was found.** A full comparison of the installed library tree against the
Generation-14 source authority `946be55`:

| object | installed | `946be55` | |
| --- | --- | --- | --- |
| `tools/capability/execution/verification.py` | `ed5b49ed…bd2e73` | `7a792aaf…1efa952` | **differs** |
| `tools/capability/execution/result_content.py` | absent | present | **not deployed** |
| `tools/capability/execution/contract_outcome.py` | absent | present | **not deployed** |
| everything else (76 objects) | — | — | identical |

The installed `verification.py` **cannot be imported**:

```
ImportError: cannot import name 'WORKER_GID' from
  'tools.capability.execution.worker' (/usr/lib/kyri/python/.../worker.py)
```

It predates `03a2e90` *"derive helper identity from deployment authority"*, which
removed the hardcoded `WORKER_UID`/`WORKER_GID` in favour of the identity
authority. The co-installed `worker.py` is current (`df9d252e…`, identical to
both repo and `946be55`), so the pair is split across that change — the G11-AI
defect class, in the runtime tree rather than the helper tree.

**Why `compatibility()` still says `compatible`, correctly.** `REQUIRED_HELPERS`
declares eight privileged objects and deliberately excludes the verification
surface — `helpers.py` says so in as many words: *"The verification helper is
deliberately absent: it is a governed alternative entrypoint, not something
supervision depends on."* The table polices the privileged surface, not the
whole library, so it cannot see this and does not claim to.

**Why this is inherited, not a Generation-14 regression.** Generation 14 is a
**single-object** change: its `MATRIX` replaces exactly one library file,
`helpers.py`. It verifies everything else against the Generation-13 baseline
evidence and expects `EXPECTED_LIBRARY_FILES_BASELINE=78`. The installed tree
holds **79** `.py` objects — 78 plus the one published helper module — which is
exactly what the installer expects and what the handoff describes. **Generation
14 is internally consistent; the stale module came in with Generation 13.**

**Blast radius, traced rather than assumed.**

- `verification.py` has exactly one consumer in the whole tree:
  `provisioning/execution/kyri-exec-verify-worker.py`, i.e. the
  `/usr/libexec/kyri-exec-verify` alternative entrypoint. It is **not** on the
  supervised launch path.
- Every module the launch path does load imports cleanly from the installed
  tree: `worker`, `identity`, `snapshot`, `adapter`, `image_store`, `protocol`,
  `helpers`, `profile`, `types`, `collector`, `payload`, `canonical_json` — all
  **OK**.
- The failure is **fail-closed**: the verify worker wraps the import and exits
  with *"the governed verification library is not importable"* rather than
  proceeding.
- It is **latent**: `/usr/libexec/kyri-exec-verify` requires its own grant at
  `/etc/sudoers.d/kyri-exec-verify`, which is **not installed**. Nothing can
  reach the broken module today.
- `result_content.py` and `contract_outcome.py` have **no importer anywhere**.
  `CCON-0001` names `result_content.py` in `response_shape.content.authority`,
  but as a documentation reference string, not as a runtime import.

**Assessment.** This does not block the first controlled invoke on the evidence
above — the launch path is intact and the defect is unreachable. It does mean
one of the ten governed helper entrypoints is currently non-functional, and that
a contract-referenced authority file is not deployed. **Because the checkpoint's
rule is to stop on module drift, the install blocks in §8 are presented as
prepared and reviewed rather than authorised**, and the reviewer should rule on
whether to remediate the runtime first or proceed to the grants and carry this
as a tracked defect.

## 8. Operator install blocks — prepared, pending the §7 ruling

**Do not run these until the §7 finding is ruled on.** Two independent files, so
either authority can be withdrawn alone.

### A — launch

```bash
bash <<'INSTALL_LAUNCH'
set -Eeuo pipefail
DEST=/etc/sudoers.d/kyri-exec-launch
EXPECT=0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1

printf '\n--- /etc/sudoers.d BEFORE ---\n'
sudo find /etc/sudoers.d -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

ACTUAL="$(sha256sum /usr/libexec/kyri-exec-transition | cut -d' ' -f1)"
test "${ACTUAL}" = "${EXPECT}" || {
  echo "REFUSE: helper is ${ACTUAL}, reviewed ${EXPECT}"; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
# Kyri capability execution — LAUNCH authority only.
# Grants one exact executable, pinned by digest, taking exactly one CINV
# identifier. No shell, no wildcard path, no arbitrary arguments, no Podman.
# Withdraw by removing this file; the reconcile authority is unaffected.
Cmnd_Alias KYRI_EXEC_LAUNCH = sha256:0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1 \
    /usr/libexec/kyri-exec-transition ^CINV-[0-9]{6}$
cschott ALL=(root) NOPASSWD: KYRI_EXEC_LAUNCH
BODY

visudo -cf "${TMP}" || { echo "REFUSE: visudo rejected the candidate"; rm -f "${TMP}"; exit 1; }
sudo install -o root -g root -m 0440 "${TMP}" "${DEST}"
rm -f "${TMP}"

printf '\n--- installed ---\n'
sudo stat -c '%n  %U:%G  %a  %s bytes' "${DEST}"
sudo visudo -c

printf '\n--- what cschott may now run ---\n'
sudo -l -U cschott | sed -n '/kyri/p'
INSTALL_LAUNCH
```

### B — reconcile

```bash
bash <<'INSTALL_RECONCILE'
set -Eeuo pipefail
DEST=/etc/sudoers.d/kyri-exec-reconcile
EXPECT=2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77

printf '\n--- /etc/sudoers.d BEFORE ---\n'
sudo find /etc/sudoers.d -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

ACTUAL="$(sha256sum /usr/libexec/kyri-exec-reconcile | cut -d' ' -f1)"
test "${ACTUAL}" = "${EXPECT}" || {
  echo "REFUSE: helper is ${ACTUAL}, reviewed ${EXPECT}"; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
# Kyri capability execution — RECONCILE authority only.
# Grants one exact executable, pinned by digest, taking exactly one CINV
# identifier. No shell, no wildcard path, no arbitrary arguments, no Podman.
# Withdraw by removing this file; the launch authority is unaffected.
Cmnd_Alias KYRI_EXEC_RECONCILE = sha256:2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77 \
    /usr/libexec/kyri-exec-reconcile ^CINV-[0-9]{6}$
cschott ALL=(root) NOPASSWD: KYRI_EXEC_RECONCILE
BODY

visudo -cf "${TMP}" || { echo "REFUSE: visudo rejected the candidate"; rm -f "${TMP}"; exit 1; }
sudo install -o root -g root -m 0440 "${TMP}" "${DEST}"
rm -f "${TMP}"

printf '\n--- installed ---\n'
sudo stat -c '%n  %U:%G  %a  %s bytes' "${DEST}"
sudo visudo -c

printf '\n--- what cschott may now run ---\n'
sudo -l -U cschott | sed -n '/kyri/p'
INSTALL_RECONCILE
```

Each block refuses if the destination exists, re-checks the helper digest
against the reviewed value **at install time**, and validates with `visudo -cf`
before installing. Withdrawal is `sudo rm /etc/sudoers.d/kyri-exec-launch` or
`…/kyri-exec-reconcile`, independently.

## 9. State at the close of this preparation

```
AZ_D_ACCEPTED             YES
FABRIC_CHAIN_FRESH        YES   CADV-000004 → CINST-000003 → CROUTE-0003 → CSEL-000002
FABRIC_VALID              YES   findings 0, counts 4/3/3/2
TRUST_VALID               YES   problems 0
CURRENT_ELIGIBILITY       PASS  ELIG-1..12 all met
HELPER_COMPATIBILITY      compatible   8 declared, 0 blocking
HELPER_CEREMONY_COHERENT  YES   all ten AX objects byte-exact
SUPERVISION_READY         true
INVOKE_PREFLIGHT          PASS
PREFLIGHT_MUTATES         NO
RUNTIME_MODULE_DRIFT      YES   §7 — stale verification.py, two modules not deployed
PRODUCTION_CINV_COUNT     0     no record; empty directory created by §6 disclosure
PRODUCTION_CRES_COUNT     0     no record; empty directory created by §6 disclosure
SUDOERS_CLOSED            YES   0 non-README files
ROOT_AUTHORITY_UNMOUNTED  YES
PRODUCTION_INVOKE_AUTHORISED  NO
```

## 10. Next

1. **Reviewer rules on §7** — remediate the runtime first, or proceed and track
   the stale `verification.py` as a known defect.
2. Operator confirms the admitted image is present **as the execution identity**
   (§6), which the coordinator cannot observe.
3. Operator installs the two grants with §8 A and B and returns the complete
   output, including `sudo -l -U cschott` and the refusal probes from §5.
4. Independent verification of the installed grants, then **G11-BB** — the first
   controlled production invocation, where the first `CINV`/`CRES` appear.
