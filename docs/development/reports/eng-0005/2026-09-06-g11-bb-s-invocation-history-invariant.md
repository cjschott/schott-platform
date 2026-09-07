# ENG-0005 G11-BB-S — the vacuous invocation-history check, closed

**Status: the defect BB-R recorded and deliberately did not fix is corrected.
The ceremony now reads the store that actually holds invocation history, and
requires what governance actually permits instead of an empty history.** This is
a provisioning-and-test correction. **No governed production object changed, no
production state was mutated, and no deployment ceremony is required by it.**

```
INVOCATION_CHECK_OBSERVATION_FIX   PASS
INVOCATION_CHECK_POLICY_FIX        PASS
SAME_DEFECT_CLASS_LIVE_WRONG       0
SAME_DEFECT_CLASS_LATENT_WRONG     0
FABRIC_MUTATION                    NONE
PRODUCTION_INVOKE_AUTHORISED       NO
```

Branch `arch/eng-0005-execution-transition`.

---

## 1. Root cause, restated precisely

BB-R §3 named it and left it. Two independent defects in one function,
`require_no_invocation_records` at `install-g11-bb-helpers.sh:594`:

```
  for root in "${FABRIC_ROOT}" "${AUTHORITY_ROOT}"; do
    count += find "${root}" -maxdepth 4 \( -name 'CINV-*' -o -name 'CRES-*' \) | wc -l
  (( count == 0 )) || halt "...invocation record(s) exist; this ceremony expects none"
  ok "no production CINV or CRES exists"
```

**A. Observation.** `FABRIC_ROOT` is `/var/lib/kyri/fabric` and `AUTHORITY_ROOT`
is `/var/lib/kyri/implementation-authority`. Neither holds a `CINV` or a `CRES`
and neither ever can: the Capability Runtime is a **second plane** with its own
root, its own identifier space, its own sequences and its own lock, deliberately
separate from the Fabric's eight record kinds (`tools/capability/store.py`
module docstring). Invocation history lives at
`/data/kyri/capability-runtime`. The count was therefore always zero, the check
could not fail, and its success line asserted a property it never established.

**B. Policy.** "This ceremony expects none" is a G11-AX-era statement about a
host on which nothing had ever been invoked. `CINV-000001` is accepted,
immutable, permanently `UNRESOLVED` history (G11-BB-D; resume **not**
authorised). Scoped correctly while keeping that policy, the check would have
**refused the accepted host** for holding exactly the history governance ruled
it should hold.

The two cancelled, which is why the ceremony was never blocked and why the false
line reached a production console. This is the same shape BB-L corrected in the
Generation-15 preflight and BB-Q corrected in the sudoers gate — the third
instance of one class.

Both halves are executed rather than argued. The B half is proved against the
**historical bytes**: the suite extracts `require_no_invocation_records`
verbatim out of `96653199` and runs it with its roots pointed at the correct
store, and requires the refusal BB-R predicted.

## 2. The invariant that replaced it

`require_accepted_invocation_history <freshness>`. It reads the governed store
through **the platform's own readers** — `CapabilityStore.open_for_read`,
`inspection.validate_store`, `store.list_records`, `store.path_for`,
`store.peek_next_id`, `identifiers.ID_FIELDS` — loaded from `${LIBRARY_ROOT}`,
exactly as `runtime_verdict` takes the readiness rule from the installed runtime
rather than carrying a copy. Nothing here is a second interpretation of the
store.

The store's expected ownership is neither guessed nor taken from the store
itself, which would be circular: the coordinator account comes from the identity
authority whose bytes `require_identity_authorities` has already pinned, and is
resolved through the platform's own `identity.resolve_account`.

**What is declared**, in the same shape as the identity authorities above it:

```bash
ACCEPTED_INVOCATION_HISTORY=(
  "CINV-000001 1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa"
)
ACCEPTED_RESULT_HISTORY=()
```

**What it refuses**, in both freshness modes:

