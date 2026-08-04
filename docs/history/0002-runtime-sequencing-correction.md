# 0002 - Runtime Sequencing Correction

Status: Permanent Superseding Historical Record
Date: 2026-08-03
Platform Baseline: v0.9.6 plus Operator Root establishment commit

## Purpose

This record corrects the dependency ordering recorded after the Operator Root
Authority ceremony. It preserves the original ceremony record unchanged and
supersedes only its statement that Fabric Runtime, Capability Runtime, and
Health Runtime remain blocked until TrustGateway cutover.

## Corrected decision

The Operator Root ceremony was the architectural gate for Fabric Runtime.
TrustGateway cutover is intentionally not the Fabric Runtime gate.

The canonical dependency chain is:

1. Operator Root Authority ceremony
2. Released-defect sprint: ENG-0001, then ENG-0002
3. Fabric Runtime
4. Capability Runtime, as a Fabric increment under its own specification
5. Health Runtime
6. Required subject seeding
7. TrustGateway cutover

ENG-0001 and ENG-0002 are separate Red -> Green changes. Each is independently
reviewable and independently releasable. Both must be merged and released
before Fabric Runtime implementation begins.

TrustGateway cutover remains the final production transition. It occurs only
after the runtimes exist, have been validated, and their required production
subjects have been seeded.

## ENG-0001 scope correction (2026-08-04)

The first statement of ENG-0001 — "persist the allocated `TrustLineage`" — was
withdrawn before implementation as not implementable. `TrustLineage` requires
two `TDEC` identifiers; `init-root` creates no decision; and an authority is
forbidden from approving itself. Satisfying it would have required fabricating a
decision that never happened.

[ADR-0014](../decisions/ADR-0014-root-establishment-lineage.md) replaces it with
a dedicated `RootAuthorityLineage` record type that carries no decision fields at
all. ENG-0001 now implements that contract. No trust record, ceremony record, or
audit event was changed to reach this correction.

## Supersession boundary

This record does not alter the authority, evidence, audit identifiers, known
implementation defects, or any other ceremony fact in
[0001 - Operator Root Authority Establishment](0001-operator-root-establishment.md).
It corrects sequencing only.

## Planning authority

The live execution order is maintained in the
[v1.0 engineering ledger](v1.0-engineering-ledger.md) and the
[post-root runtime sequence](../superpowers/plans/2026-08-03-post-root-runtime-sequence.md).
