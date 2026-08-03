# Trust Plane Runtime Overview

v0.9.2 defined the Trust Plane and deliberately built nothing. This release
makes those guarantees refusals rather than intentions.

> **Kyri shall never silently trust anything.** Everything here fails closed:
> where a state is unknown, missing, malformed, or unreadable, the answer is
> denial with a written reason — never a default, never a guess, never a score.

Governed by [ADR-0011](../decisions/ADR-0011-trust-plane.md). See also
[root authority operations](root-authority-operations.md),
[state transitions](state-transition-runtime.md), and the
[query reference](trust-query-reference.md).

## Store layout

The trust store lives **outside the repository**. A store root inside a git
repository is refused, so generated records cannot land in tracked source.

```
<store-root>/
  authorities/          TAUTH-000001.yaml
  records/              TREC-000001.yaml
  decisions/            TDEC-000001.yaml
  evidence-references/  TEVID-000001.yaml
  lineages/             TLIN-000001-v0001.yaml
  audit/                TAUDIT-000001.yaml
  sequences/            per-kind identifier counters
  indexes/              append-only pointers
```

Directories are `0700`, files `0600`. Writes go to a temp file and then
`os.link`, so committing a write and refusing an overwrite are the same atomic
operation. There is no update method and no delete method — not disabled, absent.

Lineage files carry a version because **a lineage advances by writing a new
version, never by editing the previous one**. The head is whichever version is
highest.

> **Sequence allocation is single-host only.** Identifier allocation uses
> `fcntl.flock`, which does not coordinate across machines. A store shared over
> a network filesystem could allocate duplicate identifiers. This is documented,
> not solved.

## Stored versus effective state

Two different questions, and conflating them would report a grant as live after
its boundary elapsed.

- **Stored state** is what the record says. It never changes.
- **Effective state** is what the record means at an explicit moment.

They differ only through expiry. A record stored as `trusted` with an
expiration in the past is effectively `expired`, and the evaluation says so —
without writing anything.

No core function reads the wall clock. The caller supplies `evaluated_at`, so
answers are reproducible rather than a race, and the CLI requires
`--evaluated-at` for every time-sensitive read.

## What the runtime enforces

| Rule | Enforcement |
|---|---|
| Unknown and Pending fail closed | No usable state; every activity denied |
| Restricted is usable only inside scope | Deny-by-default on all four dimensions |
| Quarantined forbids normal use | Only explicitly named verification operations |
| Revoked cannot be reactivated | Terminal within its lineage |
| Rejected means never granted | Terminal; cannot follow a granted trust |
| Only Expired occurs automatically | Every other transition needs a decision |
| Every chain terminates externally | Decisions require the active operator root |

## Failure semantics

Three exit codes, and the distinction matters mid-incident:

- **0** — the command succeeded.
- **1** — trust answered, and the answer was no. The store is fine.
- **2** — the invocation or store was unusable.

Collapsing 1 and 2 would make "denied" indistinguishable from "misconfigured".

Every denial carries written reasons. A denial with no reason is unusable at
exactly the moment it matters.

Queries fail closed in three distinct ways, each explained: a subject with no
lineage, a lineage head citing a decision with no record, and a record that
cannot be interpreted all evaluate to `unknown`.

## Validation repairs nothing

`validate-store` reports structural problems and fixes none of them. Records are
immutable, so a malformed one can only be superseded — which is why validation
is a command rather than an afterthought.

It detects multiple active roots, unresolvable authorities, decisions with no
lineage, dangling and self-referential supersession, duplicate identifiers,
records citing unknown decisions, and temp residue from a failed write.

## Non-goals

Explicitly **not** implemented in this release, and not partially implemented
either:

- SSH host-key enrollment, `known_hosts` modification, certificate enrollment
- Model approval workflows, collector approval migration
- Root authority supersession, delegated (non-root) authorities
- Automatic trust, trust on first use, trust scores, automatic recovery
- Remediation or repair of any kind
- Any use of a model or reasoning layer to interpret trust

## Migration is still deferred

The platform's existing trust mechanisms — `known_hosts` references, the
collector plugin registry, the code-owned remote operation catalog, and target
`allowed_operation_ids` — **keep working unchanged and are not migrated here**.

Until they are, the platform has two trust systems and only one of them is
enforced by this runtime. That is the most important limitation to hold onto
when reading anything below.

## The Fabric is still blocked

v0.9.5 remains blocked. This release supplies the root authority, transitions,
scope, quarantine, revocation lineage, and query service the gate requires — but
the migration above is outstanding, and a fabric node is trusted through the
same mechanisms that have not yet moved.

## Related

- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [The Trust Plane](trust-plane.md)
- [Trust states](trust-states.md)
- [Trust domains](trust-domains.md)