| refuses | because |
| --- | --- |
| an absent or unreadable store while anything was reviewed | fail closed; never a quiet pass, which is the whole of what was wrong |
| any finding from `validate_store` | malformed records, orphan results, duplicate identity, outcome mismatch, refusal-without-result, result-without-execution-authority, execution-interrupted, partial-write residue |
| an object in a record directory that is not a governed record | an object nobody declared |
| a declared record absent, or at bytes other than its declared digest | a `CINV` is immutable pre-execution evidence and a `CRES` a terminal outcome; neither may move |
| a record count that disagrees with its own sequence counter | an identity spent whose record never landed, or a record no allocation produced |

**What is mode-scoped, and why.** Freshness — "the host has not moved past the
review" — is a **preflight** question. `--verify` requires the history to be
*exactly* the reviewed one, so an invocation prepared between review and install
refuses and forces re-review. `--verify-installed` does not, because it attests
to a helper surface, and an accepted deployment must not start reporting FAIL
the moment the platform does the thing it exists for. Pinning the *size* of the
history in a post-install attestation would be the BB-L/BB-Q/BB-R staleness
class one grain finer, with `CINV-000002` expected next. Pinning a declared
record's *digest* is durable: a `CINV` can never legitimately change.

**Scope this deliberately does not claim.** The lifecycle-journal signature of a
lost supervised execution (`recovery.unresolved_invocations` with a real
`execution_root`) is **not** read here. It needs a verified `RootDescriptor`
built from the provisioned backing-store configuration, which a `--fixture` run
cannot construct and which is not this ceremony's question. The
execution-safety gate (`capability recover`) remains the surface that answers
it. What this check does cover on the record plane is a `CRES` that appeared, a
`CINV` that changed, an adapter identity bound without a terminal result, and a
counter that moved — stated rather than implied.

**Under `--fixture`**, `RUNTIME_STORE` is rebound like every other root, and the
declaration is read from `${FIXTURE}/root/kyri-accepted-invocation-history.txt`
beside the other evidence files the ceremony already reads out of a fixture's
`/root`. A fixture is a different host and production's pin names production's
records; a fixture declaring none is a host on which nothing was ever invoked.
This is not a production override — under `--fixture` no production path is read
for state either way.

## 3. RED first, then GREEN

Seventeen assertions were added to
`tests/test-capability-execution-bb-helper-ceremony.sh` (already registered in
`tools/dev/run-validation.sh:437` and `tests/host-only.manifest`). Against the
pre-correction bytes, **eleven failed**:

```
FAIL  the ceremony still claims an empty invocation history: ok  no production CINV or CRES exists
FAIL  the ceremony did not name the capability-runtime store
FAIL  an invocation record nobody reviewed was accepted
FAIL  a result record nobody reviewed was accepted
FAIL  the reviewed CINV rewritten was accepted
FAIL  the reviewed CINV removed was accepted
FAIL  the next invocation identity spent was accepted
FAIL  a malformed invocation record was accepted
FAIL  a partial write left in the record store was accepted
FAIL  an unexpected object in the record store was accepted
FAIL  declared history with no runtime store was accepted
```

After the correction all seventeen pass, and the suite is 69 PASS / 0 FAIL (52
before this checkpoint).

Two properties of the suite are worth naming, because an earlier draft of each
was wrong:

- **Every refusal must name the invocation history.** Without that, cases pass
  because the ceremony refused for coherence or readiness. The freshness case
  originally did exactly that; it now runs on a host whose helper surface is
  still the predecessor, so only the history can be the reason.
- **The fixture store is built from the platform's own record model.** An
  invocation carrying a terminal result also carries the adapter identity that
  result came from, or `validate_store` reports
  `result-without-execution-authority` — correctly — and every case built on the
  fixture would refuse for that instead of for what it names.

## 4. Defect-class sweep

Two sub-classes were swept: a check reading a store that cannot hold what it
claims, and a policy asserting production has never advanced. Every match:

```
LIVE_AND_WRONG        0   (after this correction)
LATENT_AND_WRONG      0
```

