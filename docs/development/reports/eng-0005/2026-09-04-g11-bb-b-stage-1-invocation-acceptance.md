# ENG-0005 G11-BB-B — Stage 1 acceptance, `CINV-000001`

**Status: Stage 1 ACCEPTED.** `CINV-000001` exists, is immutable, and binds the
expected authority. No result, no handoff, no lifecycle authorisation, no
privileged execution, no container. Stages 2 and 3 remain unauthorised.

Follows **[G11-BB-A](2026-09-04-g11-bb-a-first-controlled-invoke-preparation.md)**,
whose §13 authorised Stage 1 only.

Branch `arch/eng-0005-execution-transition`, HEAD `f8ba25e`.

---

## 1. The record, read from the store

`/data/kyri/capability-runtime/capability-invocations/CINV-000001.yaml` —
`cschott:cschott 0600`, **985 bytes**.

```
CINV_SHA256 = 1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
```

**This digest is the immutability authority for Stages 2 and 3.** `CINV-000001`
must still carry it after `authorise-launch` and after `execute`.

```
CINV_COUNT = 1     CRES_COUNT = 0
```

Exactly one invocation record exists, and it is the expected one.

### Bound authority, verified from the stored record

| required | stored | |
| --- | --- | --- |
| selection | `CSEL-000002` | ✓ |
| instance | `CINST-000003` | ✓ |
| package | `CPKG-0001` | ✓ |
| operation | `execute` | ✓ |
| invocation identity | `g11bb-first-controlled-invoke` | ✓ |
| request identity | `g11bb-first-production-invoke` | ✓ |
| artifact digest | `sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e` | ✓ |
| payload digest | `sha256:0b62b1012c0b6861f33a78737eeeeda671c4a21891a327fd8ad0526bb584a3ec` | ✓ |
| binding digest | `sha256:33c31404a06cd91259ce983264a324a83d0cb0ede79ebe9e3310392280c7b2a5` | ✓ |

Also stored and derived rather than supplied: `contract_id: CCON-0001`,
`capability_id: CAPDEF-0001`, `effect_class: computational`,
`actor: primary-platform-operator`, `schema_version: 2`,
`requested_at: 2026-09-04 19:30:54-05:00`,
`staged_path: …/staging/tree-sha256-6f2282c5…`,
`evidence: {actor, outcome, request_id, selection_id}`.

### Fields deliberately absent at this stage

```
adapter_identity   null      ← correct; see §2
result_record_id   absent
```

**No implementation/CIMP field exists on the invocation schema at all.** The
stored record has no `implementation_id`, `cimp` or equivalent. `CIMP-000001` is
bound at Stage 2, where `--cimp` is an argument to `authorise-launch`, and it is
carried in the launch projection and the handoff rather than written back onto
the invocation. BB-A §13.2 anticipated this; the stored record confirms it.

## 2. A correction to BB-A §13.2

BB-A predicted the stored record would carry `evidence.outcome: prepared`. **It
carries `evidence.outcome: execution-prepared`.**

Both are correct and they are different constants for different surfaces:

```
tools/capability/evidence.py:56   OUTCOME_PREPARED = "execution-prepared"   ← stored evidence
                                  STATUS_PREPARED  = "prepared"             ← CLI status field
```

The CLI reported `status: prepared`; the record stores
`evidence.outcome: execution-prepared`. The prediction named the CLI constant
where it should have named the record constant. The record is right, and
`execution-prepared` is the value Stage-2/3 checks must expect — `inspection.py`
confirms the invocation *"stays `execution-prepared`"* as its pre-execution
attempt record.

`adapter_identity: null` was predicted correctly and holds.

## 3. Payload digests — raw file is not the governed digest

The reviewer flagged this, and source settles it. `payload.py` binds the digest
*"over the **canonical** bytes — not the source spelling, not a pathname, not a
later copy."*

Recomputed through the released module:

```
raw file bytes        197   sha256  db34cc9fb4ad172847f9230c15da50c6bed8d6a0c3988e2645f77314c5ee35b2
canonical bytes       168   sha256  0b62b1012c0b6861f33a78737eeeeda671c4a21891a327fd8ad0526bb584a3ec
identical?            False

stored payload_digest       sha256:0b62b1012c0b6861f33a78737eeeeda671c4a21891a327fd8ad0526bb584a3ec   MATCH
```

**They are intended to differ.** The operator's `db34cc9f…` is the file as
written, with its indentation and key order; the governed digest is over the
canonicalised document, so two files differing only in whitespace or key order
bind identically and two differing in value do not. `db34cc9f…` must never be
compared against a governed `payload_digest`.

## 4. Sequence and staging

