# ADR-0011: The Trust Plane

- **Status:** Accepted
- **Date:** 2026-08-02
- **Decision Makers:** Schott Platform Engineering

> **Numbering note.** ADR-0005 and ADR-0006 remain unassigned and reserved.

> **This ADR defines architecture only. There is no runtime implementation in
> this release** — no trust engine, no enrollment, no certificate handling, no
> approval workflow, no fabric. This document plus the four schemas are the
> specification; a future engineer should be able to build the Trust Plane from
> them without inventing behaviour. Where something is undecided, this ADR says
> so explicitly rather than leaving a gap to be filled by whoever implements it
> first.

## Context

During supervised validation of v0.9.0, the platform was asked to collect facts
from a real host for the first time. It refused. The host's SSH identity had
never been explicitly trusted, so the collection stopped before any connection
was attempted, and the operator was told exactly what to do about it.

Nothing was broken. That was the design working: **trust had to be established
by a human, out of band, and the platform had no path to establish it for
itself.**

That refusal is the most important event in the platform's history so far,
because it exposed something the architecture had been getting right by
accident. Trust decisions already existed — in `known_hosts` files, in an
approved-plugin registry, in a code-owned command catalog, in a target file's
`allowed_operation_ids` — but they were scattered across the layers that
happened to need them, in different formats, with different lifetimes, and with
no shared way to answer four questions:

- **Who decided this is trusted?**
- **On what evidence?**
- **For how long, and for what?**
- **How is it withdrawn?**

A platform that cannot answer those uniformly does not have a trust model. It
has a collection of habits that resemble one, and habits degrade quietly: the
first `StrictHostKeyChecking=no` during an incident, the first plugin added
without review because it was urgent, the first model swapped in because the
old one was slow.

The pressure to degrade will increase, not decrease. v0.9.5 will let the
platform use machines it does not own. v1.0.0 will make Kyri a governed core
with replaceable capabilities. Every one of those capabilities is something
that must be trusted before it is used, and each will arrive with a good reason
why its particular case should be easy.

## Decision

Trust becomes a **first-class governed layer**: the **Trust Plane**, beside
Observation, Knowledge, Integrity, Experience, and Occurrence.

> **Kyri shall never silently trust anything.**

### Directionality

**Reasoning may consume trust. Trust never consumes reasoning.**

A knowledge state may take trust into account — refusing to act on a fact from
a quarantined collector is exactly the sort of judgement the knowledge layer
exists to make. But no inference, pattern, baseline, or model output may
produce, raise, or restore a trust state.

This is not a stylistic preference. A trust plane that consumes reasoning can
be argued into trusting something: a model that concludes a host is probably
fine, a baseline that observes a plugin has behaved acceptably, a pattern that
notes a certificate has been accepted many times before. Each is a plausible
signal and none is an authority. Trust must come from outside the system that
benefits from it.

Concretely: `TRUSTS`, `VERIFIED_BY`, and `APPROVED_BY` may not take a
`knowledge-event`, `knowledge-state`, `experience-profile`,
`operational-baseline`, `pattern`, or `occurrence-series` as their source.
Reasoning records may reference trust records; trust records may not be derived
from them.

### Design principles

1. **Trust is explicit.** It is granted by a decision that names a subject, not
   inferred from behaviour, availability, or prior success.
2. **Trust is immutable.** A trust record is never edited. A change is a new
   record superseding the old one, and both remain readable.
3. **Trust is reviewable.** A human can read what is trusted, why, and on whose
   authority, without reconstructing it from logs.
4. **Trust is explainable.** Every decision carries a written reason. "It was
   already there" is not a reason.
5. **Trust is revocable.** Every grant has a withdrawal path that takes effect
   without deleting the history of the grant.
6. **Trust is versioned.** Records carry a version and a supersession chain, so
   "what did we trust in March" has an answer.
7. **Trust never auto-enrolls.** No component may add a subject to the trusted
   set as a side effect of encountering it.
8. **Trust never auto-recovers.** A revoked, quarantined, or expired subject
   does not return to trusted because the condition that caused the change went
   away.
9. **Trust never assumes.** The absence of a record is `Unknown`, never
   `Trusted`, and `Unknown` fails closed.
10. **Trust always has provenance.** Every record names its source, its actor,
    and the evidence behind it.

### Definitions

**Trust Authority.** The entity permitted to make trust decisions within one or
more domains. An authority declares which domains it covers, which states it may
assign, what approval it requires, and how often its own grants must be
reviewed. An authority may not approve its own trust record; something else must
establish it. Schema: `TAUTH-0000`.

**Trust Decision.** One act of judgement, at one moment, by one actor, producing
one state for one subject. Immutable. It is the only thing that can change a
trust state, and it records everything needed to re-examine it later. Schema:
`TDEC-000000`.

**Trust Record.** The current standing of one subject in one domain: what it is,
what state it holds, under which authority, and which decision put it there. A
record is superseded, never edited. Schema: `TRUST-000000`.

**Trust State.** One of eight values describing standing. Defined below.

