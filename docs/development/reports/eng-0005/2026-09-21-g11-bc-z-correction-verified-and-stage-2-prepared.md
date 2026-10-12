# G11-BC-Z — CADM-000002 verified, and CINV-000003 Stage 2 prepared

**Date:** 2026-09-21
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `bcde93208226e3a52670e2a645c9bc4c21b9bb58`
**Engineer:** Claude (implementation)
**Status:** OPERATOR ACTION REQUIRED — Stage 2 is prepared and rehearsed, not run. Nothing in production was mutated.

---

## A. The correction, verified independently

Read-only. Measured with the installed runtime, not taken from the acceptance.

| | |
|---|---|
| Runtime aggregate | `76bf8f993c4af1cdce88ecb93d0e72f88177ba56f7e6d407ab4f0166aa0e1cd7` — matches |
| Generation 20 | all five objects at their reviewed digests; library 83 objects |
| `CINV-000001` | `launch_authorized` |
| `CINV-000002` | `abandoned`, and recovery still treats it as closed |
| `CINV-000003` | no execution state |
| Occupancy | **1 of 2** |
| `cadm-counter` / `cmut-counter` | `000002` / `000000000007` |
| `capability-invocation.seq` / `capability-result.seq` | 3 / 1 |
| Transitions / mutations | 5 / 7 |
| `CRES-000002` | absent |

`CADM-000001` is byte-identical to its accepted digests (`abandonment`
`d1307f01…`, `intent` `a7faa2c1…`, `outcome` `07bb889d…`). All four immutable
records are unchanged.

`CADM-000002` carries `intent`, `outcome` and `provenance-correction`
(`47b977d83b164ee9056527d99ec40d995b8e9b26e4b63b992df1ac8da8b0e58e`), and every
field matches the acceptance — `subject_digest` equal to the live
`CADM-000001/abandonment` digest, `effect: retained`, `action_reversed: false`,
`lifecycle_unchanged: true`, `slot_changed: false`, `lifecycle_state: abandoned`,
both evidence references present.

**Mutation accounting, by content.** A copy with `CADM-000002` removed and
`cadm-counter` rewound to `000001`, hashed with the production path prefix,
reproduces

`9374b56870759ebccbbb74a38ada5905bcd5ce3bd1418428b72e148cdc662d68`

exactly. The whole mutation was one administrative record and one counter
increment. Nothing unexplained.

**PROVENANCE_CORRECTION_VERIFIED = PASS.**

## B. Incident closure

1. **Generation 20 installed.** All five objects at their reviewed targets;
   `provenance.py` created; library 82 → 83. Both administrative mutators
   require `--store-root` and report the device and inode they wrote through.
2. **ADR-0016 accepted.** Append-only, subject preserved byte-for-byte, no
   ratification, lifecycle effect standing, `actor` the only correctable field.
3. **The correction ceremony ran** with the installed library and
   `--store-root /data/kyri/capability-runtime` spelled out, and its emitted
   target (`st_dev` 2065, `st_ino` 268436008) matched the inode the ceremony had
   measured for itself.
4. **`CADM-000002` semantics**: the attribution in `CADM-000001` is not truthful
   provenance; the finding is `attribution-not-authorised`; the initiator was an
   `unauthorised-rehearsal-harness`; the effect is retained.
5. **The explicit target fingerprint** is what closed the class of defect that
   caused the incident. It is now checked, not assumed.
6. **Mutation accounting** above.
7. **New runtime aggregate** `76bf8f99…`.
8. **Unchanged**: lifecycle, occupancy 1 of 2, both sequences, `cmut-counter`,
   the transition journal, every `CINV` and `CRES`, `CINV-000003`'s absence of
   execution state.
9. **The incident's provenance is corrected append-only.** The untrue
   attribution is still readable, beside a governed finding about it. Nothing
   was edited, deleted or reversed.
10. **Authenticated actor provenance remains unresolved architectural debt.**
    `actor` is still a caller-asserted string. `CADM-000002`'s own `actor` field
    is asserted in exactly the same way as the one it disputes — which is the
    honest limit of what a correction can do, and is stated in ADR-0016 rather
    than papered over.

## C. CINV-000001

Not reclaimed, and no abandonment ceremony was prepared for it. It remains
`launch_authorized` historical state holding one slot, per the reviewer ruling.

## D. Stage 2, reconstructed from the installed Generation-20 bytes

Read from `/usr/lib/kyri/python`, not from the pre-Generation-20 rehearsal.

