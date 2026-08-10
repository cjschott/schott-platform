# Capability Runtime Design (ENG-0005)

**Status:** Draft — awaiting review

> **This document specifies architecture and scope only. It authorises no
> implementation.** No runtime source, scaffolding, executable schema,
> placeholder, or runtime test accompanies it. ENG-0005 implementation begins
> only when this specification is accepted **and** its own test-first plan,
> feature branch, review, and release boundary exist.

Builds on the released [Fabric Runtime](2026-08-04-fabric-runtime-design.md)
(ENG-0004, `v0.10.0`) and settles the execution model its §3 assigned to
ENG-0005. It changes no accepted decision, no Fabric schema, and no Fabric
record kind.

## 1. Purpose

ENG-0004 answers *where may this run?* and stops. Its §3 draws the line in one
sentence:

> **ENG-0004 determines whether an already-described instance is governed,
> eligible, and deterministically selectable. ENG-0005 makes that instance
> executable and performs the capability invocation.**

The ownership boundary was settled there. The **mechanics** were not, and the
ENG-0005 discovery classified the gap as `DISCOVERY-C`: package execution,
invocation identity, persistence, and security boundaries were each
fundamentally unspecified. This document specifies them.

**Capability Runtime is the execution layer downstream of governed Fabric
selection.** It receives a decision that has already been made and carries it
out. It makes no governance decision of its own, and the whole of its design is
arranged so that it cannot.

## 2. Authority boundary

The authority chain is fixed and one-directional:

```
Operator Root Authority  (external, human, out of band)
  → Trust Authority
    → Trust Decision
      → Fabric governance
        → eligibility
          → route
            → CSEL
              → Capability Runtime execution precondition validation
                → invocation
```

**MUST**

- Capability Runtime MUST execute only the instance a governed `CSEL` selected.
- Capability Runtime MUST validate the execution preconditions of §6 before
  invoking, and MUST refuse when any is unmet.
- Capability Runtime MUST treat a `CSEL` as **necessary but not sufficient**.
  Its insufficiency is resolved by the concrete preconditions of §6 — facts
  about records and artefacts — never by a second policy decision.

**MUST NOT**

- MUST NOT select, re-select, or substitute an instance.
- MUST NOT call C5 as an execution authorisation step, or call C6 at all.
- MUST NOT create a `CSEL`, implicitly or otherwise.
- MUST NOT interpret Trust scope independently (§25).
- MUST NOT consult, derive, or act on health (§24).
- MUST NOT change Fabric state because an execution failed.
- An execution result MUST NOT produce, raise, or restore a Trust state, alter
  eligibility, or influence any later selection. **Nothing flows back up.**

## 3. Inputs

| Input | Origin | Supplied or read |
|---|---|---|
| Fabric `request_id` | the governed decision that produced the `CSEL` | **read** from `CSEL` evidence |
| `CSEL` identity | caller | **caller-supplied** |
| `CSEL` record | Fabric store | **read** |
| selected `CINST` identity | `CSEL.selected_instance_id` | **read** — never caller-supplied |
| `CINST` record | Fabric store | **read** |
| `CPKG` record | `CINST.capability_package_id` | **read** |
| `CCON` / `CAPDEF` metadata | `CINST.contract_id`, `capability_id` | **read** (effect class, shapes) |
| actor | caller | **caller-supplied** |
| invocation identity | caller | **caller-supplied**, opaque (§4) |
| execution payload | caller | **caller-supplied** |
| canonical payload digest | derived from the payload | **derived** — never caller-supplied |
| execution instant | caller | **caller-supplied**, timezone-aware |

**MUST** — the runtime MUST derive the selected `CINST` from the `CSEL`, never
accept it as an argument. A caller that could name the instance would be
selecting.

**MUST NOT** — the runtime MUST NOT accept a caller-supplied payload digest, a
caller-supplied effect class, or any caller-supplied value that a Fabric record
already carries. Anything readable from a record is read from it.

## 4. Invocation identity

Fabric request identity governs **decisions**. Invocation identity governs
**executions**. They answer different questions and MUST NOT be conflated.

**MUST**

- An invocation MUST carry an `invocation_id` that is **opaque,
  caller-supplied, and never parsed** — the same discipline §6 of the Fabric
  design applies to `request_id`. Bounded length, printable ASCII, compared as
  bytes.
- The runtime MUST allocate its own record identity separately, in its own
  store (§13), in the released six-digit form: `CINV-[0-9]{6}` for invocations
  and `CRES-[0-9]{6}` for results.
- An `invocation_id` MUST be unique within one Capability Runtime store.
- Every invocation record MUST carry the Fabric `request_id` of the decision
  that produced its `CSEL`, so an execution is traceable to its governance.

**MUST NOT**