```
sequences/capability-invocation.seq   = 1     (2 bytes, "1\n")
sequences/capability-result.seq       ABSENT
```

The invocation sequence was **created**, not advanced — none existed before.
No result sequence exists, which is correct: nothing has written a result.

**Staged package:**

```
d  staging/tree-sha256-6f2282c5…9a8e/            cschott:cschott 0500
f  staging/tree-sha256-6f2282c5…9a8e/main.py     cschott:cschott 0400  8192 bytes
```

The staged `main.py` is **byte-identical** to the governed artifact:

```
683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd   staged main.py
683e25ed8cb317acd21e92b4706653454035f12320e0701ddabcb09eb688f7fd   /var/lib/kyri/artifacts/…/1.0.0/main.py
```

The directory name encodes the tree digest `6f2282c5…`, which matches
`CPKG-0001`'s manifest `package_tree_sha256` and the `artifact_digest` on the
record. The staged tree is read-only to its owner (`0500` / `0400`) — staged for
execution, not for editing. `STAGED_TREE = PASS`.

## 5. Exact Stage-1 mutation, against `PRE_BB_BASELINE`

Enumerated against the seventeen baseline objects recorded in BA §0.2
(`36a13cd7…d5f5d1a6`):

```
CREATE  f  capability-invocations/CINV-000001.yaml
CREATE  f  sequences/capability-invocation.seq
CREATE  d  staging/tree-sha256-6f2282c5…9a8e/
CREATE  f  staging/tree-sha256-6f2282c5…9a8e/main.py

REMOVE     (none)
```

**Four creations, nothing removed, and every pre-existing baseline object
unchanged in content:**

```
execution/cadm-counter               2f1ab4cf0adb400e…   unchanged
execution/cmut-counter               70cad16dcf08fa19…   unchanged
sequences/invocation_identity.lock   e3b0c44298fc1c14…   unchanged (taken and released)
```

That is exactly the permitted set derived in BB-A §13.3. The
`initialized-empty` scaffolding is pre-existing and is not Stage-1 mutation.

## 6. Nothing executed

```
CRES record                    none          capability-results/ empty
capability-result.seq          absent
handoff entries                0             /data/kyri/capability-handoff
execution/transitions          0
execution/state                0             ← no lifecycle transition recorded
execution/locks                0
execution/mutations            0
execution/admin-records        0
execution/inspection-audit     0
execution/quarantine-releases  0
execution/quarantine-reservations 0
quarantine/                    0
quota counters                 cadm 000000   cmut 000000000000   unmoved
```

```
HANDOFF_PRESENT            NO
LAUNCH_AUTHORIZED          NO
PRIVILEGED_HELPER_EXECUTED NO
CONTAINER_EXECUTED         NO
```

**No lifecycle state exists yet.** `execution/state` is empty, so `CINV-000001`
has not entered `RESERVED` or `LAUNCH_AUTHORIZED` — consistent with Stage 2 not
having run. The privileged helpers were not executed: no transition record, no
handoff, and `invoke` reaches no subprocess at all.

**Containers.** The operator attested no `kyri-CINV-*` container before Stage 1,
and Stage 1 cannot create one — it never reaches the launcher. The coordinator
cannot enumerate Podman and must not gain that authority, so no coordinator-side
container check was attempted. A read-only operator check is **not required**
before Stage 2; it is required after Stage 3.

## 7. Immutability

```
CINV-000001 before this inspection   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV-000001 after  this inspection   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
```

`CINV_IMMUTABLE = YES`. Every inspection in this report was read-only.

## 8. Unchanged planes

| plane | value | |
| --- | --- | --- |
| `[fabric]` | `7c53efcdffdee337fe3ca94b71a3085bf53b4474f19482a523d263feaa6c8e96` | unchanged |
| `[trust]` | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | unchanged |
| `[libexec]` | `489f108dfd93854023817a7339e34cc8ebc9c29b810223381d2b2343952bea86` | unchanged |
| `[runtime-lib]` | `5bf50db23f086364e594f15c8390e9aff198b2825e681ee2aca2a40b7c133b84` | unchanged |
| `[identity]` | `bf825c7c380082dd21b574ba82d4e507392485ef1ba1b19c1fd7dc1f5fa09f61` | unchanged |
| `[sudoers]` | `f837d5923a719af50944c990569a7475c21628674184d8599b262150495da1a9` | unchanged |

Individual Fabric records, all unchanged:

```
CADV-000004   965499a3dace61d620b3d6a00bbc59a0655bceaeedcdd0ca879e8245574af708
CINST-000003  5b83135db80693e430d92f36a04fea837b354949a2a4bee18170da73f70c21d1
CROUTE-0003   18d54f8a6f8201362a827c940bee3d42ea8cd792d69005a5ed96a3bdff8bb22a
CSEL-000002   d344c89729ebbfed61a928881c1933deb235b77df19031469085c49d634a4ccb
```

