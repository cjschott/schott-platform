# Trust Mechanism Migration Implementation Plan

**Goal:** One trust system. Every existing trust decision resolves through the
Trust Plane, and nothing decides independently.

**Architecture:** v0.9.3 built the Trust Plane runtime; the platform kept using
four older mechanisms alongside it. This release routes them all through one
gateway.

## The Constraint That Shaped This

The Trust Plane runtime denies everything against an unseeded store, and
ADR-0011 forbids inventing a deployment identity. So a migration that made the
runtime mandatory would either break every released behaviour or require an
invented root.

Resolved by the operator: **one gateway, two policy sources.** The gateway is
the single decision point; it resolves from the trust store when configured and
from migrated code-owned policy otherwise, and records which. Behaviour is
preserved; the root-termination gap is documented rather than hidden.

- [x] **Task 1** — inventory every trust decision before changing anything.
- [x] **Task 2** — red phase across four suites.
- [x] **Task 3** — `tools/trust/policy.py`: the migrated rules, once.
- [x] **Task 4** — `tools/trust/gateway.py`: the single decision point.
- [x] **Task 5** — migrate four call sites; behaviour byte-identical.
- [x] **Task 6** — documentation, roadmap, CI wiring.
- [x] **Task 7** — self-review for duplicate logic, bypass paths, second
      authorities, automatic trust, TOFU, runtime mutation, reasoning
      influence, and score-based trust.

## Verification Strategy

Behaviour preservation is proven by the *unchanged* collector suites: if a
migrated decision differed anywhere, `test-initial-collectors`,
`test-remote-collectors`, or `test-collector-framework` would fail. The
migration suite then asserts the properties those suites cannot see — one
decision point, recorded verdict source, no invented domain, deny by default.

## Risks

- **Code-owned policy is not root-terminated.** The largest remaining gap, and
  the reason this is not yet "one root-terminated trust system".
- **Two domains are declared but not decided.** Identity and capability deny at
  runtime with a reason rather than allowing.
- **A centralised authority is a centralised blast radius.** One defect in the
  gateway is now a defect everywhere, which is the trade accepted for being
  able to audit trust in one place.