**Command**

```
cd /usr/lib/kyri/python && python3 -m tools.capability.cli authorise-launch \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000003 \
  --cimp CIMP-000001 \
  --approved-payload-root /data/kyri/work/g11bcn \
  --payload-file third-invoke.json \
  --package-entrypoint main.py
```

**Expected rc: 0.** Unlike `invoke`, `command_authorise_launch` returns
`EXIT_SUCCESS` on acceptance; rc 1 is a governed refusal and rc 2 is unusable
input.

**Expected JSON** (measured in rehearsal, not predicted):

| field | value |
|---|---|
| `cinv` | `CINV-000003` |
| `cimp` | `CIMP-000001` |
| `lifecycle_state` | `launch_authorized` |
| `profile_digest` | `f6696e0dac6d70fea602897e70adb746ab9f82ddaf94527f674d677d7ace05ee` |
| `commitment_digest` | `6d5a8d9249c7c9407145a69b55748136020a1a696c2e167d879864dc2dc86289` |
| `package_digest` | `6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e` |
| `payload_digest` | `591d4b0d9c81fd5cbb56f7a08a8e9b14ef116c8625b16b19311f75d27d3c59b3` |
| `handoff_published` | `true` |
| `resumed` | `false` |

**Order, from the released bridge:** validate the prepared invocation → derive
the deterministic profile → derive the projection → commit the lifecycle
transition → journal the projection → publish the handoff → verify the
materialisation.

**Capacity.** `reserve` is called only when the invocation has no durable
execution state, which is CINV-000003's case. It refuses when the held count
**reaches** `MAXIMUM_SLOTS`; held is 1 of 2, so one free slot admits it.

**Execution-state writes.** `execution/CINV-000003/` with
`launch-authorisation` (0600), plus `execution/locks/CINV-000003` — an advisory
lock file carrying no durable authority.

**Lifecycle transitions.** Two: `CINV-000003.000001` (`reserved`) and
`CINV-000003.000002` (`launch_authorized`).

**Mutation journal.** **Three** `CMUT`s, not one: one per transition and one for
the launch-authorisation projection. `cmut-counter` `000000000007` →
`000000000010`. This was measured; assuming one would have been wrong.

**Handoff publication.** `/data/kyri/capability-handoff/CINV-000003/` with
`package/` (0555, `main.py` 0444), `payload` (0444), `profile` (0444) and
`out/` (0700); the directory itself 0555.

**Payload verification.** The payload is re-presented as a descriptor,
validated through the governed schema, and its invocation-canonical digest
compared with what the prepared record committed to. A different payload is a
different binding and is refused.

**Profile derivation.** Re-derived from the implementation authority — an
independent namespace the coordinator can read and cannot write — never carried
across from preparation.

**Idempotency.** A `CINV` already at `launch_authorized` is **resumed**: no
second transition, no second `CMUT`, no second identity. Measured: `resumed:
true`, `cmut-counter` unmoved.

**Recovery semantics.** Everything after the committed transition is a
deterministic function of it, so an interrupted run is resumable. A projection
or handoff that disagrees is a refusal, never something to rebuild — the module
contains no `unlink`, no `rmtree` and no truncating open.

**Trust and current eligibility are NOT rechecked.** The bridge says so in
terms: it re-runs no governed decision it does not own, reads the selection and
package back from the durable record, and does not consult Trust at all.
**Every current-authority question is therefore the ceremony's job.** That is
the single most important finding in this section, and it shapes BLOCK B.

**What Stage 2 does NOT do.** No container, no payload execution, no `CRES`, no
identity allocation, no sequence movement, no Fabric or Trust write, and no
Stage-3 effect.

## E. Current governed authority

Asked of the released verifier at the moment of checking, not compared by eye.

```
verify_selected_evidence(fabric, selection_id=CSEL-000004,
                         instance_id=CINST-000006, capability_package_id=CPKG-0001,
                         operation=execute, trust_root=/var/lib/kyri/trust,
                         evaluated_at=<now>)
  -> supported = True, reason = None, eligibility_reasons = ()
     CCON-0001, CAPDEF-0001, computational, HOST-0001
```

- `CADV-000007` is the advertisement head and unsuperseded.
- `CINST-000006` is currently admitted and currently eligible — the verdict
  carries no eligibility reasons.