| site | class | reason |
| --- | --- | --- |
| `install-g11-bb-helpers.sh:594` `require_no_invocation_records` | **LIVE_AND_WRONG → fixed** | this checkpoint |
| `install-g11-ax-helpers.sh:547` `require_no_invocation_records` | HISTORICAL_ONLY | see below |
| `install-g11-ax-helpers.sh:523` `require_gates_closed` "no sudoers grant exists" | HISTORICAL_ONLY | same ceremony, same reason; BB-Q left it for this reason and consistency is kept |
| `test-capability-execution-helper-ceremony.sh:258` pinning both AX lines | HISTORICAL_ONLY | a pin on a superseded ceremony's console text; now carries a comment saying so |
| `install-generation-15.sh:1001/1003` grant gate | SAFE | BB-L's correction; both branches measured from the real grant paths |
| `install-generation-15.sh:1527` `verify_excluded_absent` | READ_ACTUALLY_REQUIRED | scans `LIBRARY_ROOT`, which is where an excluded module would be |
| `install-generation-15.sh:1065` matrix/exclusion collision | SAFE | a self-check over the matrix; reads no store |
| `install-g11-bb-helpers.sh:629` grant gate | SAFE | BB-Q's correction |
| `install-g11-bb-helpers.sh:371` namespace isolation | SAFE | scans the runtime generations' real journal namespace |
| `install-g11-bb-helpers.sh:646` Root Authority mount | SAFE | reads `mount` |
| transaction-residue and journal checks in both ceremonies | SAFE | scan the actual target pathnames and journal |
| `test-capability-execution-launch-cli.sh:755`, `-launch-bridge.sh:796` | SAFE | already corrected by BB-F; both explicitly refuse to assert an empty handoff |

**Why G11-AX is HISTORICAL_ONLY and not LATENT.** It cannot reach either stale
check on the accepted host. `require_runtime_generation` pins the Generation-14
readiness rule —

```
AX pins   74b84015b18a6f38e88633e068cb9c4bdf2753804f3c336ca45aa9a577125874
installed 6dd936064f1c6d3813cbdbd9fb175b03902b18623493638cded55e3e930b8b07
```

— and it runs **before** `require_gates_closed` and
`require_no_invocation_records` in every mode that calls them. `--verify-source`
reaches none of the three. The ceremony has already run, is superseded by
G11-BB, and rewriting a superseded ceremony's console text would edit evidence
of what actually ran.

Nothing else in `provisioning/`, `tools/` or `tests/` scans a store for records
it cannot hold, and no other check asserts that production has never been
invoked.

## 5. Classification of the change

```
provisioning/execution/install-g11-bb-helpers.sh          +233 / -9
tests/test-capability-execution-bb-helper-ceremony.sh     +310
tests/test-capability-execution-helper-ceremony.sh        +14   (comment only)
```

**No governed production object changes.** `COMMIT`, `RUNTIME_COMMIT`,
`RUNTIME_HELPERS_SHA256`, `EXPECTED_RUNTIME_OBJECTS`, `HELPER_SOURCES` and every
`MATRIX` row — source, target, mode, operation, predecessor digest, target
digest, closure — are byte-identical to `9665319`. The three published helper
objects are untouched. The ceremony script is not itself an installed object:
nothing under `/usr/lib/kyri` or `/usr/libexec` is a copy of it.

```
RUNTIME_DEPLOYMENT_CEREMONY_REQUIRED   NO
HELPER_DEPLOYMENT_CEREMONY_REQUIRED    NO
```

`--install` was **not** re-run and is not authorised. What did change is the
ceremony's `--verify-installed` **attestation**, which now reads the invocation
store. Re-running it is an operator confirmation, not a deployment (§8).

## 6. The corrected check, dry-run against production read-only

The rule was executed against the real store, unprivileged, writing nothing:

```
STORE ok
ENTRY  INVOCATION CINV-000001.yaml
RECORD INVOCATION CINV-000001 /data/kyri/capability-runtime/capability-invocations/CINV-000001.yaml
SEQUENCE INVOCATION 1     NEXT INVOCATION CINV-000002
SEQUENCE RESULT     0     NEXT RESULT     CRES-000001

freshness=installed -> ok  the invocation history at /data/kyri/capability-runtime
                           carries all 1 reviewed record(s) unchanged;
                           1 invocation(s), 0 result(s), CINV-000002 unspent
freshness=reviewed  -> ok  the invocation history is exactly the reviewed one
```

`validate_store` reports **no findings**. Measured directly:

```
CINV_COUNT                       1
CRES_COUNT                       0
CINV-000001 sha256               1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV_NEXT                        CINV-000002        unspent
CINV_000001_FINAL_CLASSIFICATION UNRESOLVED
CINV_000001_RESUME_AUTHORISED    NO
```