- MUST NOT reuse, derive from, or overload the Fabric `request_id`.
- MUST NOT allocate `invocation_id` itself. An identity the runtime mints is
  one the caller cannot use to make a retry idempotent.

**Duplicate behaviour** is specified in §16.

## 5. Payload canonicalisation and binding

A Fabric selection governs a request **class**. Two entirely different payloads
of one class produce identical governance. Binding closes that gap.

**MUST**

- The runtime MUST derive a `payload_digest` from the execution payload by a
  deterministic canonicalisation, and MUST record it on the invocation.
- Canonical form MUST be: **UTF-8 encoded JSON**, object keys sorted by
  Unicode code point, no insignificant whitespace, no trailing newline,
  non-ASCII characters emitted literally rather than escaped.
- The digest MUST be **SHA-256**, recorded in the released `sha256:<hex>` form
  already used by `tools/integrity/snapshot_manager.py`.
- The digest MUST cover the payload **and** the values that bind it to its
  governance: `invocation_id`, `selection_id`, `instance_id`,
  `capability_package_id`, and `actor`. A payload alone would be re-presentable
  under a different selection.
- The runtime MUST recompute the digest from the payload it is about to pass to
  the adapter and MUST refuse on mismatch (§6, invalidator 10).

**MUST NOT** — the canonical form MUST NOT permit ambiguity: no floating-point
values, no duplicate keys, no unordered sets, no locale-dependent formatting,
no implementation-defined number representation. A payload that cannot be
canonicalised is refused, never approximated.

The same logical payload canonicalises identically; any change of value, key,
or binding produces a different digest.

## 6. Execution preconditions

These are **guards over facts**, not eligibility. They read records and
artefacts and compare them. They apply no policy, evaluate no condition class,
and reach no verdict that C5 or C6 already reached.

The runtime MUST refuse before invoking if any of the following is unmet:

| # | Precondition |
|---|---|
| 1 | the supplied `CSEL` exists and is structurally valid |
| 2 | the selected `CINST` identity in the `CSEL` matches the instance about to be invoked, exactly |
| 3 | every required Fabric record — `CSEL`, `CINST`, `CPKG`, `CCON`, `CAPDEF` — reads coherently through the released validated-read boundary |
| 4 | the selected `CINST` is in an execution-permitted lifecycle state (`admitted`; not withdrawn, retired, or superseded) |
| 5 | the applicable admission window has not expired at the supplied execution instant |
| 6 | the `CPKG` identity matches `CINST.capability_package_id` |
| 7 | the package artefact resolves through the approved containment mechanism and the artefact-reference grammar (§7) |
| 8 | the executable artefact matches its required integrity evidence (§8) |
| 9 | the contract's effect class is permitted for execution (§11) |
| 10 | the actual payload recomputes to the invocation's `payload_digest` (§5) |
| 11 | the `invocation_id` is valid and has not been consumed contrary to §16 |

**MUST NOT** — the runtime MUST NOT express any of these as "still eligible",
MUST NOT invoke C5 or C6 to answer them, and MUST NOT add a generic
`execution authority revoked` precondition, which would require querying or
reinterpreting Trust (§25).

**A refusal MUST NOT trigger reselection.** If a different target is needed,
that is a new governed Fabric decision with its own `request_id`, producing its
own `CSEL`.

## 7. Package resolution

**MUST**

- The runtime MUST resolve `CPKG.artifact_reference` through an **explicit
  grammar**, and MUST refuse any reference that does not match it.
- The initial accepted grammar is a single scheme:

  ```
  file:<relative-path>
  ```

  resolved beneath an operator-supplied **approved artefact directory**, named
  explicitly, with no default and no environment-derived value.
- Path resolution MUST use the shared containment primitive
  `tools/common/containment.contained_path`, so traversal, absolute paths
  outside the root, symlink escape, the root itself, and sibling-prefix
  collisions are refused exactly as they are everywhere else.

### The approved artefact root is trusted, and that is a claim about deployment

**The approved artefact root is part of the trusted computing base**, and this
specification says so rather than implying it. The manifest that attests an
artefact lives in the same directory as the artefact. Anyone who can write that
directory can replace both consistently, and verification would pass. Digest
checking there proves the two agree with each other — not that either is the
package that was admitted.

So the trust is placed where it actually sits: **in the operator's control of
the directory**, enforced by ownership and mode rather than assumed.

**MUST** — the root, every directory component on the resolved path, the
manifest, and the artefact MUST each:

- be a real directory or regular file, never a symbolic link;
- be owned by an **explicitly supplied trusted source UID**;
- be neither group-writable nor world-writable.

Group and other MAY retain read and execute where operation requires it. Write
they may not.

**MUST** — the trusted source UID MUST be supplied explicitly, as configuration
or input. It MUST NOT be inferred from the running process, the file's own
owner, the environment, or a home directory. **Absent, the runtime refuses**;
there is no default, because a default owner is whoever happens to be running.