- `CROUTE-0006` is the route head; nothing supersedes it.
- `CSEL-000004` still binds `CROUTE-0006` and still selects `CINST-000006`.
- Fabric aggregate `a87c2010796516ee278c305d00f45e0408654e6d792bbfcb9e4d7d88cd9412e5` — unchanged.

**CURRENT_FABRIC_AUTHORITY = PASS. CURRENT_ELIGIBILITY = PASS.**

### The authority expires on 2026-09-23T06:00:00-05:00

`CADV-000007` carries that `valid_until`. At the time of writing that is about
**47 hours** away. Stage 2 must be performed before it, or the advertisement
must be renewed and this ceremony re-prepared against the new chain. BLOCK B
asks the released verifier at run time, so a ceremony run after expiry refuses
rather than proceeding on a historical timestamp — but the operator should know
the window rather than discover it.

## F. One free slot is enough

`MAXIMUM_SLOTS = 2`, held = 1, free = 1.

- `CINV-000001` (`launch_authorized`) holds the one slot.
- `CINV-000002` (`abandoned`) holds none — `slot_holding_states()` excludes it.
- `CINV-000003` holds none before Stage 2.

`capacity.reserve` refuses only at `len(held) >= MAXIMUM_SLOTS`. The rehearsal
proves the admission rather than arguing it: occupancy went 1 → 2 and Stage 2
completed. Occupancy 0 of 2 was never required, and reclaiming `CINV-000001` to
reach it is not authorised.

## G/I. The ceremony

`provisioning/execution/g11-bc-z-cinv-000003-stage-2-ceremony.txt`, prepared and
**not executed**. Three blocks:

- **BLOCK A** — observation as `kyri-capability`: no `kyri-CINV-000003`
  container, no `kyri-CINV-*` container at all, the execution image
  `5cee2b53…` present. Writes a witness.
- **BLOCK B** — the gates, all read-only: the witness and its freshness; the
  five installed Generation-20 digests; **the current Fabric authority through
  the released verifier, at run time**; the route head, the unsuperseded
  advertisement and the selection binding; the runtime baseline `76bf8f99…`;
  both sequences, both counters and the transition count; `CRES-000002` absent;
  the four immutable record digests; the payload file, the staged tree and the
  three prepared digests; `CINV-000003` having no execution state; the lifecycle
  and occupancy 1 of 2.
- **BLOCK C** — the one irreversible command, its verdict, the exact mutation,
  what must not have changed, and the resulting occupancy.

### Why BLOCK C is separate, and is not rehearsable

`authorise-launch` compiles in its runtime, execution and handoff roots and
takes no `--store-root`. That is deliberate — the privileged transition
compiles in the same roots — and it has a consequence that has to be said
plainly, because on 2026-09-20 it was not: **a path substitution through this
ceremony would redirect every gate in BLOCK B and would not redirect BLOCK C.**
The gates would read a fixture and the mutation would land in production.

So BLOCK C is never rendered against a fixture. Its effect is rehearsed at the
API, and its post-checks are extracted and run as predicates over stores only
after asserting the extract contains no mutation. The suite asserts all of this
about the ceremony text itself.

## H. The rehearsal

`tests/test-capability-cinv-000003-stage-2-rehearsal.sh` — **126 assertions**,
host-only.

- BLOCK B runs whole against fixtures and passes on a clean one.
- Stage 2 runs at the API against a byte copy: `resumed: false`, occupancy
  **1 → 2**, every verdict field as tabulated above.
- The mutation, measured and then proved by reconstruction: removing
  `execution/CINV-000003`, its lock, the two transitions and the three `CMUT`s,
  and rewinding `cmut-counter`, reproduces the pre-Stage-2 store exactly.
- Both sequences unmoved, `cadm-counter` unmoved, every `CINV`, `CRES` and
  `CADM` byte-identical, no `CRES` written, `CINV-000001` and `CINV-000002`
  untouched.
- The handoff published with the right digests and the right modes.
- A second run resumes and journals nothing further.
- After Stage 2 the ceiling holds: occupancy 2 of 2 and a third reservation is
  refused.

## J. Failure matrix

Nineteen ceremony sabotages, each breaking one fact and each required to refuse
**for its own reason** with no traceback and no execution state created:

installed runtime not Generation 20 · advertisement authority expired · route
moved · selection changed · Fabric baseline moved · runtime baseline moved ·
`CINV-000003` changed · invocation sequence moved · result sequence moved · a
result appeared · execution state already exists · occupancy not 1 of 2 · staged
tree changed · payload changed · execution image absent · target container
exists · witness absent · witness stale · witness dated in the future.

