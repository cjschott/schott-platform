# ENG-0005 G11-BB-C — Stage 2 acceptance, launch authorisation

**Status: Stage 2 ACCEPTED.** `CINV-000001` is `launch_authorized`, the handoff
is published and verified, and the sealed profile and commitment digest were
both reproduced independently from the released source. `CINV-000001` is
byte-identical to its Stage-1 baseline. No result, no execution, no container.
Stage 3 remains unauthorised.

Follows **[G11-BB-B](2026-09-04-g11-bb-b-stage-1-invocation-acceptance.md)**.

Branch `arch/eng-0005-execution-transition`, HEAD `4059abd`.

---

## 1. Immutability held

```
CINV-000001 Stage-1 baseline  1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV-000001 after Stage 2     1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
```

`CINV_IMMUTABLE = YES`. `authorise_launch` reads the invocation and never writes
it; the authorisation lives in the projection and the handoff, beside the record
rather than on it — exactly as BB-B §10 derived.

```
CINV_COUNT = 1     CRES_COUNT = 0
capability-invocation.seq = 1     capability-result.seq  ABSENT
```

## 2. Lifecycle

Read from the transition journal, not from the CLI:

```
execution/transitions/CINV-000001.000001
  {"cinv":"CINV-000001","previous":null,"schema_version":1,"sequence":1,"state":"reserved"}
execution/transitions/CINV-000001.000002
  {"cinv":"CINV-000001","previous":"reserved","schema_version":1,"sequence":2,"state":"launch_authorized"}
```

`LIFECYCLE_STATE = launch_authorized`, reached through `reserved`, each
transition naming its predecessor. Sequence 1 has `previous: null`, which is a
first run — `RESUMED = NO`, agreeing with the CLI's `resumed: false`.

The journalled projection:

```
execution/CINV-000001/launch-authorisation   (326 bytes, 0600)
{"cimp":"CIMP-000001","cinv":"CINV-000001",
 "commitment_digest":"33c31404a06cd91259ce983264a324a83d0cb0ede79ebe9e3310392280c7b2a5",
 "handoff_root":"/data/kyri/capability-handoff",
 "lifecycle_state":"launch_authorized",
 "profile_digest":"65730fef5a5285a24dc3ea82838e5fc3dad09be3ab075bd70854eb058c0da1e3",
 "profile_schema_version":1}
```

**`execution/state` is empty and that is not a defect.** Lifecycle state is
derived from the append-only transition journal rather than stored as mutable
current-state; the directory exists for the store's layout. The state is read
from the last transition, which is what `current_state` consults.

## 3. The commitment digest, reproduced from source

Not accepted from the CLI. Recomputed through the released
`launch.commitment_digest`:

```
CINV-000001.binding_digest   sha256:33c31404a06cd91259ce983264a324a83d0cb0ede79ebe9e3310392280c7b2a5
commitment_digest(…)               33c31404a06cd91259ce983264a324a83d0cb0ede79ebe9e3310392280c7b2a5
Stage-2 reported                   33c31404a06cd91259ce983264a324a83d0cb0ede79ebe9e3310392280c7b2a5
```

`COMMITMENT_VERIFICATION = PASS`.

**The commitment equals the binding digest by ruling, not by accident.** Source
states it plainly — *"Ruling A: the commitment **is** the prepared invocation's
binding digest, carried in the bare form the privileged parser accepts. The
binding already commits to the invocation identity together with the governed
selection, instance, package, actor and payload, so deriving a second digest
over the same facts would be a second answer to one question."* The only
difference is the `sha256:` prefix, stripped **after** being proved present.

So the commitment provably binds the same execution material Stage 1 recorded:
it *is* that material's digest.

## 4. The sealed profile, verified independently

`/data/kyri/capability-handoff/CINV-000001/profile` — `cschott:cschott 0444`,
**1159 bytes**, `65730fef5a5285a24dc3ea82838e5fc3dad09be3ab075bd70854eb058c0da1e3`.

Verified through the released implementation, not by trusting the CLI:

```
parse_canonical_profile(bytes)          OK      — the stored bytes are canonical
fingerprint(profile).profile_digest     65730fef5a5285a24dc3ea82838e5fc3dad09be3ab075bd70854eb058c0da1e3
Stage-2 reported profile_digest         65730fef5a5285a24dc3ea82838e5fc3dad09be3ab075bd70854eb058c0da1e3   MATCH
canonical_profile(profile) == stored    True    — re-serialises to the same bytes
verify_governed_policy(profile)         PASS
```

`PROFILE_VERIFICATION = PASS`. The round-trip matters: the stored bytes parse as
canonical *and* re-serialise identically, so the digest is over the bytes that
are actually on disk.

### What the profile binds