**MUST** — the manifest and the artefact MUST each have a link count of exactly
one. A second hard link is a second name for the same bytes, outside the
directory whose permissions were just checked, and this contract does not try
to find every alias — it refuses the condition that makes aliases possible.

**MUST** — both files MUST be read through a **descriptor-safe open**: opened
without following a final symlink, validated by `fstat` on the descriptor
rather than by a second look at the path, and read only from that descriptor.
Validating a path and then opening it is a race with whoever can write the
directory.

**MUST NOT**

- MUST NOT execute a free-text reference.
- MUST NOT infer a scheme, guess a default, or fall back to another location.
- MUST NOT accept `oci:`, `https:`, or any other scheme in the initial
  specification. Those are deferred with remote execution (§19).

### A Fabric-valid package is not necessarily executable

**These are two different contracts.** A `CPKG` that ENG-0004 accepted is a
valid governance record and stays one for ever. Execution additionally requires
the **executable-package contract**: a reference inside the accepted grammar
(§7) and integrity evidence that verifies (§8).

**MUST NOT** — the runtime MUST NOT retroactively infer executable meaning from
historical metadata. Specifically:

- a free-text `artifact_reference` MUST NOT become executable by convention;
- an existing `oci://` value MUST NOT be silently reinterpreted;
- an absent `manifest_reference` MUST NOT be synthesised;
- an optional historical `signature_reference` MUST NOT be read as evidence
  that integrity was ever verified;
- `package_version` is a declared string and MUST NOT be treated as a content
  digest;
- an unverified package MUST NOT execute.

**Historical records remain immutable.** Nothing here mutates a `CPKG`, and no
compatibility parser guesses what an operator meant. A package intended for
execution that does not satisfy the executable-package contract requires a
**new governed admission producing new records** with conforming metadata —
which is an ENG-0004 operation, performed by an operator, not a migration this
runtime performs.

This is deliberate fail-closed behaviour. The alternative is a runtime that
decides for itself what an ambiguous reference probably meant, on the one code
path where being wrong means executing the wrong bytes.

## 8. Package integrity

Execution is fail-closed. **No unverifiable artefact executes.**

**MUST**

- The runtime MUST require integrity evidence for the artefact it is about to
  execute, and MUST obtain it from the admitted `CPKG` — specifically from
  `manifest_reference`, resolved under the same grammar and containment as the
  artefact.
- The manifest MUST be **executable manifest schema version 1** (below).
- Verification MUST happen **after** resolution and **immediately before**
  handing the artefact to an adapter.
- The runtime MUST resist substitution between verification and use by
  **opening the artefact once**, verifying the digest from that open
  descriptor, and executing from that same descriptor — never re-opening by
  path. Verifying a path and then opening it again is a race with whoever can
  write the directory.
- Where `signature_reference` is present, the runtime MUST verify it; where it
  is absent, the runtime MUST NOT synthesise or assume one.
- A digest mismatch MUST be reported as **substitution detected** and MUST
  refuse, without executing and without repairing anything.

**MUST NOT**

- MUST NOT execute a `CPKG` carrying no `manifest_reference`. `CPKG` makes it
  optional; execution does not.
- MUST NOT infer integrity from successful past execution, from trust standing,
  or from the artefact being where it was expected.

### Executable manifest, schema version 1

**UTF-8 JSON, one top-level object, closed schema — an unknown field refuses.**
A closed schema because a manifest that tolerates fields nobody reviewed is a
manifest whose meaning grows without anyone deciding it did.

```json
{
  "schema_version": 1,
  "capability_package_id": "CPKG-...",
  "contract_id": "CCON-...",
  "capability_id": "CAPDEF-...",
  "artifact_reference": "file:relative/path",
  "artifact_sha256": "sha256:<64 lowercase hexadecimal characters>"
}
```

| Field | Rule |
|---|---|
| `schema_version` | JSON integer equal to `1`. A boolean is not an integer here. Any other value refuses |
| `capability_package_id` | exactly the package identity the Fabric evidence verified |
| `contract_id` | exactly the contract identity the Fabric evidence verified |
| `capability_id` | exactly the capability identity the Fabric evidence verified |
| `artifact_reference` | exactly the `artifact_reference` the verified package carries, and itself satisfying `file:<relative-path>` |
| `artifact_sha256` | `sha256:` followed by exactly 64 **lowercase** hexadecimal characters. Uppercase refuses, another algorithm refuses, surrounding whitespace refuses |

**No optional fields. No signature field, no command, no argv, no environment,
no adapter, no image, no endpoint, no secret** — schema version 1 describes
which bytes are the package, and nothing about how they run.

**The manifest is not an independent root of trust, and MUST NOT be described
as one.** It is bound to the governed package by identity, and it is protected
by the directory it lives in. The integrity claim this architecture actually
supports, stated exactly:

> the bytes staged match the bytes identified by a manifest stored inside an
> operator-controlled trusted artefact repository, and that manifest is
> coherently bound to the governed package identities

That is stronger than path presence alone and weaker than immutable digest
evidence carried by the governed record itself. **Deferred F** (§28) is where
the stronger form is evaluated.

### Bounds

**MUST** — a manifest requiring more than **65,536 bytes** refuses. An artefact
requiring more than **268,435,456 bytes** (256 MiB) refuses.

**MUST** — both bounds are enforced **while reading**, never after buffering.
An oversized artefact MUST NOT be truncated and accepted, and MUST NOT be
partially staged: refusal leaves no staged object. A larger artefact needs an
explicit architecture change, not a larger constant chosen under pressure.

### Verified bytes are the only bytes

**MUST** — the artefact is opened **once**, its digest computed from that
descriptor, and the staged copy written from that **same** descriptor. The
source pathname MUST NOT be reopened to obtain artefact bytes after the open.
Staging is content-addressed by the verified digest, published atomically, and
re-verified after publication. **The source path is discovery input; the staged
object is what any future adapter may receive.**

## 9. Adapter contract

One narrow interface. Adapters **translate and execute**; they decide nothing.

**Inputs** — the resolved and verified artefact descriptor; the canonical
payload; the contract's declared request shape; the effect class; the execution
deadline if §10 defines one; a secret-reference resolver (§18).

**Outputs** — an outcome class (`completed`, `adapter-error`,
`provider-error`, `timeout`, `cancelled`, `serialisation-failure`); the result
payload where one exists; timing; a reason string that names the failure
without echoing payload or secret material.

**MUST** — an adapter MUST be deterministic in its refusals, MUST report a
failure rather than raise through the coordinator, and MUST confine itself to
the resources §10 grants it.

**MUST NOT** — an adapter MUST NOT choose a provider, add a fallback, retry
across targets, select another `CINST`, widen Trust scope, make a health
decision, write to the Fabric store, or acquire the Fabric request lock (§23).

**No concrete adapter is authorised by this specification.**

The abstract contract above is accepted. **A concrete adapter becomes
authorised only when its isolation boundary satisfies the execution-containment
contract of §10**, demonstrated rather than asserted.

An **in-process callable adapter is explicitly rejected**, and the reasoning
generalises: code running inside the coordinator's own process can read and
mutate coordinator memory, import arbitrary modules, reach inherited process
state and environment, open files anywhere the coordinator can, create sockets,
mutate globals, interfere with evidence being written, call Fabric interfaces
directly, and block or terminate the runtime. A specification that placed such
an adapter behind the containment claims of §10 would be making promises the
mechanism cannot keep.

Until an isolation boundary is specified and accepted, **ENG-0005 has no
executable path**. That is the honest state, and it is preferable to an
executable path whose containment is nominal.

## 10. Execution containment

**Containment has two halves, and only one of them is the coordinator's.**
Conflating them is how a specification ends up promising isolation that nothing
enforces.

### 10.1 Coordinator containment — what the runtime itself guarantees

**MUST** — the coordinator MUST enforce, on every invocation:

- approved paths only, resolved through the shared containment primitive
  `tools/common/containment.contained_path`;
- structured input, never a command string;
- payload canonicalisation and digest binding (§5);
- evidence ordering — the invocation record durable before the adapter runs;
- an explicit, enumerated environment handed to the adapter, never the
  coordinator's own;
- no Fabric request lock held across an invocation (§23);
- no provider or instance substitution (§2).

**These are real guarantees and they hold regardless of adapter.**

### 10.2 Adapter containment — what only the adapter can guarantee

**The coordinator cannot make untrusted code safe by calling it carefully.**
Once control passes to capability code, only the mechanism that executes it can
constrain what it reaches. The following MUST therefore be provided by the
**concrete adapter's isolation boundary**, and a concrete adapter is authorised
only if it demonstrably provides them:

- the capability cannot read or mutate Capability Runtime process memory;
- the capability cannot acquire or observe the Fabric critical section;
- only explicitly exposed filesystem paths are reachable, with no escape;
- the working directory is explicit;
- the environment is controlled and inherits nothing;
- no secret is inherited;
- network access is **denied by default**, enforced by the mechanism and not by
  capability cooperation;
- execution time is bounded;
- CPU and memory are bounded where the architecture requires enforcement;
- output is captured;
- the capability cannot mutate evidence already written;
- the capability cannot select another provider or `CINST`;
- terminating the capability does not terminate the coordinator;
- a crash remains attributable to its invocation.

**MUST NOT** — the specification MUST NOT claim filesystem, environment,
network, privilege, or runtime-integrity isolation for any adapter whose
mechanism does not enforce it. Monkeypatching language-level APIs — sockets,
`open`, imports — is **not** isolation and MUST NOT be presented as such: it
constrains only code that does not try to get around it.

