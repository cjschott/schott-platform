# Unknown Health and Freshness

**Architecture only.** Nothing here is implemented. Governed by
[ADR-0013](../decisions/ADR-0013-capability-health-plane.md).

The two rules this layer is most likely to be quietly broken on.

## Unknown is inert on eligibility, and never invisible

**Inert.** An `unknown` health state changes no routing decision. It does not
remove a candidate, and it does not add one.

**Never invisible.** It must appear in every explanation of every selection
that touched it. An `unknown` nobody sees is indistinguishable from a `healthy`
one at exactly the moment the difference matters.

These two together are the design: health is **fail-closed on claims and inert
on eligibility**.

## Unknown cannot support a positive claim

An `unknown` **cannot support a healthy claim**, and it **cannot clear** a
prior finding:

| Prior state | New evidence | Result |
|---|---|---|
| `degraded` | none arrives | stays `degraded`, freshness ages |
| `unavailable` | none arrives | stays `unavailable`, freshness ages |
| any | collection fails | `unknown` — but the prior finding is not cleared |

**Silence is not recovery.** A subject that stops reporting has not recovered;
it has stopped reporting. Only a fresh, positive observation moves a subject
back toward `healthy`.

## Absence of evidence is never a positive claim

An `unknown` must **never** be serialised, rendered, or summarised as any of:

- **assumed healthy**
- **probably available**
- **no known issues**
- **healthy by default**

Each converts an absence of evidence into a claim about the subject. These are
declared as forbidden renderings on the health-state schema rather than
discouraged in prose, because this is precisely the wording a dashboard reaches
for when a tile has nothing in it.

## Unknown must carry freshness and a reason

Every health state carries both, `unknown` included.

- **Must carry freshness** — `current`, `aging`, `stale`, or `unknown`. A state
  without an age is not an assessment.
- **Must carry a reason** — written, not a code. An `unknown` with no reason is
  indistinguishable from one nobody looked at, and an operator cannot tell
  "the collector failed" from "this subject has no collector" without it.

## A worked example

What a future runtime must be able to produce for a trusted, Fabric-eligible
capability with no fresh health evidence:

```yaml
eligible_by_fabric: true          # Trust and Fabric permitted it
health_state: unknown             # health has nothing fresh to say
health_effect: none               # inert: health changed nothing
health_warning: no fresh health evidence
```

The selection proceeds, because Trust and the Fabric permitted it. It states
plainly that **no fresh health claim supported the choice**. Both halves are
required: proceeding silently would imply health had agreed.

## Freshness

### A state is inseparable from its freshness

Reuses the four states from the
[Confidence and Freshness Standard](../standards/confidence-freshness-standard.md):
`current` · `aging` · `stale` · `unknown`.

### Stale evidence cannot support healthy

A `healthy` reading whose evidence has aged past its declared policy is no
longer a `healthy` reading. It becomes `unknown`, with the stale evidence
cited.

**A stale `degraded` never silently becomes `healthy`.** The finding stands
until fresh evidence contradicts it. Ageing out of a problem is not the same as
fixing it.

### Two freshnesses exist, and they are not the same

A health state carries a freshness, and a consumer needs one. **They are
different facts and must not be confused.**

- **Stored on the record: freshness at `evaluated_at`.** A historical fact about
  what the evidence looked like when the assessment was made. That is what an
  incident review needs, and it is why the record stores it.
- **Computed at the moment of use: freshness now.** Anything deciding anything
  **recomputes** freshness from each cited observation's `observed_at` against
  that dimension's declared policy and the caller's evaluation instant.

**A stored `freshness: current` never remains operationally current.** Nothing
may read the stored label to decide whether a candidate is subtracted. If it
could, a dead collector would freeze a favourable assessment permanently and a
six-month-old `healthy` would keep reading as fresh.

A state whose evidence has aged past policy contributes **no subtraction** — and
still does not become `healthy`, and still does not clear its finding. Ageing out
of a problem is not the same as fixing it, in either direction.

Derivation itself is **explicitly invoked and append-only**: every evaluation
writes a new state carrying its own `evaluated_at`, and there is no background
writer.

### Unknown carries a review flag when the policy is missing

The Null Policy Rule is inherited **exactly**, and the standard it comes from
requires `freshness: unknown` to arrive **with `review_required: true`** — never a
default maximum age. A state carries that flag when it arises from a null
freshness policy, from `insufficient-policy`, or from contradicting sources, with
its written reason naming **which** gap, because "review required" without a
subject is an alert rather than a finding.

The flag is **stored**, not derived when read. An envelope is superseded rather
than edited, and a later version declaring the missing policy must not
retroactively clear the flag on a past assessment — that is the same rule as
"supersession never rewrites prior evaluations".

### Freshness is evaluated independently per observation

Each dimension carries its own freshness policy, so a subject may hold current
latency evidence and stale availability evidence at once. Collapsing them to a
single age would hide whichever dimension stopped reporting — which is the one
worth knowing about.

### Collection failure is not capability failure

A collector that cannot reach a subject records `collection_status: failed`. It
concludes nothing.

**Missing evidence is not capability failure either.** A subject nobody has
measured is `unknown`, not broken.

**Stale evidence is not fresh evidence.** It is not discarded — it is cited,
with its age — but it cannot carry a current claim.

## Fresh healthy overrides nothing

A perfectly fresh `healthy` state overrides none of the following. Health
subtracts from what other layers allowed; it never adds.

| It cannot override | Which is owned by |
|---|---|
| **manual drain** | The Fabric operator |
| **restricted scope** | The Trust Plane |
| **quarantine** | The Trust Plane |
| **revocation** | The Trust Plane |
| **Fabric availability intent** (`availability_intent`) | The Fabric operator |

A quarantined subject reporting `healthy` is quarantined. A drained node
reporting `healthy` stays drained.

## "No subtraction" is not "eligible"

The sentence this document is most likely to be misread on.

Health fails closed **on the claim**. Where Trust fails closed by *denying
authority* — a trust failure removes eligibility — Health has no authority to
deny, so unreadable, unavailable, malformed, unverifiable, stale, `unknown`,
`unmonitored`, `insufficient-policy` and `withheld` evidence all produce the same
outcome: **Health contributes no subtraction.**

**That is not a statement about eligibility.** Eligibility was never Health's to
confer. Trust standing, the eligibility conditions, quarantine,
`availability_intent`, restricted scope and revocation all decide it
independently, and every one is evaluated **before** health is consulted. A
candidate Health did not remove may be ineligible for any of them.

An attacker who can corrupt, block or forge Health therefore gains **neither a
grant nor a denial**. Absent or unusable evidence can produce no positive claim —
no `healthy`, no "assumed healthy" — and no negative one either. That symmetry is
the whole point: if malformed health removed candidates, corrupting the store
would empty every route, and the observability layer's blast radius would exceed
that of the thing it observes.

## Related

- [Health states](health-states.md)
- [Observation model](observation-model.md)
- [Selection visibility](selection-visibility.md)
- [Worked examples](worked-examples.md)
- [Confidence and Freshness Standard](../standards/confidence-freshness-standard.md)