`CINV-000001` is byte-identical to its immutable digest and was not touched by
this checkpoint.

## 7. Validation

```
bb-helper-ceremony      PASS  69 assertions  (52 before, 17 added)
helper-ceremony (AX)    PASS
generation15-installer  PASS
capability-runtime      PASS
capability-invoke-preflight        PASS
capability-execution-helper-coherence PASS
capability-execution-helper-policy    PASS
capability-result-contract            PASS
test-static / test-docs-static        PASS
shellcheck              clean

HOST-ONLY SUITES        26 PASS   3 SKIP   0 FAIL   (clean serial run, 29 declared)
LOCAL_QUICK             PASS
LOCAL_FULL              PASS
GITHUB CI               6/6 green   (CI, CodeQL, Gitleaks, Semgrep, ShellCheck, Trivy on e4a4573)
CLEAN CLONE VERIFY      PASS  69 assertions from a fresh clone of e4a4573
```

The three SKIPs are the declared ones: `g61-verification`,
`profile-transport` and `transition-action` report `HOST_ONLY_SKIP`.

## 8. Operator items

Both are read-only. Neither is a deployment and neither is claimed above.

```bash
# 1. The corrected attestation, against production. It should pass and its
#    invocation-history line should read
#    "carries all 1 reviewed record(s) unchanged; 1 invocation(s), 0 result(s),
#     CINV-000002 unspent".
sudo bash /opt/schott-platform/provisioning/execution/install-g11-bb-helpers.sh --verify-installed

# 2. Generation 15 still verifies.
sudo bash /opt/schott-platform/provisioning/execution/install-generation-15.sh --verify-installed
```

## 9. Follow-up recorded, not solved here

- `store_fingerprint` fingerprints the authority, Fabric and Trust roots but not
  the Capability Runtime store, so "this ceremony wrote no invocation record" is
  argued rather than measured. Narrow, and out of scope for this correction.
- The lifecycle-journal signature of a lost supervised execution stays with the
  execution-safety gate (§2).

## 10. Current Fabric, read only

Measured after the gates above went green. Nothing was written.

```
head advertisement   CADV-000005 is NOT written; the head is CADV-000004  (supersedes CADV-000003)
head instance        CINST-000003  (supersedes CINST-000002, advertisement CADV-000004)
head route           CROUTE-0003   (supersedes CROUTE-0002, route_version 3, candidate CINST-000003)
selection history    CSEL-000001, CSEL-000002        neither carries a supersedes field
fabric validate      status reported, findings 0
counts               CADV 4  CINST 3  CROUTE 3  CSEL 2  CAPDEF 1  CCON 1  CPKG 1  CHOST 1

newest Fabric path   2026-09-03 18:11:44  capability-selections/CSEL-000002.yaml
nothing under /var/lib/kyri/fabric has been written since CSEL-000002
```

**Both aggregates are byte-identical to BB-R**, computed with the recipe G11-BA
recorded (`find … -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum`):

```
fabric  7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96   unchanged
trust   53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   unchanged

FABRIC_UNEXPECTED_MUTATION  NO
TRUST_UNEXPECTED_MUTATION   NO
```

**The lease is expired**, and only the clock changed. `compute-eligibility` for
`CINST-000003`, run twice against the live store:

| evaluated at | verdict |
| --- | --- |
| `2026-09-06T11:00:00-05:00` (inside the old window) | **eligible**, twelve of twelve conditions met |
| `2026-09-06T19:41:45-05:00` (now) | **not eligible** — `ELIG-6 advertisement-not-fresh`, `ELIG-7 admission-window-expired` |

`CADV-000004.valid_until` and `CINST-000003.admitted_until` are both
`2026-09-06T12:02:14-05:00`. Ten of twelve conditions still hold; the two that do
not are the two the clock governs.

```
CURRENT_FABRIC_ELIGIBILITY  FAIL
CURRENT_LEASE_STATE         EXPIRED
```

`CSEL-000001` and `CSEL-000002` both being unsuperseded is not a fork — a
selection carries no `supersedes` field, and none of the three (including the
prepared `CSEL-000003`) has one. Route-head movement has not invalidated either
historical selection; eligibility is re-evaluated at use, which is what the
table above just did.