```
cinv                CINV-000001
cimp                CIMP-000001
oci_image_id        5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
package_digest      6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
package_entrypoint  main.py
payload_digest      0b62b1012c0b6861f33a78737eeeeda671c4a21891a327fd8ad0526bb584a3ec
adapter_identity    python-podman-v1
network             none
```

Checked against the governed module constants rather than against expectations
written here:

```
profile.EXECUTION_UID      65532              sealed 65532              match
profile.EXECUTION_GID      65532              sealed 65532              match
profile.NETWORK            'none'             sealed 'none'             match
profile.ADAPTER_IDENTITY   'python-podman-v1' sealed 'python-podman-v1' match
```

Confinement, all present and as governed: `privileged: false`,
`no_new_privileges: true`, `read_only_rootfs: true`, `cap_drop_all: true`,
`dropped_capabilities: ["ALL"]`, `host_network: false`, `host_pid: false`,
`devices: []`, `sockets: []`, `gpu: false`, `pids_limit: 64`,
`timeout_seconds: 30`, `memory_bytes: 268435456`, `cpu_quota_us: 50000`,
`tmpfs_options: ["nodev","noexec","nosuid"]`. Mounts are exactly the three
governed ones: `/kyri/package` (ro), `/run/kyri/input/payload` (ro),
`/kyri/output` (rw).

### Two things the reviewer's list expects that the schema does not carry

Stated rather than inferred, per the instruction not to invent fields.

1. **`CSEL-000002`, `CINST-000003`, `CPKG-0001` and `operation` are not profile
   fields.** Confirmed by attribute check — the profile object has no
   `selection_id`, `instance_id`, `capability_package_id` or `operation`. They
   bind **transitively**: the profile names `CINV-000001`, and `CINV-000001`
   carries all four (BB-B §1). The profile is an execution-shape document, not a
   restatement of the invocation's authority, and duplicating them would be a
   second answer to a settled question — the same reasoning Ruling A gives for
   the commitment.

2. **`execution_uid`/`execution_gid` in the profile are `65532:65532`, the
   *container* identity — not the host worker identity.** The host execution
   identity `kyri-capability 999:987` lives in
   `/etc/kyri/execution-identity.json` and is unchanged. The two are different
   namespaces that happen to share a field name, and reading the profile's
   `execution_uid` as the host uid would be wrong. Both are correct here:
   container `65532:65532`, host `999:987`.

`hostname: "trackb"` is the governed `profile.HOSTNAME` constant, not a leak of
the real host name (`schai`).

## 5. Handoff content

```
d  /data/kyri/capability-handoff                      cschott:cschott 0711
d  /data/kyri/capability-handoff/CINV-000001          cschott:cschott 0555
d  …/CINV-000001/package                              cschott:cschott 0555
f  …/CINV-000001/package/main.py                      cschott:cschott 0444  8192
f  …/CINV-000001/payload                              cschott:cschott 0444   168
f  …/CINV-000001/profile                              cschott:cschott 0444  1159
d  …/CINV-000001/out                                  cschott:cschott 0700     (empty)
```

**Package is byte-identical along the whole chain:**

```
683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd  handoff package/main.py
683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd  staged main.py
683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd  governed artifact main.py
```

**Payload is the canonical bytes, and reproduces the governed digest:**

```
handoff payload   168 bytes   0b62b1012c0b6861f33a78737eeeeda671c4a21891a327fd8ad0526bb584a3ec
```

That is the canonical form (168 bytes), not the operator's source file (197
bytes, `db34cc9f…`) — the distinction established in BB-B §3. The handoff
carries what the digest commits to.

**Writability, per the released policy.** Every handoff object is read-only —
directories `0555`, files `0444` — **except `out/`, which is `0700` and empty.**
That is the one governed writable surface, the output mount the profile declares
at `/kyri/output`. `HANDOFF_VERIFICATION = PASS`.

The staged tree under the runtime store is untouched by Stage 2
(`683e25ed…f7fd`), so the handoff is a published copy rather than a move.

## 6. Exact Stage-2 mutation

Relative to the end of Stage 1. The count of `CMUT` records proves nothing on
its own, so each mutation's declared intent was checked against the bytes
actually installed:

| mutation | target | expected sha256 | installed matches |
| --- | --- | --- | --- |
| `CMUT-000000000001` | `execution-transition` `CINV-000001.000001` | `8987403ac7d686f2…` | **YES** |
| `CMUT-000000000002` | `execution-transition` `CINV-000001.000002` | `1277d7049463afa9…` | **YES** |
| `CMUT-000000000003` | `launch-authorisation` `CINV-000001` | `fdce93ae6a23a8aa…` | **YES** |

Each carries `outcome: {"installed": true}`. The mutation counter moved
`000000000000 → 000000000003` — three declared, three installed, three
accounted for, and each verified by digest rather than by count.

**New since Stage 1:**