Two notes on making these reach their intended gate rather than an earlier one:

- The aggregate gates stand in front of the specific ones, so a case about a
  single record re-pins the baseline it deliberately changed. A case *about* an
  aggregate does not.
- "Occupancy not 1 of 2" cannot be made by deleting the abandonment transition —
  that changes the transition count and is caught by the gate in front. It is
  made by rewriting `CINV-000002`'s last transition to `created`, a state the
  released vocabulary reaches from `launch_authorized` and which holds a slot,
  so occupancy moves while the journal still holds five records.

Operation-level refusals are exercised where they live: a payload that is not
the prepared one is refused by the bridge and creates no execution state, and
with both slots genuinely held the reservation refuses as `CapacityExhausted`.
BLOCK C's own post-checks are run as predicates: they accept the store Stage 2
actually produced, catch a wrong verdict field by name, and catch a fabricated
`CRES` as an unexpected Stage-3 effect.

## K. Stage 1 stays spent

`capability invoke` was not re-run. Its durable facts hold: `CINV-000003` exists
at `c0941b7d…`, payload digest `sha256:591d4b0d…`, binding digest
`sha256:6d5a8d92…`, artifact digest `sha256:6f2282c5…`, invocation sequence 3.
No whole-runtime aggregate is pinned in spent mode.

The same rule was applied to the **G11-BC-Y correction ceremony**, which became
spent when the operator ran it. Its suite now asserts the refusal at the
runtime-baseline gate and the durable facts of `CADM-000002`, and rehearses the
ceremony against a *reconstruction* of the pre-correction store — which is sound
because that reconstruction is exact.

### Three suites had stopped being reconstructions

Both are the class corrected at G11-BC-Y, arriving on schedule:

- `test-capability-execution-generation20-installer.sh` built its
  "Generation-19" fixture by copying the installed library. The operator
  installed Generation 20, so the copy became a Generation-20 tree claiming to
  be its own predecessor. It now rewinds through `succession_rewind` against the
  reviewed Generation-19 commit, compares declared baselines with that commit
  rather than with the host, additionally asserts the declared targets are what
  is installed, and derives its object counts.
- `test-capability-cadm-000001-correction-rehearsal.sh` depended on that fixture
  builder and on the ceremony being unspent. Rewritten as above.
- `test-capability-mutation-target-explicit.sh` reproduced the incident against
  the **installed** library, and the defect stopped being installed the moment
  Generation 20 landed — so the proof of it could no longer run. A claim about
  an earlier release is a claim about its reviewed bytes: the Generation-19
  package is now materialised from the commit the Generation-20 installer names
  as its baseline, digest-checked, and the defect reproduced there. The suite
  additionally asserts the defect is **not** on this host. Its correction
  fixture is cut from a pre-correction reconstruction, because a fixture cut
  from production today already carries `CADM-000002` and a fresh correction
  there is refused as a conflicting one — the released behaviour working, and
  not the question that suite asks.

## L. Verification

| Run | Result |
|---|---|
| Quick validator | **130/130**, passed |
| Full validator | **155/155**, passed |
| Clean-clone full validator | **155/155**, passed |
| ShellCheck (CI-pinned 0.9.0) | clean |
| GitHub CI | all workflows green |

New and reworked suites: Stage-2 rehearsal 126, Generation-20 installer 83,
correction rehearsal 60, mutation target 32.

Production after every run: runtime `76bf8f99…`, Fabric `a87c2010…`,
`CINV-000003` with no execution state, no handoff published for it.

## Actions NOT performed

`CINV-000001` was not reclaimed and no abandonment ceremony was prepared for it.
Stage 2 was not run in production. Stage 3 was not run. No payload was executed.
No `CRES` was created. Stage 1 was not re-run. Fabric, Trust, Artifact authority
and Platform Evidence were not altered. `MAXIMUM_SLOTS` is unchanged at 2. No
runtime record was hand-edited. Root Authority was not mounted. ENG-0006 was not
begun.

## For the reviewer

1. Accept or refuse the Stage-2 ceremony and its three-block shape — in
   particular, that BLOCK C is not rehearsable and why.
2. Note the **2026-09-23T06:00:00-05:00** authority expiry. Stage 2 before it,
   or renew `CADV-000007` and re-prepare.
3. After Stage 2, occupancy will be 2 of 2. Stage 3 is a separate decision and
   nothing here prepares it.