**Next identities, taken from the live sequence authority, not guessed:**

```
capability-advertisement  count 4   next CADV-000005
capability-instance       count 3   next CINST-000004
capability-route          count 3   next CROUTE-0004
capability-selection      count 2   next CSEL-000003
```

## 11. The fresh renewal — prepared, not authorised

Proven end to end against a **throwaway copy** of the live Fabric and Trust
stores. **No production Fabric record was written and none is authorised.**

### 11.1 The chain, and the scope carried forward unchanged

```
CADV-000005  supersedes CADV-000004   valid_until    2026-09-10T19:45:00-05:00
CINST-000004 supersedes CINST-000003  admitted_until 2026-09-10T19:45:00-05:00  advertisement CADV-000005
CROUTE-0004  supersedes CROUTE-0003   route_version 4   candidate_instances [CINST-000004]
CSEL-000003  request class only; the route is resolved at selection time
```

Scope is neither narrowed nor widened: `CAPDEF-0001`, operation `execute`,
classification `internal`, target `HOST-0001`, locality `local-only`,
`CCON-0001` at `1.0.0`, host `CHOST-0001`, package `CPKG-0001`, trust
`TREC-000001` / `TREC-000002`, resource profile `x86-64`.

The window is a fresh 96 hours, matching the bound G11-AY-A2 reviewed for
`CADV-000004`. The expired timestamps are not reused. `admitted_until` is set
**equal to** the advertisement's own `valid_until` and must be read back from the
written `CADV-000005`, not recomputed.

### 11.2 The four frozen inputs, with their digests

Each is the exact operator input object, and each carries the request digest the
live or staged preflight reported.

| destination | input sha256 | bytes | request digest |
| --- | --- | --- | --- |
| `/etc/kyri/fabric/cadv-000005.json` | `5d16ca93dae33c10c72398b34649f6112e0a7056cb2f7586f492cf6ce876f8a1` | 673 | `sha256:df41bd94ed09a16476bc5cc199405d0207a0ef273a5e4d9d1a54079be28e3a27` |
| `/etc/kyri/fabric/cinst-000004.json` | `6ac02e0c14451e544dec255e2dfaf06f5c44687fd6cf41bf571d76742eb96215` | 1269 | `sha256:e9a3d1a5b8ac8184c46ed10d01aa487d0e59e353e13ad2a332a2b9e1b26f32dd` |
| `/etc/kyri/fabric/croute-0004.json` | `12987fb0b22ed124257c135e2be0e114b12f4ec870d53c7ec3991e7d4c0b74fc` | 678 | `sha256:c81a825f549f337abe384471edc25559c1f930d56bebbdd9f1df7161d66be64b` |
| `/etc/kyri/fabric/csel-000003.json` | `040bfe4e03906f9764e086bbfe51ca85e7b37168f4d76e6100bf6b08b843a417` | 605 | `sha256:f3ec942fbea11a5d28804d155e87e0a41fd9b9a87a962fb8aa02fa27e846840d` |

Ownership and mode follow the released convention for this directory:
`root:cschott`, `0640`, installed fail-if-exists.

**The `CADV-000005` request digest was confirmed against production, read-only**
— `would_accept: true`, `mutated: false`, `predicted_record_id: CADV-000005`,
`destination_exists: false`, digest `df41bd94…` — and the fixture write returned
the same digest. The other three cannot be preflighted against production yet,
because each depends on a predecessor that does not exist there.

```json
{
  "request_id": "g11bbs-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000004",
  "actor": "CHOST-0001",
  "recorded_at": "2026-09-06T19:45:00-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": ["1.0.0"],
  "advertised_resource_profile": {"architecture": "x86-64"},
  "observed_at": "2026-09-06T19:45:00-05:00",
  "valid_until": "2026-09-10T19:45:00-05:00",
  "supersedes": "CADV-000004",
  "provenance": {"class": "declared",
                 "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
                 "recorded_at": "2026-09-06"}
}
```

The remaining three are exactly the accepted `CINST-000003` / `CROUTE-0003` /
`CSEL-000002` shapes with the chain and window advanced:

