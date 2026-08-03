# Governance Boundaries

**Architecture only.** Nothing here is implemented. Governed by
[ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

The Health Plane observes. It is the only layer in the platform whose entire
specification is about what it must not be able to do.

## The asymmetry

The Health Plane **consumes Trust Plane state**. It **cannot change** it.

> A monitor that can change trust is a monitor that can be induced to grant it,
> and availability data is the easiest signal in the platform to manipulate
> from outside.

| Health | |
|---|---|
| **consumes** Trust Plane state | **cannot change or mutate** trust state |
| **consumes** Fabric records | **cannot admit, register, route, or select** |
| **may recommend** investigation or draining | **cannot execute remediation** |
| **may remove** a candidate on evidence | **cannot add or reorder** candidates |

## What health may never do

- **grant trust**, or change trust state in either direction
- **override quarantine** — a quarantined subject with a perfect health record
  stays quarantined
- **broaden scope**
- **admit a node**, register a capability, or create an instance
- **reroute** workloads, automatically or otherwise
- **drain** a node
- **quarantine** anything
- **restart, redeploy, requeue, or repair** anything
- **predict or forecast** availability, capacity, or demand
- **conclude anything about a subject it could not reach**

## The Trust Plane does not read health back

The loop must not close. **The Trust Plane does not use health records as
evidence of trustworthiness.**

A capability that has been healthy for six months has earned nothing. A
compromised capability's most likely behaviour is to look well.

The relationship catalog declares this as a forbidden pairing on
`DERIVED_FROM`: a trust record or trust decision may never derive from a health
observation or health state. Health may be derived *from*; it may never be
derived *to* trust.

## Recommendations are records, not acts

The single output that touches operations.

A `capability-health-recommendation` draws from a **closed vocabulary of
exactly four**. Closed rather than merely enumerated: an open list is one pull
request away from containing `restart`, and the argument for adding it will be
made during an incident.

| Kind | Asks a human to |
|---|---|
| **`investigate`** | Look. The safe default and the usual answer. |
| **`review-envelope`** | Check whether the threshold is wrong. A capability repeatedly outside a limit nobody has revisited is as likely to be a wrong limit as a broken capability. |
| **`verify-observation-source`** | Check whether the *measurement* is wrong. A failing collector produces the same shape of evidence as a failing capability, and they are not the same problem. |
| **`consider-manual-drain`** | Consider withdrawing a node. **Consider, not do.** |

Every recommendation carries its kind, the health evaluation it followed from,
a written reason, `created_at`, `review_required: true`, and
`advisory_only: true` — carried on the record rather than assumed from the
record type, so a consumer reading one in isolation still knows it is advice.

It may **never** propose quarantine, revocation, trust changes, approval, scope
broadening, rerouting, restart, stop, kill, repair, remediation, execution, or
application. Those are trust decisions or fabric changes, and neither belongs
to an observer.

It carries **no execution surface**: no execution target, command, script,
shell, action payload, route identifier, or trust decision identifier. These
are named as forbidden fields on the schema rather than merely omitted, so a
future runtime cannot quietly add one and still pass its tests.

## Manual drain

A **Fabric-local administrative drain**, defined here because it is the
boundary health must not cross.

A manual drain:

- **prevents new selections**
- **does not alter trust**
- **does not quarantine**
- **does not revoke**
- **does not broaden or narrow trust scope**
- **does not terminate existing work** unless separately approved
- is **reversible only by an explicit Fabric decision**
- **cannot be executed by Health**

It is expressed through the Fabric's `availability_intent`, is an operator
decision, and **remains architectural only until the Fabric runtime exists**.

**Health may recommend `consider-manual-drain`. Health may not perform one**,
trigger one, or reverse one. A fresh `healthy` state does not undo a drain
either — see [worked example 2](worked-examples.md).

**It requires a human to act on it, and is never executed automatically.**

Quarantine is excluded deliberately, and the reasoning is worth keeping. A
quarantine recommendation reads as harmless because a human still approves it.
In practice a stream of automated quarantine recommendations trains the
approver to click through them, which is an automatic path with a human-shaped
delay in it. Health recommends investigation; a human decides what the
investigation found.

## Audit requirements

Every health record is immutable, append-only, and superseded rather than
edited. States carry the observation identifiers they were derived from, so the
evidence behind any past assessment stays reachable.

| Record | Answers |
|---|---|
| **Every observation** | What was measured, when, by which source, and whether collection succeeded |
| **Every health state** | What the assessment was, against which envelope, on which evidence |
| **Every degradation event** | What moved, in which direction, and which declared condition was met |
| **Every recommendation** | Who was asked to do what, and why |

Three questions must be answerable **from records alone**:

- **"Was this capability healthy when that request was routed to it?"**
- **"What evidence did that assessment rest on?"**
- **"Who was told, and what did they do about it?"**

A health history that can be edited cannot answer the first one, which is the
only one that matters after an incident.

## Dependency and sequencing

- The Health Plane **depends on v0.9.5 Fabric entities**. There is nothing to
  observe until something has been admitted.
- **v1.0.0 requires both** the Fabric and the Health Plane.
- **No health runtime exists in this release**, and the Fabric runtime remains
  blocked by the Operator Root Authority deployment gate.

## Related

- [Capability Health overview](capability-health.md)
- [Degradation semantics](degradation-semantics.md)
- [Health states](health-states.md)
- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [Fabric governance boundaries](../fabric/governance-boundaries.md)
