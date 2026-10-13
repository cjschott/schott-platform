# Selection Visibility

**Architecture only.** No selection runtime exists, and none is implemented
here. This document records a **future requirement** on the Fabric's
[capability selection](../fabric/capability-routing.md) record, defined now so
that a future runtime cannot be built without it.

Governed by [ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

## The requirement

Every Capability Selection must expose:

| Exposure | Why |
|---|---|
| **Referenced Health state** | Which assessment applied at the moment of the choice |
| **Health freshness** | A state without an age is not an assessment |
| **Whether Health changed eligibility** | The difference between "health agreed" and "health said nothing" |
| **Explanation** | Why this candidate, and why not the others |
| **Envelope version**, where applicable | So a later supersession cannot change what a past selection meant |
| **Warning**, when the state is `unknown`, stale, `withheld`, or `insufficient-policy` | Each of these is an absence of a positive claim, and absences must be conspicuous |

## A selection may proceed on unknown health

**It may — when Trust and the Fabric permit it — but it must say so.**

```yaml
eligible_by_fabric: true
health_state: unknown
health_effect: none
health_warning: no fresh health evidence
```

The selection is legitimate. Trust granted eligibility, the Fabric's declared
candidate order chose this instance, and health had nothing fresh to contribute.

What is not legitimate is proceeding *silently*. A selection that omits health
when health had nothing to say is indistinguishable from one where health
agreed — and the two are very different facts to read during an incident.

> **Health must never silently disappear from the explanation.**

## Health changed eligibility, or it did not

The flag matters more than it looks. There are three cases and they must not be
collapsed:

| Case | `health_effect` |
|---|---|
| Health had fresh positive evidence and removed a candidate | `removed` |
| Health had fresh evidence and the candidate stayed | `none` |
| Health had nothing fresh to say | `none`, **with a warning** |

The second and third produce the same eligibility outcome and mean opposite
things. Without the warning, an operator cannot tell a monitored-and-fine
capability from an unmonitored one.

## The forward boundary

**Corrected at ENG-0006-C.** This section previously asserted that the released
Fabric selection schema already carried this requirement as a declared block. It
did not. The released schema mentioned health only as `health_score` among its
forbidden fields, and the five selections in production carry no health field at
all.

The requirement now has a declared boundary, and the mechanism matters:

- **Disclosure is required from `CSEL-000006` onward.** Every new selection
  carries selection-level context and a per-candidate result for every considered
  candidate, the selected one included.
- **`CSEL-000001` through `CSEL-000005` are a closed pre-disclosure set.** They
  stay exactly as written and are read as what they are — selections made when no
  Health runtime existed. They are **not** read as `consulted: false`, and are
  **not** assigned a default health state.
- **A new write cannot disguise itself as a legacy one.** Selection identities
  come from a monotonic sequence that refuses rollover, so every identity a new
  write can receive is strictly greater than every member of the closed set.
  Membership is decided by identity, not by shape, and omitting the fields does
  not buy exemption.
- **The global Fabric `schema_version` is unchanged.** It is one value shared by
  eight record families and enforced by equality; moving it would invalidate
  every record in the store.

## Three cases that must stay distinguishable

| Case | `consulted` | `health_state` | `health_effect` | warning |
|---|---|---|---|---|
| Health was never asked | `false` | `not-consulted` | `none` | **required** |
| Health was asked and had nothing fresh | `true` | `unknown` | `none` | **required** |
| Health was asked and agreed | `true` | `healthy` | `none` | not required |

All three end with no removal. The first two were byte-identical in the released
record, and they mean opposite things.

**Malformed, unreadable or unverifiable health evidence** is disclosed as its own
case — `adapter_outcome` plus an `evidence_unusable_reason` — and contributes
**no subtraction**. That is not a statement that the candidate is eligible;
eligibility was decided before health was consulted.

Nothing in this release records a selection, because nothing selects.

## Related

- [Unknown health and freshness](unknown-and-freshness.md)
- [Worked examples](worked-examples.md)
- [Capability routing](../fabric/capability-routing.md)
- [Governance boundaries](governance-boundaries.md)