```json
{
  "request_id": "g11bbs-admit-instance-cpkg-0001-chost-0001-cadv-000005-supersedes-cinst-000003",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-09-06T19:50:00-05:00",
  "evaluated_at": "2026-09-06T19:50:00-05:00",
  "capability_id": "CAPDEF-0001",
  "capability_package_id": "CPKG-0001",
  "capability_host_id": "CHOST-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": ["1.0.0"],
  "verified_resource_profile": {"architecture": "x86-64"},
  "admission_decision_id": "eng-0005-cinst-000004-admission",
  "package_trust_record_id": "TREC-000002",
  "host_trust_record_id": "TREC-000001",
  "advertisement_id": "CADV-000005",
  "supersedes": "CINST-000003",
  "admission_scope": {
    "permitted_capabilities": ["CAPDEF-0001"],
    "permitted_operations": ["execute"],
    "permitted_data_classifications": ["internal"],
    "permitted_targets": ["HOST-0001"]
  },
  "admitted_at": "2026-09-06T19:50:00-05:00",
  "admitted_until": "2026-09-10T19:45:00-05:00",
  "provenance": {"class": "declared",
                 "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
                 "recorded_at": "2026-09-06"}
}
```

```json
{
  "request_id": "g11bbs-create-route-capdef-0001-ccon-0001-cinst-000004-supersedes-croute-0003",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-09-06T19:55:00-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": ["1.0.0"],
  "locality": "local-only",
  "candidate_instances": ["CINST-000004"],
  "data_classification": "internal",
  "route_version": 4,
  "supersedes": "CROUTE-0003",
  "provenance": {"class": "declared",
                 "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
                 "recorded_at": "2026-09-06"}
}
```

```json
{
  "request_id": "g11bbs-select-capdef-0001-ccon-0001-internal-local-only-host-0001-croute-0004",
  "actor": "primary-platform-operator",
  "recorded_at": "2026-09-06T20:00:00-05:00",
  "evaluated_at": "2026-09-06T20:00:00-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": ["1.0.0"],
  "data_classification": "internal",
  "locality": "local-only",
  "local_node_identity": "HOST-0001",
  "provenance": {"class": "declared",
                 "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
                 "recorded_at": "2026-09-06"}
}
```

The selection body names no `route_id`; it names a request class, which is why
§11.4 matters.

### 11.3 Each stage refuses without its exact fresh predecessor

Every row is a rehearsal against a store rewound to the named stage. Nothing was
mutated by any of them.

| stage | input | `would_accept` | reason |
| --- | --- | --- | --- |
| S0 heads | the reviewed `CADV-000005` | **true** | control |
| S0 | `CADV` superseding the already-superseded `CADV-000003` | false | `renewal-predecessor-not-current` |
| S0 | `CADV` whose window closes before it opens | false | `invalid-validity-window` |
| S0 | `CINST-000004` before `CADV-000005` exists | false | `unresolved-reference` |
| S0 | `CROUTE-0004` before `CINST-000004` exists | false | `unresolved-reference` |
| S1 `CADV-000005` written | the reviewed `CINST-000004` | **true** | control |
| S1 | `CINST` naming the superseded `CADV-000004` | false | `advertisement-record-superseded` |
| S1 | `admitted_until` **one second** past the advertisement window | false | `admission-window-exceeds-advertisement` |
| S1 | `CINST` superseding the already-superseded `CINST-000002` | false | `supersedes-already-superseded` |
| S2 `+CINST-000004` | the reviewed `CROUTE-0004` | **true** | control |
| S2 | `CROUTE` superseding the already-superseded `CROUTE-0002` | false | `supersedes-already-superseded` |
| S2 | `CROUTE` at `route_version` 3 | false | `invalid-route-version` |
| S3 `+CROUTE-0004` | the reviewed `CSEL-000003` | **true** | control |

The G11-AG structural bound is refused **at one second**. There is no tail.

### 11.4 Two things the engine will NOT catch, stated rather than hidden

**A route may name a superseded instance.** Rehearsed at S2 with
`candidate_instances: [CINST-000003]` — the superseded predecessor — the engine
returns `would_accept: true`. The ceremony must therefore not rely on it: the
route is written only after `CINST-000004` exists, and step G reads the written
`CROUTE-0004.candidate_instances` back and requires exactly `[CINST-000004]`.
This ceremony does not exercise the ambiguity; it is ordered around it.