**Trust Source.** Where the assertion originated — an operator, a signed
release, an offline certificate authority, a hardware token, a documented
out-of-band verification. A source is not the same as an actor: the actor
performs the decision, the source is what they relied on.

**Trust Verification.** The method by which evidence was checked, recorded as a
named method rather than a free-text claim. A fingerprint compared over a
separate channel is a different quality of verification from a fingerprint read
from the connection being verified, and the record must be able to tell them
apart.

**Trust Revocation.** A decision moving a subject to `Revoked`. Revocation is
terminal for that record: the subject may be trusted again only by a new
decision producing a new record, with its own evidence. Revocation never deletes
anything.

**Trust Scope.** The bounded set of things a grant permits. Trust is never
global. A host trusted for observation is not thereby trusted for placement; a
model trusted for summarisation is not trusted for decisions.

**Trust Domain.** The category of subject being trusted. Fifteen are defined,
listed below. Domains exist so that a grant in one category cannot silently
extend to another.

**Trust Boundary.** The line across which a subject's assertions stop being
taken at face value. Every domain names its boundary explicitly — what the
platform accepts from the subject, and what it refuses regardless of state.

**Trust Evidence.** The material a decision rested on: a fingerprint, a
signature, a checksum, an attestation, a review record. Evidence is referenced,
never inlined as credential material.

**Trust Approval.** The human act authorising a decision, recorded with the
approving identity and the approval source. Approval is distinct from the
decision itself so that "who pressed the button" and "who authorised it" can
differ and both are recorded.

**Trust Expiration.** The time after which a grant is no longer valid. Expiry
moves a record to `Expired` and is not a renewal trigger — an expired subject
requires a new decision, not an automatic extension.

**Trust Review.** The scheduled re-examination of an existing grant. Review does
not extend trust by itself; it produces a decision, which may reaffirm, restrict,
or revoke. A grant that is never reviewed is a grant nobody has looked at since
the day it was made.

**Trust History.** The ordered chain of decisions affecting a subject. Append
only. It answers "what did we trust, when, and who changed it" and is the reason
none of the other structures need to be editable.

### Trust states

Eight states. **Unknown is the default state, and it fails closed.**

| State | Meaning | Reached by |
|---|---|---|
| `Unknown` | No record exists. The platform knows nothing about this subject. | Default for everything |
| `Pending` | A decision has been requested but not made. Fails closed exactly like `Unknown`. | Submission for review |
| `Trusted` | Explicitly approved, in scope, unexpired. | An approving decision |
| `Restricted` | Trusted for a narrower scope than requested. | A decision granting less than asked |
| `Quarantined` | Previously trusted, temporarily withheld pending investigation. | A decision, never automatically |
| `Revoked` | Trust withdrawn, terminal for this record. | A revoking decision |
| `Expired` | The grant's expiration has passed. | Time, against a recorded expiration |
| `Rejected` | A request for trust was considered and refused. | A refusing decision |

`Pending` deliberately behaves as `Unknown` rather than as provisional trust.
A state that is "not yet trusted but usable" is trust on first use with a
waiting period.

Only `Expired` may be entered by the passage of time. Every other transition
requires a decision. **No state transition may be automatic**, and in particular
nothing returns to `Trusted` without a new decision — see principle 8.

### Trust domains

Fifteen domains, each with its own boundary, enumerated in
[the domain document](../trust/trust-domains.md) and in the `trust-record`
schema: host, SSH host key, certificate, user, collector plugin, capability
package, model, model adapter, prompt bundle, embedding model, index, policy,
configuration snapshot, remote transport, and fabric node.

A subject in one domain is never automatically a subject in another. Trusting a
host does not trust the SSH host key that identifies it; trusting a model does
not trust the prompt bundle used with it.

### Every trust decision records

| Element | Purpose |
|---|---|
| **Identifier** | Stable reference for the decision itself |
| **Actor** | Who performed it |
| **Timestamp** | When, with a timezone offset |
| **Reason** | Written justification, not a code |
| **Evidence** | What was checked, by reference |
| **Verification Method** | How it was checked |
| **Approval Source** | Who authorised it, and on what basis |
| **Scope** | What the grant covers, bounded |
| **Expiration** | When it stops being valid |
| **Current State** | The resulting state |
| **History** | The prior state and the chain it belongs to |

A decision missing any of these is not recordable. The schema requires all of
them, so an incomplete decision cannot be written and later explained away.

### Explicitly forbidden

Each of these is individually convenient. That is why each is named rather than
left to judgement.

- **Automatic trust** — nothing becomes trusted as a side effect of anything.
- **Trust on first use** — the first time a subject is seen is not evidence.
- **Automatic ssh-keyscan** — reading a key from the connection you are trying
  to verify proves nothing about it.
- **Automatic known_hosts updates** — no component writes to a known-hosts
  file; a changed key is an event for a human.
- **Automatic certificate acceptance** — expiry, rotation, and reissue are
  decisions, not maintenance.
- **Automatic model approval** — a new model version is a new subject.
- **Automatic capability approval** — a capability package is trusted by review,
  not by successful installation.
- **Automatic policy changes** — a policy that can rewrite itself is not a
  policy.
