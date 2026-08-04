# Post-Root Runtime Sequence Implementation Plan

> **For agentic workers:** Execute one engineering item at a time. Stop for
> independent review and explicit merge approval after each item.

**Goal:** Correct the post-ceremony dependency order and define two independent
test-first defect releases before Fabric Runtime implementation begins.

**Architecture:** The Operator Root Authority is already established and
completed the Fabric Runtime architecture gate. ENG-0001 implements the root
establishment lineage contract accepted in
[ADR-0014](../../decisions/ADR-0014-root-establishment-lineage.md); ENG-0002
repairs `validate-store`. Each is a separate release. Fabric, Capability, and
Health runtimes are then built and validated before subject seeding and the
final TrustGateway cutover, which is a **separate, later gate**.

**Tech Stack:** Python 3 Trust Runtime, Bash behavioral contract suites,
append-only YAML trust store, Markdown architecture records.

## Global constraints

- Test-first Red -> Green development.
- No implementation without its accepted specification.
- No hidden defaults, automatic trust, or LLM-based trust decisions.
- Preserve immutable audit history and append-only store semantics.
- Each ENG item is independently reviewable and independently releasable.
- Stop before merge unless explicitly approved.
- Do not begin Fabric Runtime until ENG-0001 and ENG-0002 are merged and
  released.
- Do not perform subject seeding or TrustGateway cutover during either defect.

## Dependency sequence

1. Operator Root Authority ceremony: complete.
2. ENG-0001: implement the root establishment lineage contract.
3. ENG-0002: make `validate-store` genuinely read-only.
4. ENG-0004: implement Fabric Runtime in separately specified increments.
5. ENG-0005: implement Capability Runtime as a Fabric increment, under its own
   accepted specification.
6. ENG-0006: implement Health Runtime against the validated Fabric.
7. Seed the required production subjects.
8. ENG-0003: perform TrustGateway cutover as the final production transition.

## ENG-0001 - Implement the root establishment lineage contract

**Entry gate:** [ADR-0014](../../decisions/ADR-0014-root-establishment-lineage.md)
accepted, and its
[contract specification](../../trust/root-establishment-lineage.md) merged.

> **Why the earlier plan was withdrawn.** It said "construct the initial
> `TrustLineage`". That is not implementable: `TrustLineage` requires
> `first_decision_id` and `current_decision_id` matching `^TDEC-[0-9]{6}$`;
> `init-root` creates no decision; and `evaluator.py` refuses any decision whose
> subject is its own actor, which a root's own decision would be. The only way
> to satisfy the old plan was to fabricate a `TDEC` recording an approval that
> never happened. ADR-0014 replaces it with a dedicated record type.

**Files:**

- Modify: `tests/test-trust-runtime.sh`
- Modify: `tools/trust/models.py` — add `RootAuthorityLineage`; add the
  `lineage_type` discriminator constant to `TrustLineage` and change nothing
  else about it
- Modify: `tools/trust/root_authority.py` — construct and write the lineage
- Modify: `tools/trust/store.py` — add the authority-lineage validation rule
- Update: `CHANGELOG.md` and the release record selected for ENG-0001

**Acceptance contract:** A successful `init-root` against a **fresh** store
writes `lineages/TLIN-000001-v0001.yaml` as a `root-establishment` lineage
carrying `authority_id`, `establishment_origin`, the five evidence reference
identifiers, and the establishment audit identifier. It carries **no**
`first_decision_id`, **no** `current_decision_id`, and no fabricated `TDEC`. No
second `TLIN` is allocated. `validate-store` reports the fresh store valid, and
reports a finding for any authority whose lineage record is absent.

### Red

- [ ] Assert a fresh `init-root` store contains exactly one lineage file named
      `TLIN-000001-v0001.yaml`.
- [ ] Assert the record's `lineage_type` is `root-establishment`.
- [ ] Assert it names `authority_id` `TAUTH-000001`, `establishment_origin`
      `external-operator-ceremony`, all five `TEVID-` identifiers, and the
      `TAUDIT-` identifier.
- [ ] Assert the record carries no `first_decision_id`, no
      `current_decision_id`, no `prior_decision_ids`, no `root_authority_id`,
      and no `approved_by`.
- [ ] Assert `decisions/` is still empty — no `TDEC` was fabricated.
- [ ] Assert `RootAuthorityLineage` cannot be constructed with any decision
      field, and that `TrustLineage` still refuses construction without both
      decision identifiers.
- [ ] Assert `validate-store` reports a finding when an authority's lineage
      record is absent.
- [ ] Run `bash tests/test-trust-runtime.sh` and retain the failing output that
      proves the released defect.

### Green

- [ ] Add `RootAuthorityLineage` per the contract specification. Decision fields
      must be **absent from the model**, not optional on it.
- [ ] Add `lineage_type` to `TrustLineage` as the constant `subject-decision`.
      Change no other `TrustLineage` field, validation rule, or invariant.
- [ ] In `declare_root_authority()`, construct the lineage from the **already
      allocated** authority lineage identifier. Do not allocate a second `TLIN`.
