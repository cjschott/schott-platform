# Capability Routing

**Architecture only.** There is no router, no scheduler, and no placement
engine. Governed by
[ADR-0012](../decisions/ADR-0012-distributed-capability-fabric.md).

Routing is a **deterministic, total, and explainable** function of declared
inputs. The same inputs choose the same instance, every time, and the choice
can be reconstructed from records after the fact.

## The algorithm

1. Resolve the **route** for the request class — capability, contract version
   range, data classification, locality. **No route → refuse.**
2. Reduce the candidate list to **eligible** instances, by the eight conditions.
3. Allow **health to remove** further candidates. Health may not reorder or add.
4. Select the **first remaining candidate in the declared order**.
5. If none remain, **refuse**, naming every candidate and why it was excluded.
6. Write a `capability-selection` record.

## The eight eligibility conditions

An instance is eligible only when **all** hold:

1. The **package** holds `Trusted` or `Restricted` in `capability-package`.
2. The **host** holds `Trusted` or `Restricted` in `fabric-node`.
3. The package **declares** it satisfies the requested contract version.
4. The host's **verified** resource profile satisfies the package's
   requirements.
5. A **fresh advertisement** exists, inside its validity window.
6. An **admission decision** exists, is human-approved, and has not expired.
7. The **effective scope** intersection is non-empty.
8. The request's **data classification** is within the host's ceiling.

Any one missing makes the instance ineligible. **The default is ineligible.**

## A route is policy; a selection is an act

Two records, two lifetimes, and they must not merge.

| | Capability Route | Capability Selection |
|---|---|---|
| **Is** | A **policy declaration** | An **immutable audit record** |
| **Written by** | A human, in advance | The fabric, per request |
| **Lifetime** | Durable, versioned | One moment, never edited |
| **Records** | Which candidates, in what order | Which candidate was chosen, and why each other was not |

A route is **not an execution event**. It says nothing about anything having
run; it says where something *may* run.

A selection **must reference the governing route and its version**, and
**does not duplicate route policy**. A copy would drift from the route, and the
audit record would then describe a policy that never applied — which is worse
than no record, because it reads as authoritative.

## Order is written, never computed

The candidate order lives in the route and is **human-authored**.

Selection takes the **first eligible candidate in human-declared route order**.
That is the whole rule.

**No load-based routing, no latency-based routing, no score-based routing, no
weighting, no automatic scaling, no automatic reordering.**

A router that orders candidates by observed behaviour is deriving placement
from reasoning — the ADR-0011 directionality violation wearing an operations
hat. It is also unpredictable during the incident when predictability matters
most. Declared order is worse at utilisation and better at being understood,
and that trade was made deliberately.

## Locality is enforced, not advisory

| Value | Meaning |
|---|---|
| `local-only` | Must execute on this host. **Refuses rather than leaving it.** |
| `operator-controlled-only` | May execute on any operator-controlled host; never third-party-hosted. |
| `any-trusted` | May execute on any eligible instance in the route. |

A `local-only` request that cannot run locally is **refused**. Degrading to a
remote instance because the local one is unavailable is exactly the silent
redirection this rule exists to prevent.

## Version negotiation

Negotiation happens against **contracts**, never packages, and it is set
intersection with no cleverness in it.

- A request declares a contract and an **explicit set of accepted versions**.
- A package declares the **explicit set of contract versions it satisfies**.
- The eligible set is the intersection. **Empty → refuse.**

**Compatibility is declared, never inferred.** A contract names the prior
versions it is compatible with, in a field, reviewed by a human. The platform
never reads meaning into a version number: semantic versioning is a convention
publishers follow imperfectly, and treating it as a guarantee means an upgrade
decision gets made by string comparison.

**No automatic upgrade, no automatic downgrade, no nearest match, no
best-effort.** A request that cannot be satisfied exactly is refused.

## Health, before there is a health monitor

The Capability Health Monitor is v0.9.6. Until it exists:

- Health may be **declared or unknown**.
- Health **must not reorder** candidates. It may only remove them.
- **Absence of health data must not be converted into a positive health
  claim.** Unknown stays unknown — treating missing data as healthy is how an
  unmonitored node becomes the preferred one.
- **No automatic rerouting.**

Where health and trust disagree, trust decides.

## Only instances are routable

A route may target a `capability-instance` and nothing else. It may **never**
target an advertisement — that would be routing to a self-report.

A route may not select a `side-effecting` contract. That class exists so a
future actuating capability is representable without being permitted; opening
it requires a future ADR that governs actuation on its own terms.

## Every choice is recorded

A `capability-selection` records the route and **route version** that applied,
every candidate considered, the exclusion reason for each rejected one, the
instance chosen, and when.

Recording the route version matters: a later route edit must not be able to
change the explanation of a past choice.

A **refusal is recorded the same way**. Silence is not an outcome.

## Related

- [Capability Fabric overview](capability-fabric.md)
- [Failure behaviour](failure-behaviour.md)
- [Governance boundaries](governance-boundaries.md)
- [Node model and heterogeneous hardware](node-model.md)