**Until an adapter satisfying §10.2 is specified and accepted, ENG-0005
executes nothing.**

## 11. Effect-class behaviour

| Class | Executable | Retry (§12) | Duplicate (§16) | Concurrency | Evidence |
|---|---|---|---|---|---|
| `read-only` | yes | same-target transport retry permitted | refused by identity | unconstrained | standard |
| `computational` | yes | same-target transport retry permitted | refused by identity | unconstrained | standard |
| `content-generating` | yes | same-target transport retry permitted | refused by identity | unconstrained | standard, and every attempt recorded |
| `side-effecting` | **no — refused** | n/a | n/a | n/a | refusal recorded |

"Executable" above means **permitted in principle**. Nothing executes at all
until a concrete adapter is authorised under §9 and §10.2; the effect class is
one gate, not the only one.

**MUST** — the runtime MUST read the effect class from the contract and MUST
refuse to execute `side-effecting`. **MUST NOT** — MUST NOT enable
`side-effecting` execution, which requires all six ADR-0012 conditions and a
new ADR; and MUST NOT let a route, a flag, or configuration lift the refusal.

`content-generating` is separated from the other two in evidence because it
consumes budget and produces output someone may act on: a repeated attempt is
not free even though it changes nothing outside the request.

## 12. Retry

| Form | Ruling |
|---|---|
| same-target transport retry | **MAY**, bounded, explicit, effect-class-gated, and every attempt recorded as its own result |
| re-execution of the same invocation | **MUST NOT** — the invocation identity is consumed |
| new invocation under the same `CSEL` | **MAY**, with a distinct `invocation_id` |
| retry with a changed payload | **MUST NOT** under the same invocation — the digest binding refuses it |
| retry on another `CINST` | **MUST NOT** |
| new Fabric selection | **MAY** — a new governed decision, outside this runtime |

**MUST NOT** — no implicit failover, no cross-instance retry, no backoff
derived from health, no retry that silently changes the selection. A retry that
is not recorded did not happen.

## 13. Execution store

A separate persistence plane. **It MUST NOT become a Fabric store extension.**

**MUST**

- Root supplied explicitly with expected UID/GID; no default, no
  environment-derived value.
- Directory mode `0o700`, file mode `0o600`, matching the released stores.
- Append-only and immutable: records are never edited; a correction is a new
  record.
- Identifier allocation lock-serialised, monotonic, six digits, refusing
  exhaustion rather than rolling over.
- Atomic writes via exclusive temporary creation, refusing a pre-existing
  temporary rather than truncating it.
- Residue is **reported, never cleaned** — the released doctrine.
- Read-only validation reporting findings deterministically and repairing
  nothing.
- Its own critical section for invocation-identity serialisation, **entirely
  separate from the Fabric's** (§23).

**MUST NOT** — MUST NOT write any Fabric record, MUST NOT extend the eight
Fabric kinds, MUST NOT carry governance authority, MUST NOT create Trust
authority, MUST NOT modify Fabric history, and MUST NOT make a refused
execution appear governed after the fact.

## 14. Invocation evidence

Conceptual fields for the invocation record (`CINV-######`):

`invocation_record_id` · `invocation_id` (opaque, caller-supplied) ·
`request_id` (the Fabric decision) · `selection_id` · `instance_id` ·
`capability_package_id` · `contract_id` · `capability_id` · `actor` ·
`payload_digest` · `effect_class` · `artifact_digest` · `adapter_identity` ·
`requested_at` · `evidence` (approving actor, causal references, outcome).

**MUST** — the invocation record MUST be written **before** the adapter is
invoked, so an execution that crashes mid-flight is still attributable (§17).

## 15. Result evidence

Conceptual fields for the result record (`CRES-######`):

`result_record_id` · `invocation_record_id` · `attempt_number` ·
`outcome_class` (one of `completed`, `refused`, `adapter-error`,
`provider-error`, `timeout`, `cancelled`, `interrupted`,
`serialisation-failure`) · `reason` · `result_digest` ·
`result_artifact_reference` where the result is stored out of line ·
`started_at` · `ended_at` · `evidence`.

**MUST NOT** — MUST NOT persist secret material, credentials, or unrestricted
request/response bodies. Results are recorded by digest and reference; a reason
names the failure without echoing content. This is the released "no full
prompts or responses by default" rule, applied to execution.

## 16. Replay and idempotency

| Case | Behaviour |
|---|---|
| duplicate `invocation_id`, identical binding | **refuse** — `invocation_identity_consumed`; the prior record is returned as evidence, and nothing re-executes |
| duplicate `invocation_id`, different binding | **refuse** — `invocation_identity_conflict` |
| identical payload under a new `invocation_id` | **executes** — a new invocation is a new decision to execute |
| failed invocation | **not replayable** — going forward means a new `invocation_id` |
| interrupted invocation | **not replayable** — see §17 |
| existing result for the invocation | returned; never recomputed |