- [ ] Write in order: evidence, lineage, authority, audit — so a partially
      written store never holds an authority naming a lineage that was never
      written.
- [ ] Add the `validate-store` rule that an authority's `lineage_id` must
      resolve to a `root-establishment` lineage record. Report only; repair
      nothing.
- [ ] **Do not** amend `TAUDIT-000001` or any existing record to reference the
      new lineage. The ceremony's audit event records the ceremony.
- [ ] Run `bash tests/test-trust-runtime.sh`; require zero failures.
- [ ] Run `bash tests/test-trust-plane.sh` and `bash tests/test-trust-migration.sh`;
      require zero failures.
- [ ] Run `tools/dev/run-validation.sh`; require exit code 0.

### Explicitly out of scope for ENG-0001

- [ ] **Do not persist `TLIN-000001` into the production store.** `TAUTH-000001`
      already exists and cannot be re-declared, so the code fix repairs future
      root establishment only.
- [ ] Specify the production backfill as an append-only, separately
      operator-approved action: write `TLIN-000001-v0001` and nothing else;
      leave `TAUTH-000001` and `TAUDIT-000001` byte-identical, verified by
      digest before and after; emit a new audit event rather than amending the
      ceremony's; refuse if the lineage record already exists. **Do not execute
      it.**
- [ ] Do not touch `validate-store` directory-creation behaviour — that is
      ENG-0002.

- [ ] Commit ENG-0001 alone and stop for independent review and explicit merge
      approval.

## ENG-0002 - Make `validate-store` genuinely read-only

**Entry gate:** ENG-0001 is merged and released. Begin from the resulting clean
`main`, not from the ENG-0001 feature branch.

**Files:**

- Modify: `tests/test-trust-runtime.sh`
- Modify: `tools/trust/cli.py`
- Modify: `tools/trust/store.py` or `tools/common/immutable_store.py` only as
  required to expose a non-initializing read path
- Update: `CHANGELOG.md` and the release record selected for ENG-0002

**Acceptance contract:** `validate-store --store-root PATH` performs no
filesystem mutation whether `PATH` is absent, empty, valid, or malformed. It
must not create the store root, record directories, sequence files, indexes,
temporary files, or permission changes. Repeated validation produces the same
filesystem metadata and content digest.

- [ ] Add a behavioral assertion that snapshots an absent target's parent,
      invokes `validate-store`, and proves the target path was not created.
- [ ] Add assertions for empty, valid, and malformed stores that capture paths,
      file types, modes, sizes, modification timestamps, and content hashes
      before and after validation and require exact equality.
- [ ] Run `bash tests/test-trust-runtime.sh` and retain the failing output that
      proves the released mutation defect.
- [ ] Separate TrustStore opening-for-read from initialization. The read-only
      path must never call directory creation or sequence initialization.
- [ ] Make `command_validate_store()` use only the non-initializing read path;
      retain deterministic JSON and existing exit-code semantics.
- [ ] Run `bash tests/test-trust-runtime.sh`; require zero failures.
- [ ] Run `tools/dev/run-validation.sh`; require exit code 0.
- [ ] Update release documentation for ENG-0002 only.
- [ ] Commit ENG-0002 alone and stop for independent review and explicit merge
      approval.

## Fabric Runtime entry gate

Fabric Runtime planning may begin only after the released ENG-0001 and ENG-0002
commits are both present on `main`. Its first increment requires its own accepted
specification, test-first plan, feature branch, review, and release boundary.

ENG-0005 Capability Runtime is an increment of Fabric delivery, sequenced after
ENG-0004 and before ENG-0006, under its own accepted specification. Its exact
boundary against ENG-0004 is not yet specified.

TrustGateway remains in code-owned-policy mode during Fabric, Capability, and
Health runtime construction by design.

**Gate 1 permits construction only.** Production node admission, capability
registration, routing, selection, and execution wait for Gate 2 — a node
admitted while the gateway still answers from code-owned policy is trusted
through a chain that does not terminate at the root.

## TrustGateway production cutover gate

The second gate, in order: Fabric Runtime validated -> Health Runtime validated
-> initial subjects seeded -> verdict source ready -> rollback validated ->
deployment evidence retained -> TrustGateway cutover.

Seed the required production subjects using the reviewed operator procedure.
Perform cutover only after the validation checklist passes with **Operator Root
Authority instantiated**, **production trust store validated**, **initial
migrated subjects seeded**, **trust-plane-runtime or approved code-owned
fallback available**, **rollback procedure validated**, and **deployment
evidence retained** — with no silent fallback.

Related records:

- [ADR-0014: The Root Establishment Lineage](../../decisions/ADR-0014-root-establishment-lineage.md)
- [Root establishment lineage contract](../../trust/root-establishment-lineage.md)
- [Runtime sequencing correction](../../history/0002-runtime-sequencing-correction.md)
- [Engineering ledger](../../history/v1.0-engineering-ledger.md)
- [Operator Root deployment guide](../../trust/operator-root-authority-deployment.md)
- [Operator Root validation checklist](../../trust/operator-root-authority-validation-checklist.md)