```
execution/CINV-000001/launch-authorisation      326 bytes  0600
execution/transitions/CINV-000001.000001         89 bytes  0600
execution/transitions/CINV-000001.000002        104 bytes  0600
execution/mutations/CMUT-00000000000{1,2,3}/{intent,outcome}
execution/locks/capacity                          0 bytes  0600
execution/locks/CINV-000001                       0 bytes  0600
/data/kyri/capability-handoff/CINV-000001/…      package, payload, profile, out/
```

`execution/cadm-counter` unchanged at `000000` — no admin record was written.

**Still empty:** `execution/state`, `execution/admin-records`,
`execution/inspection-audit`, `execution/quarantine-releases`,
`execution/quarantine-reservations`, `quarantine/`, `capability-results/`.

## 7. Nothing executed

```
CRES record                    none        capability-results/ empty
capability-result.seq          absent
worker terminal result         none
privileged transition          not executed — no sudo, no helper invocation
reconciliation                 not run
container                      none created
handoff out/                   empty
```

`authorise-launch` *"does not execve"*. The privileged boundary is crossed only
by Stage 3 through `HelperLauncher`, and no transition beyond
`launch_authorized` exists.

**Containers.** Stage 2 cannot create one — it reaches no subprocess. The
operator attested before Stage 1 that only historical `trackb-*` containers
exist and no `kyri-CINV-*` container. A read-only operator check is offered in
§10 as a pre-Stage-3 confirmation. **No coordinator Podman authority was
acquired or attempted.**

## 8. Unchanged authority planes

| plane | digest | |
| --- | --- | --- |
| `[fabric]` | `7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96` | unchanged |
| `[trust]` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | unchanged |
| `[libexec]` | `489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86` | unchanged |
| `[runtime-lib]` | `5bf50db23f086364e594f15c8390e9aff198b2825e681ee2aca2a40b7c133b84` | unchanged |
| `[identity]` | `bf825c7c380082dd21b574ba82d4e507392485ef1ba1b19c1fd7dc1f5fa09f61` | unchanged |
| `[sudoers]` | `f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9` | unchanged |

```
CADV-000004   965499a3dace61d620b3d6a00bbc59a0655bceaeedcdd0ca879e8245574af708
CINST-000003  5b83135db80693e430d92f36a04fea837b354949a2a4bee18170da73f70c21d1
CROUTE-0003   18d54f8a6f8201362a827c940bee3d42ea8cd792d69005a5ed96a3bdff8bb22a
CSEL-000002   d344c89729ebbfed61a928881c1933deb235b77df19031469085c49d634a4ccb
```

`/etc/sudoers.d/kyri-exec-verify` still absent.

## 9. Current standing, re-evaluated

```
host now                     2026-09-04T19:44:28-05:00
CADV-000004.valid_until      2026-09-06T12:02:14-05:00   inside: True
CINST-000003.admitted_until  2026-09-06T12:02:14-05:00   inside: True
WINDOW_REMAINING             40h 17m   (145065 s)        expired: False

current eligibility          true, unmet [], ELIG-1..12
fabric validate              reported, findings 0
trust validate-store         valid true, problems 0
helper compatibility         compatible, 8 declared, 0 blocking
supervision_ready            true
```

**Trust standing, re-read at this instant:**

```
HOST-0001   effective_state trusted   TREC-000001  TDEC-000001  validity_end null
CPKG-0001   effective_state trusted   TREC-000002  TDEC-000002  expires null
```

Both carry scope `capabilities [CAPDEF-0001]`, `operations [execute]`,
`classifications [internal]`, `targets [HOST-0001]`.

**A query that reads alarming and is not.** Asking the trust store for
`CHOST-0001` returns `effective_state: unknown`, `usable: false`, *"no trust
lineage exists for this subject; unknown fails closed"*. That is correct:
`CHOST-0001` is the **Fabric host record**, not a trust subject. The trust
subject is the node identity `HOST-0001`, which `CHOST-0001.node_identity_reference`
names and which `TREC-000001` is keyed on (`subject_id: HOST-0001`,
`subject_type: fabric-node`). The instance cites `TREC-000001`, and that record
is `trusted`. Nothing here is unresolved.

## 10. Optional pre-Stage-3 operator container check

Not required — Stage 2 cannot have created a container — but available if the
reviewer wants the baseline restated immediately before the first execution.
Read-only:

```bash
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
```

Require **no `kyri-CINV-000001` container**. The `trackb-*` containers are
historical test artefacts from roughly three weeks ago and are recorded
separately; they are not invoke residue and must not be removed as part of this
ceremony.

## 11. Stage 3 — expected output, derived from source

From `command_execute` in `tools/capability/cli.py`. **There are two emit shapes
and they carry different fields.**

**Success path** (`execute_supervised` returned a terminal):