**MUST NOT** — the runtime MUST NOT claim capability-level idempotency. What is
idempotent is the **record**: presenting one `invocation_id` twice yields one
invocation. Whether the capability itself is safe to run twice is a property of
the capability, declared by its effect class, and is not this runtime's to
assert.

## 17. Crash consistency

**The hard case, stated honestly.** An adapter may complete work with an
external effect before the result record is durable. No ordering within a
single-record atomic write removes that window.

**What the architecture provides:** the invocation record is written before the
adapter runs, so a crash leaves durable evidence that the invocation was
**attempted**, naming the target, the payload digest, and the actor. Validation
reports an invocation with no result as **interrupted** — observable residue,
never cleaned, never repaired.

**What it does not provide:** the runtime **MUST NOT claim exactly-once
external execution.** It cannot. After a crash it can prove an invocation was
attempted; it cannot prove whether the external effect occurred.

**MUST** — completion is an operator decision. An interrupted invocation is
resolved by inspection and a new governed decision, not by automatic
re-execution. This is bounded by the fact that everything currently routable is
non-actuating (§11); the honest statement is that the guarantee is
**at-most-once recorded**, not exactly-once executed.

## 18. Secrets

**The initial runtime requires no implemented secret broker.** Secret-free
capability execution is permitted as soon as an adapter is authorised; secrets
are not on the critical path to a first executable increment.

**MUST**

- Secret values remain forbidden from Fabric records — an accepted prohibition.
- Secret values remain forbidden from immutable Capability Runtime records.
- The architecture MAY define **opaque secret references**; a reference names a
  secret and carries no value.
- If an invocation requires a secret and no authorised broker is available, the
  runtime MUST **refuse before execution**.

**MUST NOT**

- Secret absence MUST NOT authorise an environment fallback.
- No `.env` convention, no plaintext secret file convention, no inherited
  arbitrary process environment.
- No general secret-management platform is defined here.

A broker MAY be specified separately, when an authorised adapter requires one.

## 19. Remote execution

**Deferred.** Not part of the initial implementation.

**MUST NOT** — MUST NOT create a generic HTTP executor, MUST NOT open
unrestricted outbound networking, and MUST NOT accept a remote artefact scheme
(§7). Enabling remote execution requires its own specification covering
transport, endpoint provenance, TLS and authentication, hostname validation,
redirects, proxies, DNS trust, and permitted egress.

## 20. Runtime and service form

**Initial form: a library plus a dedicated Capability Runtime CLI.**

**MUST NOT** — no daemon, no worker service, no queue consumer, no systemd
unit, and nothing that keeps provider state alive between invocations. Each of
those adds credential lifetime, cancellation, and crash-recovery surface that
this specification does not cover, and none is required to execute a governed
selection.

## 21. CLI boundary

**MUST** — Capability Runtime owns its own interface, `tools/capability/cli.py`.
The Fabric CLI remains **governance-only** and gains no execution verb.

Commands justified by this architecture, and no others:

| Command | Purpose |
|---|---|
| `invoke` | execute one governed selection |
| `inspect` | read Capability Runtime records |
| `validate` | report execution-store findings, repairing nothing |

**MUST NOT** — no `retry` command (a retry is a new invocation), no `cancel` in
the initial form (§20 has nothing running to cancel), no `list-adapters` verb
that would imply adapter selection.

## 22. Inspection

**MUST** — Capability Runtime provides read-only inspection and validation over
its own store, deterministic and repair-free.

**MUST NOT** — Fabric C8 MUST NOT be extended across the plane boundary. It
inspects the eight Fabric kinds and continues to refuse an unknown kind.

## 23. Fabric-lock isolation

**Normative.**

- **No capability code executes while the Fabric request critical section is
  held.** No adapter, provider connector, callback, worker, or capability body
  may run under that lock.
- Capability Runtime MUST NOT use the Fabric request lock as its execution
  lock, and MUST NOT acquire it at all.
- An invocation is **not** a Fabric governed write.
- Every Fabric read the runtime performs MUST complete before invocation
  begins.

The Fabric lock is store-global and non-reentrant. Executing under it would
make an arbitrary capability body able to hang every governed write in the
store, and a capability that called back into Fabric would deadlock it
outright.

## 24. Health boundary

**Normatively prohibited in ENG-0005:** health derivation, liveness, readiness,
degradation, remediation, restart, failover, scheduling, placement, adaptive
routing, provider scoring, health-derived backoff, and candidate substitution.

**MAY** — the runtime MAY record what happened during an invocation it
performed. **MUST NOT** — it MUST NOT interpret that into a health state, feed
it into selection, or let it influence which candidate runs next.