- **Automatic recovery** — nothing returns to `Trusted` because a problem
  stopped being visible.

## Rejected Alternatives

**Trust on first use.** The standard answer, and the reason it is standard is
that it makes the first connection painless. It also means the platform's entire
trust model can be established by whoever answers first — which, on the one
occasion it matters, is the attacker.

**Per-layer trust, left where it already lives.** Cheapest option: `known_hosts`
for hosts, a registry for plugins, a catalog for operations. It is where the
platform already was. The four questions in the Context have four different
answers per layer, and nobody can audit the whole picture, which is how a
platform ends up unable to say what it trusts.

**Trust scores.** A number expressing degree of trust, computed from behaviour.
Attractive because it degrades gracefully and terrible for the same reason: a
threshold nobody chose becomes the security boundary, and a subject can raise
its own score by behaving well until it matters. Trust here is categorical, and
the categories are decided.

**Reputation from observed behaviour.** The platform already records occurrence,
experience, and integrity — it would be easy to let a long clean history confer
trust. This is precisely the direction the directionality rule forbids. A
compromised subject's most likely behaviour is to look normal.

**Automatic expiry renewal.** Re-granting a grant that has not visibly gone wrong
seems harmless, and turns expiration into a formality. An expiry that renews
itself measures nothing. Expiry exists to force a look.

**Trust inheritance between domains.** Trusting a host and thereby its host key,
its transport, and its services. Convenient, and it means a single decision has
consequences nobody enumerated. Each domain is entered explicitly.

**Editable trust records.** Fixing a typo in a reason, correcting a scope. An
editable record is an audit trail that can be rewritten after the fact, which is
the one property an audit trail must not have. Corrections are supersessions.

**Deleting revoked records.** Keeping the store clean. The revocation is the
most interesting thing in the history, and a store containing only current
grants cannot answer what was trusted last month.

**A trust engine in this release.** The strongest temptation: the design is
written, the schemas exist, and building it would take days. A partially built
trust engine is worse than none — it reads as a control while behaving as a
suggestion, and every layer above would start depending on guarantees it does
not yet make. Architecture ships first, deliberately.

**Deferring the whole question until the Fabric needs it.** Building trust
alongside the thing that needs it would let the fabric's convenience shape the
trust model. Governance built to accommodate a feature accommodates the feature.

## Consequences

**Positive.** The platform gains one place to ask what is trusted, by whom, on
what evidence, and until when. Revocation becomes a defined operation rather
than an edit. The v0.9.5 Fabric inherits a trust model it did not get to shape.
The four scattered mechanisms already in use — `known_hosts` references, the
plugin registry, the operation catalog, target allowlists — gain a common
vocabulary they can be migrated onto deliberately.

**Negative.** Everything becomes slower to add. A new model, plugin, host, or
node requires a decision with evidence, an authority, and a scope, and there is
no fast path. This will be felt first during an incident, which is exactly when
the pressure to add one will be strongest and the reason to refuse strongest.

**Migration is not free and is not attempted here.** The existing mechanisms
keep working unchanged in this release. Bringing them under the Trust Plane is
future work, and doing it during a feature sprint would put the riskiest change
in the least appropriate place.

**Accepted risks.**

- **A specification is not a control.** Nothing in this release enforces
  anything. Until the Trust Plane is implemented, the guarantees described here
  are intentions, and the static tests only assert the specification is complete
  and that no partial implementation has appeared.
- **The state model may prove too coarse or too fine.** Eight states are a
  judgement. `Restricted` and `Quarantined` in particular may turn out to
  overlap in practice, and the schemas allow a later ADR to narrow them.
- **Review intervals are unenforced.** The schemas require an interval to be
  declared; nothing yet notices when one lapses. That is implementation work,
  and it is the most likely place for the plane to quietly stop functioning.
- **Human approval is a bottleneck and a single point of failure.** If the
  approving authority is unavailable, nothing new can be trusted. This is
  accepted: the alternative is an automatic path, which is the thing being
  prevented.

## Relationship to the Distributed Capability Fabric

**The Distributed Capability Fabric cannot begin until the Trust Plane exists.**

v0.9.5 lets the platform place work on machines it does not own. Every question
the fabric asks is a trust question: may this node run this workload, may this
result be believed, may this endpoint see this data. Building the fabric first
would mean answering those questions inside the scheduler, which is how a
scheduler becomes the security boundary.

The rule extends once more: **no model is Kyri, no machine is Kyri, and no
node's self-report is trust.** A fabric node describes itself; the Trust Plane
decides whether that description is believed.

## Related

- [ADR-0002: Evidence-First Architecture](ADR-0002-evidence-first-architecture.md)
- [ADR-0003: Provider-Agnostic AI Architecture](ADR-0003-provider-agnostic-ai-architecture.md)
- [ADR-0004: Immutable Knowledge Timeline](ADR-0004-immutable-knowledge-timeline.md)
- [ADR-0010: Remote Read-Only Collection](ADR-0010-remote-read-only-collection.md)
- [Trust Plane overview](../trust/trust-plane.md)
- [Trust domains](../trust/trust-domains.md)
- [Trust states](../trust/trust-states.md)
