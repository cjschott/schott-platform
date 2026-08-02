# The Trust Plane

**Kyri shall never silently trust anything.**

The Trust Plane is how the platform decides that a machine, capability,
identity, model, collector, or transport is trusted — and how it records that
decision so it can be read, reviewed, and withdrawn.

> **Architecture only. Not yet implemented.** This release defines the Trust
> Plane; it does not build one. There is no runtime trust engine, no enrollment,
> no certificate handling, and no approval workflow. Until those exist, the
> guarantees described here are a specification, not a control. Implementation
> is reserved for **v0.9.2**.

Governed by [ADR-0011](../decisions/ADR-0011-trust-plane.md).

## Why this exists

During supervised validation of v0.9.0 the platform was asked to collect facts
from a real host for the first time, and it refused: the host's SSH identity had
never been explicitly trusted. The collection stopped before any connection was
attempted, and the operator was told exactly what to do.

That refusal is why this layer exists. It showed the trust boundary working —
and it showed that the platform's trust decisions were scattered across the
layers that happened to need them, with no shared way to answer four questions:

- Who decided this is trusted?
- On what evidence?
- For how long, and for what?
- How is it withdrawn?

## Where it sits

The Trust Plane is a governed layer beside the others, not beneath them:

```
Reality
   ↓
Observation → Knowledge → Integrity → Experience → Occurrence
   ↑                                                    ↑
   └──────────────── Trust Plane ───────────────────────┘
                (consulted, never derived)
```

### The directionality rule

**Reasoning may consume trust. Trust never consumes reasoning.**

A knowledge state may take trust into account — declining to act on a fact from
a quarantined collector is exactly the judgement the knowledge layer exists to
make. But no inference, pattern, baseline, or model output may produce, raise,
or restore a trust state.

A trust plane that consumes reasoning can be *argued into* trusting something: a
model concluding a host is probably fine, a baseline observing that a plugin has
behaved acceptably, a pattern noting a certificate has been accepted many times
before. Each is a plausible signal. None is an authority. A compromised
subject's most likely behaviour is to look normal.

This is enforced structurally: `TRUSTS`, `VERIFIED_BY`, and `APPROVED_BY` may
not take a `knowledge-event`, `knowledge-state`, `experience-profile`,
`operational-baseline`, `pattern`, or `occurrence-series` as their source.

## The four entities

| Entity | Identifier | What it is |
|---|---|---|
| **Trust Record** | `TRUST-000000` | Current standing of one subject in one domain |
| **Trust Decision** | `TDEC-000000` | One act of judgement producing one state |
| **Trust Authority** | `TAUTH-0000` | Who may decide, in which domains |
| **Trust Policy** | `TPOL-0000` | Defaults, permitted transitions, review cadence per domain |

All four are **immutable**: no update method, no delete method, superseded by a
new record only. A correction is a supersession. An editable trust record is an
audit trail that can be rewritten after the fact, which is the one property an
audit trail must not have.

## What every decision records

Eleven elements, all mandatory. A decision missing any of them cannot be
written, so an incomplete decision cannot be recorded now and explained away
later.

| Element | Purpose |
|---|---|
| Identifier | Stable reference for the decision |
| Actor | Who performed it |
| Timestamp | When, with a timezone offset |
| Reason | Written justification, not a code |
| Evidence | What was checked, by reference |
| Verification Method | How it was checked |
| Approval Source | Who authorised it |
| Scope | What the grant covers, bounded |
| Expiration | When it stops being valid |
| Current State | The resulting state |
| History | Prior state and the chain it belongs to |

**Reason is free text and required.** An enum here would let "it was already
there" become a valid justification.

**Evidence is referenced, never inlined.** Evidence identifies what was checked;
it is not a place to store the thing itself. No trust record carries a private
key, password, passphrase, or token — the record says a subject was verified,
never how to authenticate as it.

## Scope: trust is never global

A grant covers a bounded set of things. A host trusted for observation is not
thereby trusted for placement. A model trusted for summarisation is not trusted
for decisions. Unbounded scope is refused at the schema level.

Domains do not inherit from one another. Trusting a host does not trust the SSH
host key that identifies it, and trusting a model does not trust the prompt
bundle used with it. See [trust domains](trust-domains.md).

## Expiration and review

Every grant is time-bounded. **Expiry is not a renewal trigger** — an expired
subject requires a new decision, not an automatic extension. An expiry that
renews itself measures nothing; expiry exists to force a look.

**Review does not extend trust by itself.** A scheduled review produces a
decision, which may reaffirm, restrict, or revoke. A grant that is never
reviewed is a grant nobody has looked at since the day it was made.

## Revocation

Revocation is a decision moving a record to `Revoked`. It is **terminal for that
record**: the subject may be trusted again only by a new decision producing a
new record, with its own evidence.

Revocation never deletes anything. A store containing only current grants cannot
answer what was trusted last month, and the revocation is usually the most
interesting entry in the history.

## Explicitly forbidden

Each is individually convenient. That is why each is named rather than left to
judgement.

| Forbidden | Why |
|---|---|
| **Automatic trust** | Nothing becomes trusted as a side effect of anything |
| **Trust on first use** | The first time a subject is seen is not evidence — on the one occasion it matters, whoever answers first is the attacker |
| **Automatic `ssh-keyscan`** | Reading a key from the connection you are verifying proves nothing about it |
| **Automatic `known_hosts` updates** | A changed key is an event for a human, not maintenance |
| **Automatic certificate acceptance** | Expiry, rotation, and reissue are decisions |
| **Automatic model approval** | A new model version is a new subject |
| **Automatic capability approval** | Trusted by review, not by successful installation |
| **Automatic policy changes** | A policy that can rewrite itself is not a policy |
| **Automatic recovery** | Nothing returns to `Trusted` because a problem stopped being visible |

There are also **no trust scores**. A number computed from behaviour makes a
threshold nobody chose into the security boundary, and lets a subject raise its
own standing by behaving well until it matters. Trust here is categorical, and
the categories are decided.

## What this costs

Everything becomes slower to add. A new model, plugin, host, or node requires a
decision with evidence, an authority, and a scope, and there is no fast path.

This will be felt first during an incident — which is exactly when the pressure
to add a fast path is strongest, and the reason to refuse is strongest.

Human approval is also a bottleneck and a single point of failure. If the
approving authority is unavailable, nothing new can be trusted. That is
accepted: the alternative is an automatic path, which is the thing being
prevented.

## Migration is not attempted here

The platform already makes trust decisions: `known_hosts` references, the
collector plugin registry, the code-owned operation catalog, and a remote
target's `allowed_operation_ids`. **All of them keep working unchanged.**

Bringing them under the Trust Plane is future work. Doing it during a feature
sprint would put the riskiest change in the least appropriate place.

## Relationship to the Distributed Capability Fabric

**The Distributed Capability Fabric (v0.9.5) cannot begin until the Trust Plane
exists.**

Every question the fabric asks is a trust question: may this node run this
workload, may this result be believed, may this endpoint see this data. Building
the fabric first would mean answering those inside the scheduler — which is how
a scheduler becomes the security boundary.

The rule extends: **no model is Kyri, no machine is Kyri, and no node's
self-report is trust.** A fabric node describes itself; the Trust Plane decides
whether that description is believed.

## Related

- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [Trust domains](trust-domains.md)
- [Trust states](trust-states.md)
- [ADR-0010: Remote Read-Only Collection](../decisions/ADR-0010-remote-read-only-collection.md)
- [Remote Read-Only Collection](../collectors/remote-collection.md)