```
cinv                        CINV-000001
status                      terminal.status
reason                      terminal.reason
invocation_record_id        CINV-000001
result_record_id            CRES-000001   (expected; derive from the live store)
succeeded                   true|false
result_digest               sha256:…
result_artifact_reference   null          ← by design, see below
disposal_proven             true          ← literal True on this path
```

exit `EXIT_SUCCESS` iff `terminal.succeeded`, else `EXIT_DENIED`.

**Unresolved path** (`SupervisionRefused`):

```
cinv, status "unresolved", reason,
protocol_states [...], worker_reaped, disposal_proven, reconciled,
result_recorded false
```

exit `EXIT_DENIED`. **A refusal writes nothing** — no `CRES` is synthesised.

**A limit the reviewer should know before Stage 3 runs.** `worker_reaped`,
`reconciled` and `protocol_states` appear **only on the unresolved path**. The
success emit does not carry them; it asserts `disposal_proven: true` and nothing
more about the trace. That is not a gap in the evidence — a supervised execution
that could not prove worker reaping or container disposal raises
`SupervisionRefused` and lands on the *other* path — but it does mean those three
fields must not be demanded of a successful Stage-3 JSON. Where the success path
is silent, the evidence comes from the stored `CRES`, from `recover` reporting
ready, and from the operator's container check.

**`result_artifact_reference: null` is correct.** `execute_supervised` passes
`result_artifact_reference=None` literally. Non-null would be the anomaly.

**`result-missing` is a governed outcome, not a ceremony failure.** If the
workload exits zero without a governed result, the released path names it
`result-missing` (`collector.Classification.RESULT_MISSING`,
`records.REASON_RESULT_MISSING`), one of `CCON-0001`'s declared `failure_modes`.
It must be reported as that, with `succeeded: false` — **never as success**.

**The stored `CRES` shape**, from `_result_body`:

```
capability_result_id, invocation_record_id, attempt_number, outcome_class,
reason, result_digest, result_artifact_reference, started_at, ended_at,
recorded_at, kind, schema_version, evidence{actor, outcome}
```

Note it carries **no** selection, instance, package or operation field: the
`CRES` binds to those through `invocation_record_id → CINV-000001`, which
carries all four. Requiring them directly on the `CRES` would fail a correct
record — the same transitive-binding pattern as the profile in §4.

## 12. Recovery boundary — unchanged, restated

If Stage 3 returns `status: unresolved`:

- **Do not re-run `execute`.**
- Use only the governed surface:
  `python3 -m tools.capability.cli recover --expected-uid 1000 --expected-gid 1000`.
  It writes nothing, never touches the invocation record, reconciles the
  container through the privileged reconcile grant, and is idempotent —
  *"Reconciliation treats absence as success."*
- **No manual `podman stop`, `kill` or `rm`.**
- **Do not synthesise a `CRES`.** Leaving the invocation unresolved is the
  honest state and the one the recovery enumeration can still act on.
- Capture the full JSON — `protocol_states`, `worker_reaped`, `disposal_proven`,
  `reconciled` — and escalate.

Also standing: no further sudoers grant, `/etc/sudoers.d/kyri-exec-verify` stays
absent, and the capability-runtime scaffolding is not deleted.

## 13. Standing

```
BB_STAGE2                     ACCEPTED
CINV_ID                       CINV-000001
CINV_SHA256                   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV_IMMUTABLE                YES
CINV_COUNT                    1
CRES_COUNT                    0
LIFECYCLE_STATE               launch_authorized
HANDOFF_PUBLISHED             YES
RESUMED                       NO
PROFILE_DIGEST                65730fef5a5285a24dc3ea82838e5fc3dad09be3ab075bd70854eb058c0da1e3
COMMITMENT_DIGEST             33c31404a06cd91259ce983264a324a83d0cb0ede79ebe9e3310392280c7b2a5
PACKAGE_DIGEST                6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
PAYLOAD_DIGEST                0b62b1012c0b6861f33a78737eeeeda671c4a21891a327fd8ad0526bb584a3ec
PROFILE_VERIFICATION          PASS
COMMITMENT_VERIFICATION       PASS
HANDOFF_VERIFICATION          PASS
FABRIC_UNCHANGED              YES
TRUST_UNCHANGED               YES
CURRENT_ELIGIBILITY           PASS
HELPER_COMPATIBILITY          compatible
SUPERVISION_READY             true
WINDOW_REMAINING              40h 17m
EXECUTE_AUTHORISED            NO
```

## 14. Next

1. Reviewer accepts this Stage-2 evidence.
2. Operator runs **Stage 3 only** — the `execute` block reviewed in BB-A §10.
3. Independent Stage-3 verification: `CINV-000001` still `1dcef40d…d6cfaaa`,
   `CRES-000001` terminal and bound, no orphan container, `recover` ready, all
   authority planes unchanged.
