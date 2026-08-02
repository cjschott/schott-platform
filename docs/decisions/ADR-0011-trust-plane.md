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

### The external root rule

**Every trust chain must terminate at an external Operator Root Authority that
is not established, approved, or modified by Kyri itself.**

A chain that terminates inside the platform is circular: the system asserts its
own trustworthiness, and the assertion is worth exactly what the system is worth
if it has been compromised. The root is outside so that compromising Kyri does
not compromise the ability to say what Kyri may trust.

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

**Operator Root Authority.** The authority every trust chain terminates at.

- **External to Kyri.** It is not a component of this platform.
- **Human-controlled.**
- **Established through an out-of-band process**, outside any system it governs.
- **Not created, approved, or modified by Kyri itself.** A platform that can
  establish its own root authority has no root authority — it has a variable.
- **Terminates every trust chain.** Follow any `APPROVED_BY` edge far enough and
  it ends here.
- **May approve, restrict, quarantine, revoke, reject, and supersede** trust.
- **Every action produces immutable history**, exactly like any other decision.
- **Cannot silently self-delegate.** Delegation requires a recorded trust
  decision, so an authority's reach is always readable.

**The concrete external identity is deliberately not named here.** Binding a
specific person, account, key, or address into an architecture document creates
an identity that outlives whoever currently holds it, and turns a role into a
name that must be edited — in an immutable record — when the person changes.
ADR-0011 defines the *role* and its invariants; the **v0.9.2 implementation
binds the concrete external identity**, where it can be superseded like any
other record.

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

Every verification records a `verification_method` **and**
`verification_details`, plus **at least one immutable trust-evidence
reference**. A method name alone says a check happened without saying what was
checked, which is unreviewable a year later.

For **out-of-band-physical-verification** — the strongest and most easily
faked-up claim, because it rests entirely on what a human says they did — the
details must record all five of:

| Field | Records |
|---|---|
| `subject_property` | **What property was verified** (for example, a host key fingerprint) |
| `observed_value_reference` | **Where it was observed**, by reference |
| `comparison_source` | **Which independent channel** it was compared against, and what approved value or evidence |
| `performed_by` | **Who performed the comparison** |
| `performed_at` | **When it occurred**, as a timezone-aware ISO 8601 timestamp |

`performed_at` requires an offset because a time without a zone is not a point
in time, and the whole value of this record is being able to place the check.

Sensitive raw values are **referenced, never embedded**. The record proves a
comparison was made; it is not a copy of the material compared.

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

| State | Meaning | Usable? |
|---|---|---|
| `Unknown` | No approved trust decision exists. Fail closed. | No |
| `Pending` | A decision is awaiting review. Operationally equivalent to `Unknown`. | No |
| `Trusted` | Approved for the recorded scope. | Yes, within scope |
| `Restricted` | Identity is trusted, but authority or use is deliberately limited to an explicit non-empty scope. | Yes, within that scope |
| `Quarantined` | Identity, integrity, provenance, or behaviour is suspect. Normal use is forbidden. | No |
| `Revoked` | Previously granted trust was explicitly withdrawn. | No |
| `Expired` | Trust ceased solely because its approved time boundary elapsed. | No |
| `Rejected` | A proposed trust decision was considered and denied; trust was never granted under that decision. | No |

`Pending` deliberately behaves as `Unknown` rather than as provisional trust.
A state that is "not yet trusted but usable" is trust on first use with a
waiting period.

#### Restricted: limited authority, not suspicion

**Restricted is a governance decision, not evidence of compromise.** The
subject's identity is trusted; what it is permitted to do has been
deliberately limited.

- A `Restricted` record **requires a non-empty scope**. A restriction that
  bounds nothing is a `Trusted` record with a misleading label.
- The subject may be used, but **only inside that explicit scope**.
- **Broadening the scope requires a new approval and a new trust decision.**
  Scope expansion is the moment a restriction stops being one, so it gets the
  same scrutiny as the original grant.
- `Restricted` **never automatically returns to** `Trusted`.

**Restricted is not equivalent to Quarantined.** One says "we deliberately gave
it less authority"; the other says "we are worried about it". Reporting either
as the other destroys the distinction an operator needs during an incident.

#### Quarantined: suspect, pending investigation

**Quarantined means identity, integrity, provenance, or behaviour is suspect
and requires investigation.**

- **Normal capability use is forbidden.** A quarantined subject is not usable
  for ordinary work of any kind.
- Only **explicitly approved verification or investigation activity** may occur
  — the actions needed to resolve the question, and nothing else.
- **Quarantine does not itself mean `Revoked`.** It is a withheld state pending
  an answer, not a withdrawal. **Quarantine is not permanent revocation.**
- A quarantined subject **cannot automatically return to a usable state**.
  Moving to `Trusted` or `Restricted` requires a new trust decision.

**Quarantined is not equivalent to Restricted.**

#### Rejected versus Revoked

These are permanently distinct historical meanings, and the difference is about
whether trust ever existed.

- **`Rejected`** — approval was considered and denied. The subject **never
  became trusted** under that decision. There is no grant to withdraw, because
  none was made.
- **`Revoked`** — **previously granted** trust was explicitly withdrawn. A grant
  existed, was relied upon, and was taken away.

A revoked subject **does not return to** `Trusted`. Later approval after
revocation creates a **new trust lineage**: a new record, with its own evidence
and approval, which references the revoked record but **does not mutate** it.
The revoked record remains exactly as written, because it is usually the most
interesting entry in the subject's history.

#### Transition rules

- **Only `Expired` may occur automatically**, through the passage of time
  against a recorded boundary.
- **Every other transition requires a new decision.**
- **No transition mutates prior records.** Change is supersession.
- **No usable state is restored automatically** — see principle 8.
- **Restricted scope expansion requires approval.**
- **Quarantine exit requires a new decision.**
- **Revoked trust cannot be reactivated**; future approval creates a new
  lineage.
- **`Rejected` and `Revoked` remain permanently distinct** in the history.

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
