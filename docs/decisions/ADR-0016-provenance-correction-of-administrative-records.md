# ADR-0016 — Provenance correction of administrative records

- **Status:** Proposed (G11-BC-Y), pending reviewer acceptance
- **Date:** 2026-09-20
- **Context:** ENG-0005, after the G11-BC-X incident
- **Related:** ADR-0002 (evidence-first), ADR-0015 (governed administrative abandonment)

## Context

On 2026-09-20 at 18:54:33-05:00 a rehearsal harness drove `capability abandon`
against the production capability runtime. The incident and its measurement are
recorded in
`docs/development/reports/eng-0005/2026-09-20-g11-bc-x-unauthorised-production-abandonment-incident.md`
(commit `e5471e8`).

The resulting store is in an unusual condition, and naming it precisely is what
this decision turns on:

- The **lifecycle effect is materially valid.** `CINV-000002` reached
  `launch_authorized` and never advanced; it was closed under
  `terminal-result-lifecycle-stranded` with `CRES-000001` referenced and not
  rewritten; one slot was reclaimed; nothing was deleted; the operator has since
  observed that no `kyri-CINV-000002` container exists or runs. This is exactly
  the outcome ADR-0015 specifies for this situation.
- The **provenance claim is false.** `CADM-000001` records
  `actor: primary-platform-operator`. No operator took, authorised or approved
  that action.

So the store holds a true effect under an untrue attribution. Every obvious
remedy is worse than the condition:

| Considered | Rejected because |
|---|---|
| Edit `CADM-000001`'s `actor` | The administrative namespace is create-once and append-only. An editable evidence record is not evidence, and the disputed claim must stay readable. |
| Delete `CADM-000001` and re-run under operator authority | Deletes the record of what actually happened, and the re-run would be a second closure of an already-closed invocation. |
| Revert `CINV-000002` to `launch_authorized` and redo it properly | `ABANDONED` is terminal and there is no reverse edge. Manufacturing one would be the force-transition ADR-0015 exists to refuse, and would re-take a slot to release it again for appearances. |
| Write a compensating lifecycle transition | Same objection, plus it would falsify the lifecycle to fix the provenance. |
| Accept the record as it stands | Leaves an audit trail asserting an operator action that never happened. |
| Record a free-form note somewhere | Not governed, not append-only in the same namespace, and not discoverable by anything that reads the record it is about. |

## Decision

**Add one closed-set administrative verb, `correct-provenance`, which records a
finding about a claim in an earlier `CADM` without touching that record, the
lifecycle, or capacity.**

`tools/capability/execution/provenance.py` implements it. `admin.Verb` gains
`CORRECT_PROVENANCE`, absent from `_DESTROYS_UNDER`, carrying no destruction
authority and dispatching no operation.

### Semantics

A correction asserts exactly this, and nothing more:

> This administrative action occurred and its lifecycle effect is retained. The
> claim named in `disputed_field`, as recorded in `subject_cadm`, is not
> truthful provenance, for the reason given in `finding`. The initiator was
> `actual_initiator`.

It is **not** ratification. It does not say the operator approved the action, it
does not name a substitute actor, and it makes no statement that the original
action was correct to take. `action_reversed: false` and `effect: retained` are
written out rather than implied, so a reader never infers them from silence.

### The record

A correction is a normal `CADM` — allocated from the same counter, with the same
create-once `intent` -> attempt -> `outcome` ordering — carrying one extra
member, `provenance-correction`:

| Field | Meaning |
|---|---|
| `subject_cadm`, `subject_member`, `subject_digest` | which record and member is disputed, and its SHA-256 at the time of the finding |
| `cinv` | the invocation the subject is about |
| `disputed_field`, `disputed_value` | the claim, and what it says — which must match the store |
| `finding` | closed set; today `attribution-not-authorised` |
| `actual_initiator` | closed set; `unauthorised-rehearsal-harness` or `unknown` |
| `effect`, `action_reversed`, `lifecycle_unchanged`, `slot_changed` | the retention statement, explicit |
| `lifecycle_state` | the state observed when the finding was made |
| `actor`, `request_id`, `recorded_at` | who recorded the correction, and when |
| `evidence_references`, `causal_references` | where the incident evidence lives |

