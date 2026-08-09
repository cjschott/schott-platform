# Capability Lifecycle

**Architecture only.** Nothing here is implemented. Governed by
[ADR-0012](../decisions/ADR-0012-distributed-capability-fabric.md).

A capability moves through six stages. **No stage transition happens
automatically except expiry**, which is the same rule ADR-0011 applies to trust
states, for the same reason: everything else is a decision, and a decision has
an author.

## The six stages

| Stage | What exists | What made it happen |
|---|---|---|
| **Declared** | capability, contract, package | A human wrote the records |
| **Trusted** | a trust record on the package, and on the host | A trust decision (ADR-0011) |
| **Advertised** | a host's self-report | The host published a claim |
| **Admitted** | a capability instance | A human-approved admission decision |
| **Superseded** | a newer instance or package, both readable | A declared supersession and a new route version |
| **Retired** | nothing eligible; history intact | A decision to withdraw |

### Declared

Somebody writes a `capability-definition`, one or more
`capability-contract` versions, and a `capability-package` that claims to
satisfy explicit contract versions.

Nothing is trusted. Nothing is eligible. A declared capability is a description.

### Trusted

The package becomes a subject in the `capability-package` domain; the host
becomes a subject in the `fabric-node` domain. Each is decided **separately**,
with its own evidence, by the Trust Plane.

**Trusting the package trusts no machine. Trusting the machine trusts no
package.**

### Advertised

The host publishes a `capability-advertisement`: what it holds, which contract
versions it satisfies, what resources it claims, observed at one moment and
valid until another.

**This is a claim, never a grant.** It confers no trust, creates no
eligibility, and admits nothing — including itself. Believing the first
advertisement a host sends is trust on first use with a new spelling.

### Admitted

A human-approved admission decision creates a `capability-instance` — the
binding of one package to one host for one contract, and the only thing a route
may target.

Admission requires **all eight** eligibility conditions to hold: package trust,
host trust, contract version satisfaction, verified resource match, a fresh
advertisement, an unexpired admission, a non-empty scope intersection, and a
data classification the host is declared to handle.

The effective scope is the **intersection** of package scope, host scope, and
admission scope, taken across **all four** released dimensions —
`permitted_capabilities`, `permitted_operations`,
`permitted_data_classifications`, `permitted_targets`. It is **computed**, from
the two grants the Trust Plane reported and the operator's own bound; it is
never asserted by whoever asked. An empty dimension is a valid composition
outcome, and it means nothing is eligible: if any released dimension is empty
once package, host, and admission scope have been intersected, the effective
scope authorises no binding.

An **absent** grant bounds nothing and therefore permits nothing — absence is
never permission. The package is decided under its **record identity**, which
is per version by construction and is the only identity that knows which
contract the trust was granted for; the host is decided under its
`node_identity_reference`.

Classifications are compared by **exact equality**. There is no ordering and no
ceiling, because no accepted source declares one.

### Superseded

A new package version is a **new subject** requiring its own trust decision.
"It is a patch release of something we already trust" is precisely the
automatic capability approval ADR-0011 forbids.

- Supersession is **declared**, never inferred from a version number or an
  installation event.
- Old and new instances **may coexist** during a declared overlap window.
- **Cutover is a route change** — a new route version listing the new
  instance — not a package event. A package cannot promote itself.
- Superseded records **remain readable**. Nothing is edited.

A declared overlap window is **immutable audit evidence** on the route that
declares it: two offset-carrying instants recording that old and new coexisted.
**Nothing happens when either instant arrives.** It schedules nothing,
activates nothing, delays nothing, rolls nothing back, rewrites no route, and
selects no candidate; no eligibility or selection behaviour reads it. What it
does enforce is the honesty of the declaration — it may be written only on a
route that supersedes another, and only where the candidate lists actually show
one carried over and one new. An identical list, or one dropping every prior
candidate, is refused: there was no coexistence to record.

### Retired

A decision withdraws the capability. Instances become ineligible, routes stop
listing them, and every record stays exactly as written. Retirement deletes
nothing: what was trusted last March remains answerable.

An instance carries its stage on the record, as `lifecycle_state`:

| State | Routable | Returns to `admitted` | Terminal |
|---|---|---|---|
| `admitted` | yes | — | no |
| `withdrawn` | **no** | **never** | **no** — a later decision may retire it |
| `retired` | **no** | **never** | **yes** |

The legal transitions are `admitted → withdrawn`, `admitted → retired`, and
`withdrawn → retired`. Every other pair is refused. A lifecycle decision writes
a new record that supersedes the previous one and carries every binding fact
across unchanged; no trust is consulted, because ending a binding is a decision
about a record rather than a fresh admission of one.

**Retirement is terminal.** No event, host return, fresh advertisement, route
change, or trust decision reactivates a retired binding. Re-admission is a new
human decision producing a **new** binding, evaluated against then-current
evidence — reactivation does not exist.

## Three expiry clocks

The one transition that *is* automatic, and it only ever removes eligibility.

| Clock | Governs | On lapse |
|---|---|---|
| **Trust expiry** | package and host trust records | state becomes `Expired`; instance ineligible |
| **Advertisement validity** | the host's claim about itself | claim is stale; instance ineligible |
| **Admission expiry** | the instance binding | binding lapses; instance ineligible |

Any one lapsing is sufficient. **None auto-renews.** Critically, a fresh
advertisement does not revive an expired admission or an expired trust
record — otherwise a host could keep itself eligible indefinitely by talking,
which is auto-renewal with extra steps.

**Recovery is a decision, not an event.**

## Related

- [Capability Fabric overview](capability-fabric.md)
- [Capability identity](capability-identity.md)
- [Failure behaviour](failure-behaviour.md)
- [Trust states](../trust/trust-states.md)