**A selection binds the route at selection time, and a premature one is
accepted.** Run against a throwaway copy of the live store — route head still
`CROUTE-0003` — the reviewed `CSEL-000003` body is **accepted** and writes:

```
selection_id           CSEL-000003
route_id               CROUTE-0003          <- the stale head
route_version          3
selected_instance_id   null                 <- selects nothing
request_digest         sha256:f3ec942f…846840d   <- identical to the correct one
```

The identity is spent, the selection selects nothing, and **the request digest
cannot witness which route it bound**, because it covers the caller's inputs and
not the resolved route. `CSEL_PREPARATION = DEFERRED_UNTIL_ROUTE_WRITE`, exactly
as G11-AZ-A ruled for `CSEL-000002`.

**Scope widening is accepted at admission.** An input adding `administer` to
`permitted_operations` rehearsed `would_accept: true`. Carried forward, not
solved here, and the frozen input pins the accepted scope exactly:

```
SCOPE_INTERSECTION_ESCALATION       NO
SCOPE_INTERSECTION_SILENT_NARROWING YES
FOLLOW_UP_REQUIRED                  YES
```

### 11.5 The completed chain, in fixture

```
fabric validate           status reported, findings 0
counts                    CADV 5  CINST 4  CROUTE 4  CSEL 3
CSEL-000003               route CROUTE-0004, route_version 4, selected_instance CINST-000004
CSEL-000001, CSEL-000002  byte-identical to production; neither carries supersedes
```

Eligibility of `CINST-000004`, from the released calculation:

| evaluated at | verdict |
| --- | --- |
| `2026-09-06T20:05:00-05:00` | eligible |
| `2026-09-10T19:44:59-05:00` | eligible |
| `2026-09-10T19:45:01-05:00` | not eligible — `advertisement-not-fresh`, `admission-window-expired` |

### 11.6 Ceremony order, and the rollback position

```
A  freeze cadv-000005.json       -> B  preflight the frozen input   -> C  write CADV-000005   -> D  verify
E  freeze cinst-000004.json, admitted_until READ BACK from the written CADV-000005
                                 -> F  preflight                    -> G  write CINST-000004  -> H  verify
I  freeze croute-0004.json       -> J  preflight                    -> K  write CROUTE-0004   -> L  verify
                                                                       and read candidate_instances back
M  freeze csel-000003.json       -> N  preflight                    -> O  write CSEL-000003   -> P  verify
```

Each write is its own authorised step, and each is preceded by a preflight whose
request digest must equal the one in §11.2. **Read `would_accept`, not
`outcome`** — `outcome` reads `preflight` whether the rehearsal accepted or
refused.

**There is no rollback.** The Fabric store is append-only and its writers offer
no delete, no overwrite and no retraction; `write_atomic` refuses an existing
record outright. Recovery from a wrong record is a *further governed write* —
a superseding record and a fresh identity — never an edit. That is why every
stage is frozen, digest-pinned and rehearsed first, and why the selection is
deferred: an identity spent wrongly cannot be reclaimed. A partial chain
(`CADV-000005` written, the rest not) is a **safe** resting state: the head is
fresh, nothing selects it, and `CINV-000002` cannot proceed because no selection
names it.

**Nothing under `/etc/kyri/fabric` or `/var/lib/kyri/fabric` was written by this
checkpoint.** The four bodies above exist only in this report and in a scratch
directory outside the repository.

```
FRESH_FABRIC_RENEWAL_PREPARED    YES
FRESH_FABRIC_RENEWAL_AUTHORISED  NO
FABRIC_MUTATION                  NONE
```

## 12. Next

The fresh Fabric chain gets its own acceptance checkpoint, and `CINV-000002` is
not prepared here — no invocation input is created and no invocation sequence is
advanced.

```
FABRIC_RENEWAL_AUTHORISED      NO
PRODUCTION_INVOKE_AUTHORISED   NO
CINV_000001_RESUME_AUTHORISED  NO
CINV_000002_PREPARED           NO
CINV_000002_SPENT              NO
```