### Invariants

1. **The subject is never opened for writing.** It is read, digested, and left
   byte-for-byte. `subject_digest` makes any later change to it detectable.
2. **No lifecycle claim is correctable.** `CORRECTABLE_FIELDS` is a closed set
   of provenance attributions — today `{actor}`. `state`, `previous_state`,
   `reason`, `slot_released` and `result_record_id` are unreachable by
   construction. A dispute about *what happened* is not a dispute about *who is
   recorded as having done it*, and one verb answering both would recreate the
   force-transition ADR-0015 refused.
3. **The disputed value must match.** Read from the subject, compared with what
   the caller states. An operator cannot correct a claim that is not there.
4. **Exactly one member may carry the claim.** A claim appearing twice makes the
   correction ambiguous, and this refuses ambiguity rather than choosing.
5. **The effect must still be standing.** If the subject recorded a `state` and
   the invocation is no longer in it, the correction refuses: it would describe
   a store that no longer exists.
6. **It takes the `CINV` lock and not the capacity lock.** A verb that touched
   occupancy would need capacity; this one must never be able to, and the lock
   it does not take is part of the evidence.
7. **No transition, no result, no slot movement.** The module imports neither
   `capacity` nor `transition_locked`.
8. **Create-once per (subject, field).** An identical repeat reports `resumed`
   and writes nothing. Anything differing refuses — two findings about one claim
   is a disagreement no reader could resolve.

### What `actor` means

The incident also demonstrated something the design already implied but had not
stated: **`actor` is a caller-asserted string, not an authenticated identity.**
Nothing in the current architecture binds it to an operator, a session, a key or
a privilege. A harness that passes `--actor primary-platform-operator` produces
a record indistinguishable from one an operator produced.

This ADR does **not** fix that, and deliberately does not pretend otherwise:

- A correction record can only ever say *which claim is not to be trusted*. It
  cannot prove who did act.
- The abandonment detail schema is **not** bumped to carry an
  `actor_provenance: asserted` marker in this generation. `CADM-000001` is the
  subject of a correction in the same publication; changing the schema of the
  record being corrected, in the release that corrects it, would make the
  subject harder to compare against its peers for no gain in truth.
- A stronger binding — the Trust plane's decision lineage, or the privileged
  helper's own authority — is the natural place for authenticated operator
  provenance, and is out of scope here.

The tests assert the weakness explicitly, so nobody reads the field as more than
it is.

## Consequences

**Good.** The disputed claim stays readable forever, beside a governed finding
about it. Nothing is deleted, edited or reversed. The mechanism is narrow enough
that it cannot become a general edit history: it corrects one closed set of
provenance fields in one record kind, and every other use refuses.

**Costs.** A reader of `CADM-000001` alone still sees the untrue attribution; the
correction is discoverable only by reading the administrative records, which is
how every other fact in this namespace works. The verb set grows by one, and the
closed set was a deliberate property.

**Not solved.** Authenticated actor provenance. Stated plainly above.

## Alternatives rejected

- **A new top-level record kind (`CPRV`) with its own counter and namespace.**
  More surface for no benefit: the finding belongs beside the record it is about,
  and the `CADM` machinery already gives create-once allocation, intent/outcome
  ordering and integrity scanning.
- **A generic `annotate` verb.** That is an edit history by another name. The
  value here comes from the closed field set and the mandatory match against the
  store.
- **Recording the correction in the Trust plane.** Trust decides admission and
  lineage; it does not hold capability-runtime administrative evidence, and
  splitting one audit across two planes makes it answerable from neither.
