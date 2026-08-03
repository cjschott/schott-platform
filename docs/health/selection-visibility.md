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

## No runtime fields are added here

This is a specification statement, not an implementation. The Fabric's
selection schema carries the requirement as a declared block; the fields above
are what a future runtime must produce, not columns that exist today.

Nothing in this release records a selection, because nothing selects.

## Related

- [Unknown health and freshness](unknown-and-freshness.md)
- [Worked examples](worked-examples.md)
- [Capability routing](../fabric/capability-routing.md)
- [Governance boundaries](governance-boundaries.md)
