# Post-Root Runtime Sequence Implementation Plan

> **For agentic workers:** Execute one engineering item at a time. Stop for
> independent review and explicit merge approval after each item.

**Goal:** Correct the post-ceremony dependency order and define two independent
test-first defect releases before Fabric Runtime implementation begins.

**Architecture:** The Operator Root Authority is already established and is the
completed Fabric Runtime gate. ENG-0001 and ENG-0002 repair released Trust
Runtime behavior as separate releases. Fabric and Health runtimes are then
built and validated before subject seeding and final TrustGateway cutover.

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
2. ENG-0001: persist TLIN lineage records.
3. ENG-0002: make `validate-store` genuinely read-only.
4. ENG-0004: implement Fabric Runtime in separately specified increments.
5. ENG-0006: implement Health Runtime against the validated Fabric.
6. Seed the required production subjects.
7. ENG-0003: perform TrustGateway cutover as the final production transition.

## ENG-0001 - Persist TLIN lineage records

**Files:**

- Modify: `tests/test-trust-runtime.sh`
- Modify: `tools/trust/root_authority.py`
- Verify: `tools/trust/store.py`
- Update: `CHANGELOG.md` and the release record selected for ENG-0001

**Acceptance contract:** A successful `init-root` writes the allocated
`TLIN-000001-v0001.yaml` lineage record. The lineage names `TAUTH-000001` as its
subject, carries the authority's trusted state and provenance, and is written
before records that reference it can make the store observable as complete.
`validate-store` reports no missing-lineage defect after initialization.

- [ ] Add a behavioral assertion to `tests/test-trust-runtime.sh` that reads the
      initialized lineage through `TrustStore.read("lineage",
      authority.lineage_id + "-v0001")` and verifies its subject, type, state,
      version, and provenance.
- [ ] Add a CLI assertion that a fresh `init-root` store contains one lineage
      file and that `validate-store` reports it valid.
- [ ] Run `bash tests/test-trust-runtime.sh` and retain the failing output that
      proves the released defect.
- [ ] Construct the initial `TrustLineage` in
      `declare_root_authority()` using the already allocated authority lineage
      identifier; do not allocate a second TLIN identifier.
- [ ] Persist the lineage with `store.write("lineage", lineage)` using the
      existing immutable write path and add its versioned identifier to the
      root-declaration audit event's related records.
- [ ] Run `bash tests/test-trust-runtime.sh`; require zero failures.
- [ ] Run `tools/dev/run-validation.sh`; require exit code 0.
- [ ] Update release documentation for ENG-0001 only.
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
TrustGateway remains in code-owned-policy mode during Fabric and Health runtime
construction by design.

## Final production transition

After Fabric Runtime and Health Runtime exist and have been validated, seed the
required production subjects using the reviewed operator procedure. Perform
TrustGateway cutover only after the validation checklist passes with retained
evidence, a validated configuration rollback, `trust-plane-runtime` as the
verdict source, and no silent fallback.

Related records:

- [Runtime sequencing correction](../../history/0002-runtime-sequencing-correction.md)
- [Engineering ledger](../../history/v1.0-engineering-ledger.md)
- [Operator Root deployment guide](../../trust/operator-root-authority-deployment.md)
- [Operator Root validation checklist](../../trust/operator-root-authority-validation-checklist.md)
