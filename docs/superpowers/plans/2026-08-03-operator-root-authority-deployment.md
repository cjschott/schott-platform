# Operator Root Authority Deployment Plan

**Goal:** define the operator-controlled process that will later instantiate the
external Operator Root Authority and seed the first trust store.

**Nothing is instantiated by this plan.** No root authority, no trust store, no
production path, no runtime configuration change.

## Why this is a gate rather than a sprint

v0.9.4 gave the platform one decision point. What it could not give it is a
chain terminating outside the platform: doing that requires a real external
identity, and ADR-0011 forbids inventing one. So the last step between "one
trust system" and "one root-terminated trust system" is **deployment work
performed by a human**, not engineering work.

This plan exists so that step is executed from a reviewed procedure rather than
improvised at the console.

- [x] **Task 1** — document the boundaries: external root, declaration only, no
      inferred identity, references never material.
- [x] **Task 2** — propose store and input paths with ownership and permission
      rules; create none of them.
- [x] **Task 3** — define the input template using synthetic placeholders only.
- [x] **Task 4** — define acceptable out-of-band verification, and name what is
      not verification.
- [x] **Task 5** — define the non-mutating dry run.
- [x] **Task 6** — record the instantiation command and the evidence its
      execution must capture. Do not execute it.
- [x] **Task 7** — list the first subjects to seed, by domain, following
      released model conventions.
- [x] **Task 8** — define cutover acceptance, headed by the verdict source
      moving to `trust-plane-runtime` with no fallback.
- [x] **Task 9** — define rollback as configuration rollback, never
      trust-history rollback.
- [x] **Task 10** — make the v0.9.5 gate depend on deployment acceptance.

## Verification Strategy

Documentation assertions only. The suite proves the procedure is complete and
that no test executes `init-root`, creates a production path, or instantiates
anything.

## Risks

- **The procedure is untested against a real deployment.** Every step here is
  reasoned, not exercised. First execution needs supervision, and the checklist
  exists so that supervision has something to check against.
- **Rollback point 3 is the one most likely to be shortcut.** Code-owned policy
  resuming automatically on failure would be a bypass with a friendly name.
- **Seeding is a large manual act.** Seven subject classes, each needing
  evidence, an approval source, and a reason. A tired operator seeding at 2am
  is exactly the situation the expiry and review rules exist for.