**ENG-0006 owns Health.** Health remains a one-directional candidate-removal
input to selection: it may remove a candidate and may never add one.

## 25. Trust boundary

**Normative, and now settled.**

- **No live Trust authorisation on the normal invocation path.** The runtime
  does not query Trust to decide whether an invocation may proceed.
- MUST NOT interpret Trust scope independently. Execution consumes the
  authority the Fabric decision already carried.
- Execution results MUST NOT create, raise, or restore Trust.
- **Post-selection Trust revocation semantics are not invented here.** Trust
  governs the Fabric decision that produced the selection; revocation reaches
  subsequent governed decisions through the existing chain. If the platform
  later requires revocation to invalidate an already-issued, not-yet-executed
  `CSEL`, that requires an explicit selection-revocation and freshness
  architecture, specified on its own terms.

## 26. Failure semantics

Every case resolves to exactly one disposition.

| Case | Disposition |
|---|---|
| `CSEL` absent or malformed | refuse before execution |
| `CSEL` names no instance (a recorded refusal) | refuse before execution |
| selected `CINST` not admitted / withdrawn / retired / superseded | refuse before execution |
| admission window expired | refuse before execution |
| required record chain unreadable | refuse before execution |
| `CPKG` mismatch against `CINST` | refuse before execution |
| artefact reference outside the grammar | refuse before execution |
| artefact unresolvable or outside containment | refuse before execution |
| manifest absent | refuse before execution |
| integrity mismatch (substitution) | refuse before execution |
| effect class `side-effecting` | refuse before execution |
| payload digest mismatch | refuse before execution |
| adapter missing or unloadable | refuse before execution |
| secret required, no broker | refuse before execution |
| duplicate `invocation_id` | refuse; return prior record |
| conflicting `invocation_id` | refuse |
| adapter raises | attempt and record `adapter-error` |
| provider returns an error | attempt and record `provider-error` |
| timeout | attempt and record `timeout` |
| result serialisation failure | attempt and record `serialisation-failure` |
| crash mid-invocation | recorded as `interrupted` by validation; requires a new invocation |
| a different target is needed | requires a new Fabric decision |
| remote execution | deferred |
| cancellation | deferred (§20) |

No case resolves to "retry or fall back as appropriate."

## 27. Security invariants

1. Nothing executes that a `CSEL` did not select.
2. Nothing executes whose payload does not match its bound digest.
3. Nothing executes whose artefact bytes are not integrity-verified from the
   descriptor it executes from.
4. No caller-supplied text reaches a filesystem path except through the shared
   containment primitive.
5. No caller-supplied text reaches a shell, a command string, or an argument
   another program parses.
6. No secret value is persisted in any record, in either plane.
7. No environment is inherited by capability code.
8. No capability code runs while the Fabric lock is held.
9. No execution result alters Fabric or Trust state.
10. No `side-effecting` capability executes.
11. No invocation identity executes twice.
12. No refused execution leaves durable state suggesting it was permitted.
13. No stale selection executes against a `CINST` that is no longer admitted.
14. No unverifiable artefact executes, whatever its trust standing.

## 28. Out of scope

ENG-0006 Health · automatic failover · scheduling · placement · adaptive
routing · TrustGateway cutover (ENG-0003) · subject seeding · any Fabric
policy, schema, or record-kind change · Deferred A (route-declaration
uniqueness) · Deferred B (shared validated-read resolver) · `side-effecting`
enablement · a generic arbitrary-code sandbox · **every concrete adapter, until
one is authorised under §9** · remote execution · a broad secret-management
platform · **Deferred F — governed package-content integrity**, which evaluates
moving the artefact digest into immutable governed package evidence, or an
equivalent cryptographically governed package-authenticity mechanism (a digest
carried directly by `CPKG`, a governed manifest digest, signed package
metadata, or another immutable content binding). Until then the trusted
artefact repository of §7 carries that weight, and historical nonconforming
packages remain Fabric-valid and non-executable ·
scheduler, placement, clustering, and leases (ENG-0007/0008).

## 29. Acceptance criteria

**Authority**
1. Execution without a `CSEL` is refused.
2. A caller-supplied instance identity is refused; the instance comes from the `CSEL`.
3. A `CSEL` recording a refusal executes nothing.
4. No execution path calls C5 or C6.
5. No execution writes a Fabric record.

**Invocation identity**
6. An invocation carries a caller-supplied opaque `invocation_id`, never parsed.
7. Invocation record identities are unique and monotonic under concurrency.
8. Every invocation record names the Fabric `request_id` of its decision.

**Payload binding**
9. The same logical payload canonicalises to the same digest across runs.
10. Any change to payload, `invocation_id`, `selection_id`, `instance_id`, `capability_package_id`, or actor changes the digest.
11. A payload not matching the bound digest is refused before execution.
12. A payload that cannot be canonicalised is refused, not approximated.