`helpers: compatible 8 0`. `/etc/sudoers.d/kyri-exec-verify` still **absent**.

**A Fabric-plane invocation writes nothing to the Fabric.** The Capability
Runtime is a separate store, which is why `[fabric]` is untouched by an
invocation that binds four Fabric records.

## 9. Time

```
host now                     2026-09-04T19:33:35-05:00
CADV-000004.valid_until      2026-09-06T12:02:14-05:00   inside: True
CINST-000003.admitted_until  2026-09-06T12:02:14-05:00   inside: True
WINDOW_REMAINING             40h 28m   (145718 s)        expired: False
current eligibility          true, unmet []
```

Ample for Stages 2 and 3 with room for review and, if needed, recovery.

## 10. Stage 2 — what it will write, derived from source

From `authorise_launch` in `tools/capability/execution/launch.py`. The ruled
order is *"validate the prepared invocation, derive the deterministic profile,
derive the projection, commit the lifecycle transition, journal the projection,
publish the handoff, verify the materialisation."*

| step | effect |
| --- | --- |
| validate prepared invocation | reads `CINV-000001`; refuses unless it is prepared |
| commitment | `commitment_digest(record.binding_digest)` — from the binding already committed |
| payload re-presentation | `invocation_payload_digest(document)` compared against the record's `payload_digest`; a different payload *"may not borrow this authorisation"* |
| package | `validate_package(artefact_fd, entrypoint="main.py")` |
| profile | re-derived from the implementation authority via `authorise_implementation(…, cimp=CIMP-000001)`; *"not carried across from preparation"* |
| capacity | `capacity_module.reserve(execution_root, CINV-000001)` |
| lifecycle | `state_module.transition(RESERVED → LAUNCH_AUTHORIZED)` under `execution/` |
| projection | `_commit_projection` journals the launch record |
| handoff | `publish_handoff(handoff_root, …)` then `_verify_handoff` |

**Expected new state:** entries under `execution/state`, `execution/transitions`
and the capacity reservation; a journalled projection; and a handoff under
`/data/kyri/capability-handoff/`. Expected output: `rc=0`,
`lifecycle_state: launch_authorized`, `handoff_published: true`,
`resumed: false`, plus `profile_digest` and `commitment_digest`.

**`CINV-000001` must remain byte-identical at `1dcef40d…d6cfaaa`.**
`authorise_launch` reads the invocation and never writes it; the authorisation
lives in the projection and the handoff, beside the record rather than on it.

**Two payload digest domains, and both were checked in advance.** Source is
explicit that they *"answer different questions"* and are never compared with
each other: `invocation_payload_digest(document)` guards the invocation binding,
`payload_binding.digest` goes to the handoff and profile. Verified against the
live payload:

```
invocation_payload_digest(document)   sha256:0b62b101…584a3ec   == stored payload_digest   ✓
payload_binding.digest (handoff)      0b62b101…584a3ec
```

The Stage-2 payload gate will pass with the **same** payload file Stage 1 used.
It must not be edited, moved or re-created — `require_single_link` and the
digest gate both bind it.

## 11. Standing

```
BB_STAGE1                     ACCEPTED
CINV_ID                       CINV-000001
CINV_SHA256                   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa
CINV_COUNT                    1
CRES_COUNT                    0
INVOCATION_SEQ                1
RESULT_SEQ                    ABSENT
STAGED_TREE                   PASS
CINV_IMMUTABLE                YES
HANDOFF_PRESENT               NO
LAUNCH_AUTHORIZED             NO
PRIVILEGED_HELPER_EXECUTED    NO
CONTAINER_EXECUTED            NO
FABRIC_UNCHANGED              YES
TRUST_UNCHANGED               YES
CURRENT_ELIGIBILITY           PASS
WINDOW_REMAINING              40h 28m
AUTHORISE_LAUNCH_AUTHORISED   NO
EXECUTE_AUTHORISED            NO
```

## 12. Next

1. Reviewer accepts this Stage-1 evidence.
2. Operator runs **Stage 2 only** — the `authorise-launch` block reviewed in
   BB-A §10, reproduced unchanged, using the existing `CINV-000001` and the same
   payload file. No second `CINV` is allocated; `authorise-launch` takes a
   `--cinv` and has no allocation path.
3. Independent Stage-2 verification, including that `CINV-000001` still digests
   to `1dcef40d…d6cfaaa`.
4. Only then Stage 3 (`execute`), which is where the first `CRES` and the first
   container appear.