**Package resolution**
13. A reference outside the accepted grammar is refused.
14. Traversal, absolute escape, symlink escape, sibling-prefix, and the root itself are refused by the shared primitive.

**Integrity**
15. A `CPKG` with no `manifest_reference` does not execute.
16. A digest mismatch is refused and reported as substitution.
17. Verification and execution use one descriptor; re-opening by path does not occur.

**Execution and containment**
18. Capability code receives no inherited environment.
19. No caller-supplied text reaches a shell, a command string, or an argument
    another program parses; the coordinator constructs no command strings.
20. Adapter output is captured and bounded.
20a. No concrete adapter executes before its isolation boundary is accepted
    against §10.2, demonstrated rather than asserted.
20b. Network access from an adapter is denied by the mechanism, and denial is
    demonstrated from inside the boundary rather than assumed.

**Effect class**
21. `side-effecting` is refused, and no flag, route, or configuration lifts it.
22. Effect class is read from the contract, never supplied.

**Replay**
23. A duplicate `invocation_id` refuses and re-executes nothing.
24. A conflicting `invocation_id` refuses.
25. An identical payload under a new `invocation_id` executes.

**Failure**
26. Every §26 case produces its stated disposition.
27. No refusal mutates either store.
28. No failure triggers reselection or cross-instance retry.

**Persistence**
29. The execution store creates no Fabric record and no ninth Fabric kind.
30. Residue is reported and never cleaned.
31. Validation repairs nothing and is deterministic across runs.

**Crash**
32. An invocation record exists before the adapter is invoked.
33. An invocation with no result is reported as interrupted.
34. No claim of exactly-once external execution is made anywhere.

**Secrets**
35. No secret value appears in any persisted record or log.
36. A capability requiring secrets with no broker is refused.

**Lock isolation**
37. No capability code executes while the Fabric request lock is held.
38. The runtime never acquires the Fabric request lock.

**Health and Trust separation**
39. No health state is derived, consulted, or recorded as a decision input.
40. No Trust call occurs on the invocation path.
41. No execution result alters Trust.

**Inspection and CLI**
42. Fabric C8 is unchanged and still refuses unknown kinds.
43. The Fabric CLI gains no execution verb.
44. Capability Runtime inspection is read-only.

## 30. Failure criteria

Numbered hostile and invalid cases the implementation must refuse:

F1 a forged `CSEL` naming an instance the route never contained ·
F2 a `CSEL` for a different capability than the payload targets ·
F3 an instance identity supplied directly, bypassing the `CSEL` ·
F4 a payload swapped after digest computation ·
F5 an artefact swapped between verification and execution ·
F6 an `artifact_reference` containing `../` ·
F7 an `artifact_reference` that is an absolute path outside the approved directory ·
F8 a symlinked artefact pointing outside the approved directory ·
F9 a manifest declaring a digest for different bytes ·
F10 a `side-effecting` contract presented for execution ·
F11 an `invocation_id` replayed to force a second external effect ·
F12 an `invocation_id` reused with a different payload ·
F13 a capability body attempting to call a governed Fabric operation ·
F14 a capability body attempting to acquire the Fabric lock ·
F15 a capability body reading outside the approved artefact directory ·
F16 a secret value submitted inside the payload ·
F17 a result large enough to exhaust memory or disk ·
F18 an adapter returning a result that fails canonical serialisation ·
F19 an execution attempted against a withdrawn instance ·
F20 an execution attempted after the admission window expired ·
F21 a crash between external effect and result write ·
F22 an attempt to record execution evidence in the Fabric store.

## 31. Implementation entry gate

Implementation remains **prohibited** until, in order:

1. this specification is accepted;
2. the architecture questions it records as open are resolved;
3. **a concrete adapter's isolation boundary is specified and accepted against
   §10.2** — without one there is no executable path to plan;
4. an implementation plan is drafted;
5. that plan is accepted;
6. test-first entry is explicitly authorised.

Increments that build the coordinator, the execution store, identity, payload
binding, package resolution, and integrity verification **do not depend on an
adapter** and could be planned first. Nothing that executes can be.

A satisfied gate is permission to plan the next increment, not to build it.

## 32. Related records

- [Fabric Runtime Design (ENG-0004)](2026-08-04-fabric-runtime-design.md)
- [ADR-0012: Distributed Capability Fabric](../../decisions/ADR-0012-distributed-capability-fabric.md)
- [Fabric governance boundaries](../../fabric/governance-boundaries.md)
- [Failure behaviour](../../fabric/failure-behaviour.md)
- [Post-root runtime sequence](../plans/2026-08-03-post-root-runtime-sequence.md)
- [v1.0 engineering ledger](../../history/v1.0-engineering-ledger.md)
