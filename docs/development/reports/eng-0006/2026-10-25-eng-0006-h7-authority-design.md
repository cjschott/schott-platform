# ENG-0006-H7 — Authority Design

**Date:** 2026-10-25
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `239bd48dbcdb01771bd10d46f29e9f262df01db2` (H7 readiness)
**Published remote:** `e47679c18ee8cb77156adea00cd0b48caaadb88a` (H6A)
**Nature:** Architecture investigation and **proposed** design. **Documentation only — no implementation authorization.**
**Recommendation:** **GO for C1** under Design **B+** (§6), conditional on four rulings. **HOLD for C2** on an exact schema incompatibility (§11.6).

> **Labelling.** **[C]** = committed requirement. **[I]** = implemented and
> verified in code. **[DOC]** = documented but unimplemented. **[P]** =
> implementation precedent in another plane. **[PROPOSED]** = this report's
> proposal, **not authoritative**. Every contract in §7, §8, §10 and §11 is
> **[PROPOSED]**.

---

## 1. Verified starting state

| Gate | Result |
|---|---|
| repository / branch | `/opt/schott-platform`, `arch/eng-0006-health-runtime` |
| local HEAD | `239bd48dbcdb01771bd10d46f29e9f262df01db2` ✓ |
| published remote | `e47679c18ee8cb77156adea00cd0b48caaadb88a` ✓ (`ls-remote`) |
| worktree / index | clean; 0 untracked |
| ancestry | strictly linear; 0 merges since H5; `239bd48^ = e47679c` |
| readiness commit contents | **one file**, `…h7-readiness-assessment.md`, +734 lines — documentation only ✓ |
| `/var/lib/kyri/health` | absent |

Local is 1 ahead of the published remote: the readiness commit, unpushed.

---

## 2. Existing authority inventory

### 2.1 The finding that reshapes the design space

**There is no cryptography in this platform.**

```
grep -rnE '^\s*(import|from)\s+(nacl|cryptography|Crypto|gnupg|ed25519|ecdsa|jwt|jose|hmac)\b' tools/
  tools/fabric/request_identity.py:36:import hmac
  tools/capability/invocation_identity.py:33:import hmac
```

Both `hmac` uses are **`hmac.compare_digest`** — constant-time *comparison*
(`request_identity.py:245`, `invocation_identity.py:184`). Neither computes a
keyed MAC. There is no signing key, no key store, no verifier, no certificate,
no revocation list, and no cryptographic dependency declared anywhere.

`tools/trust/models.py:131` declares `OFFLINE_SIGNATURE =
"offline-signature-verification"` — but that is a member of
`VerificationMethod`, "**How evidence was checked**, from the ADR-0011
vocabulary". It is a value recorded to say *a human verified a signature out of
band*. **It is not a signature verifier.** Treating it as one is precisely the
inference the brief forbids: "Do not infer a working approval mechanism from the
existence of an operator identity or signing key."

### 2.2 Inventory

| Capability | Status | Evidence |
|---|---|---|
| Operator Root Authority | **[I]** declaration only | `tools/trust/root_authority.py`. "Kyri may persist a declaration that an external root exists, and Kyri **must not establish the external identity itself**. This module records **what a human verified out of band**. It does not verify, does not resolve, and does not guess." One active root per store; a second refused; superseding not implemented |
| Trust Plane runtime | **[I]** | states, lineage, transitions, expiry, audit, query, store |
| Trust authorization decision point | **[I]** | `tools/trust/gateway.py` — "The single decision point for every authorization question." `query(*, domain, subject_id, action, evaluated_at, context) -> TrustVerdict`. **Read-only**; never constructs a store ("Constructing one as a side effect of asking a question would make the act of querying change the thing being queried"); unknown domain **fails closed**; `_from_runtime`: "Any failure to read is a denial, never a pass" |
| Operator **identity** decidable at runtime | **[DOC] — explicitly not implemented** | `tools/trust/policy.py:_declared_policy`: "Identity and capability trust are **declared in reviewed files today**. Nothing in this release grants them at runtime, so the honest answer is a denial naming the gap rather than an allow that implies a decision nobody made." The `user` domain returns exactly that denial |
| Authority **delegation** | **[DOC]** | `AuthorityType.DELEGATED` exists; "Delegated authorities exist only because a recorded decision created them, and **are not implemented in v0.9.3**" |
| Scoping | **[I]** | `tools/trust/scope.py` — "Deny by default, on every dimension… An unstated dimension is the most common way a bounded grant quietly becomes an unbounded one. State overrides scope, always" |
| Time-bounding / expiry | **[I]** | `tools/trust/expiry.py` — deterministic, no wall clock, caller supplies `evaluated_at`; `effective_state(stored, expiration, evaluated_at)` |
| Revocation | **[I]** as vocabulary + state machine | `TrustState`: `UNKNOWN PENDING TRUSTED RESTRICTED QUARANTINED REVOKED EXPIRED REJECTED`; `transitions.py` table is code-owned and explicit. **No operator subject exists to revoke** (see `user` domain) |
| Signing / signature verification | **NOT IMPLEMENTED** | §2.1 |
| Canonical JSON | **[I]**, and a **platform-wide convention** | `tools/capability/execution/canonical_json.py` (strict: refuses floats, exponents, NaN, duplicate keys, oversized ints, lone surrogates; pure). Separately, the digest convention `json.dumps(payload, sort_keys=True, separators=(",", ":"))` appears **identically in three planes** — `fabric/request_identity.py:232,403`, `observation/evidence_builder.py:36`, `integrity/snapshot_manager.py:81` |
| Strict YAML | **[I]**, in `tools/common` | `tools/common/yaml_strict.py` — `load_strict`/`loads_strict` refuse duplicate mapping keys. "It fails closed. There is no permissive mode and no flag to allow duplicates whose values happen to match" |
| Immutable records | **[I]** | `tools/common/immutable_store.py`; Health's `HealthStore` (H6/H6A) |
| Digest-bound approval evidence | **[I]**, in the Fabric | `tools/fabric/evidence.py:EVIDENCE_FIELDS` — `actor`, `approving_authority`, `causal_references`, `trust_evidence_references`, `reason_category`, `recorded_at`, `request_id`, **`request_digest`**. Closed field set; unknown fields refused; `approving_authority` required text except for `UNAPPROVED_KINDS`, which must name **none** |
| Self-governance refusal | **[I]** | `tools/fabric/admission.py:_no_self_governance` — "A machine does not admit itself into the fabric, under any identity"; and `_no_self_governance_of` — "A machine does not decide the fate of its own records," named apart on purpose |
| Replay resolution **without a ledger** | **[I]** | `tools/fabric/request_identity.py` — `REPLAY_NEW` / `REPLAY_EXACT` / `REPLAY_CONFLICT`. "There is no request ledger, no replay ledger, and no ninth record class: the `request_id` and `request_digest` that prove a request was accepted live **on the record whose existence they justify**" |
| Approved-input mechanism | **[I]**, 6 call sites | `tools/common/containment.py:contained_path` — resolve both sides, strictly beneath, symlink judged by where it lands |
| **Descriptor-verified** trusted input | **[I]**, in `tools/common` | `tools/common/trusted_source.py` — see §2.3 |
| Approval ceremony pattern | **[I]** | `declare_root_authority` + `AuditEventKind`: "Every write emits one. Read-only evaluation emits none" |

### 2.3 A correction to the H7 readiness assessment

The readiness assessment (§5.2) named `contained_path` as the approved-input
primitive and concluded that the authority model therefore "rests on filesystem
permissions" in an unchecked way. **That was incomplete.** `tools/common/trusted_source.py`
is a materially stronger primitive in the same shared location:

> "This opens **once**, refusing to follow a link on the final component, and
> then asks the **descriptor** what it got. Regular file, expected owner, not
> writable by group or other, and — when the caller requires it — exactly one
> link. `fstat` on the open descriptor, never a second look at the path."
>
> "**Trust is in the directory, and it is checked rather than assumed.** The
> approved root and every component beneath it must be a real directory, owned
> by the supplied trusted UID, and not group- or world-writable."
>
> "**The trusted UID is supplied, never inferred.** Not from the running process…"

This closes the TOCTOU window `contained_path` leaves open ("Between resolving a
name and opening it, whoever can write the directory gets a turn"), and it makes
filesystem authority a **checked** property — ownership by a declared UID, plus
non-writability of every path component — rather than an assumed one. The
trusted UID being *supplied* means the caller must **declare whose files it
trusts**, which is itself an authority statement a reviewer can audit.

It does not make filesystem control equivalent to an authenticated identity. But
it materially narrows readiness blocker **B-2**, and the readiness assessment
should be read with this correction.

---

## 3. Required authority questions, answered

| Question | Answer | Class |
|---|---|---|
| Who is permitted to approve a Health envelope? | **No committed answer exists.** No artifact names an approver for Health policy. ADR-0013:547-549 says only that inputs "follow the approved-input precedent and are reviewed before they reach the store" | gap |
| How is that operator identity established? | **It is not, at runtime, by design.** Operator identity is "declared in reviewed files today… not yet decided by the Trust Plane" (`policy.py`). The Operator Root Authority records what a human verified **out of band** | **[DOC]** |
| What authorizes that identity specifically for Health policy approval? | **Nothing.** `SUPPORTED_DOMAINS` is closed and holds six domains — `collector-plugin`, `host`, `ssh-host-key`, `remote-transport`, `user`, `capability-package`. There is **no Health domain and no policy-approval domain**. An unrecognised domain fails closed | gap |
| Delegated, scoped, time-bounded, revocable? | **Scoping [I]**, **expiry [I]**, **revocation vocabulary and transitions [I]**, **delegation [DOC]** and "not implemented in v0.9.3". All of it is machinery with **no operator subject to apply it to** | mixed |
| How does Kyri distinguish an authorized operator from a subject, collector, or compromised caller? | **Three partial mechanisms, no identity check.** (a) `trusted_source` — the file is owned by a declared trusted UID and sits under a non-world-writable tree; (b) `_no_self_governance` **[P]** — refuse when the subject identity equals the actor or the approving authority; (c) the Trust gateway — which cannot answer for this domain. **None authenticates a human** | gap |
| How is approval tied to the exact envelope? | **Not today, for Health.** The mechanism exists in the Fabric: `request_digest` over canonical JSON, `sha256:`-prefixed, with the canonicalisation and digest versions **named in the payload so an unknown one fails closed**. CHENV has no field to carry it | **[P]** |
| Behaviour when authority cannot be verified? | **Refuse.** Already the platform-wide posture: unknown domain fails closed; "Any failure to read is a denial, never a pass"; `TrustState.UNKNOWN` "is the default and fails closed"; `HealthStore` refuses rather than defaults | **[C]/[I]** |

### 3.1 The missing contract, stated exactly

> **No artifact declares who may approve a Health operational envelope, and no
> implemented mechanism can decide it.** The Trust Plane is the designated
> single decision point and is read-only and fail-closed, but its domain set is
> closed and contains no domain under which the question could even be asked.

Everything else H7 needs is either implemented or precedented. This one contract
is absent, and it is the contract C1 exists to enforce.

---

## 4. Governing requirements and exact references

Carried forward from the readiness assessment (R1–R21) and extended:

| # | Requirement | Source | Class |
|---|---|---|---|
| R5 | "**Envelope changes require immutable approval.** A new envelope version is a new record with an **approving identity**, not an edit." | `operational-envelope.md:97-98` | **[C]** |
| R6 | `change_requires: immutable-approval` | CHENV schema `:53` | **[C]** |
| R7 | "Human-authored envelope inputs follow the **approved-input precedent** and are **reviewed before they reach the store**, so that authoring a threshold and running the evaluator are not the same authority." | `ADR-0013:547-549` | **[C]** |
| R8 | `mutability: immutable`, `update_methods: none`, `delete_methods: none`, `supersession: new-record-only` | CHENV schema `:32-35` | **[C]** |
| R9 | `supersession_rewrites_prior_evaluations: false` | CHENV schema `:65` | **[C]** |
| **R12** | Health writes its own store **Yes**; **"Health reads Fabric and Trust — Only through read-only adapters, never by direct record access"** | `ADR-0013:541-542` | **[C]** |
| R11 | "Trust reads or writes Health — **Never**, in either direction" | `ADR-0013:545` | **[C]** |
| R22 | "The separation **is the mechanism, not a convention**… 'Health cannot mutate Trust or Fabric state' would rest on application discipline rather than on filesystem authority. **Discipline does not survive a bug**" | `ADR-0013:534-537` | **[C]** |

**R12 is the second correction to the readiness assessment.** That report treated
the Trust Plane as wholly unreachable from Health. ADR-0013:542 **permits
Health→Trust reads through a read-only adapter** and forbids only *direct record
access*. R11's "never in either direction" governs **Trust→Health**. So a
read-only Trust adapter is **architecturally permitted**; what is missing is a
domain to ask about (§3). This widens the design space materially.

---

## 5. Canonicalization and payload binding

### 5.1 Does the platform already define one? Yes — two, at different layers

1. **Strict canonical JSON** — `tools/capability/execution/canonical_json.py`.
   "Refuses; never repairs… the bytes a capability receives must be the bytes
   whose digest was bound to the invocation. A parser that normalises, coerces,
   or collapses its input breaks that equality quietly." No lenient mode.
2. **The digest convention** — SHA-256 over `json.dumps(payload, sort_keys=True,
   separators=(",", ":"))`, rendered `sha256:`-prefixed, matching
   `^sha256:[0-9a-f]{64}$`. `request_identity.py:14-20` states it plainly:
   "**The digest convention is reused, not invented**… exactly as
   `tools/observation/evidence_builder.py` and
   `tools/integrity/snapshot_manager.py` already do. No new cryptographic
   algorithm appears here."

**Neither lives in `tools/common`.** `tools/common` holds exactly
`containment.py`, `immutable_store.py`, `trusted_source.py`, `yaml_strict.py`.
So Health reusing the convention means a **fourth in-plane implementation**
(~6 lines) or **promotion to `tools/common`** — the same argument that created
`immutable_store.py` ("three copies of a correctness-critical routine is past
the point where that trade is worth making, and a fourth would be
indefensible"). **This is Q-H7A-4.**

### 5.2 Raw bytes or normalized content? — the three-digest problem

An envelope exists in **three** different byte forms, and they are not equal:

| Form | Produced by | Retained? |
|---|---|---|
| **submitted file bytes** | the operator's editor | **No** — nothing stores the input file |
| **parsed record** (a Python mapping) | `yaml.safe_load` → `records.parse()` | as a record, not as bytes |
| **stored bytes** | `yaml.safe_dump(payload, sort_keys=True, default_flow_style=False, allow_unicode=True)` in `write_atomic` | **Yes** |

Consequences, which decide the design:

- **Binding the submitted file bytes is not verifiable on readback**, because the
  file is not retained. The readiness assessment's readback requirement and a
  file-bytes digest are mutually exclusive unless the input file is also stored —
  which no artifact authorizes.
- **Binding the stored bytes is circular**: the stored form is produced *after*
  acceptance, so an approval could not be checked before the write.
- **Binding the canonical JSON of the parsed record is verifiable on readback.**
  `read_record` does `yaml.safe_load(path.read_text())`, and
  `HealthRecord.to_dict()` returns a plain mapping of YAML-safe types (str, int,
  bool, None, mapping, sequence — decimal thresholds are *strings*), so the
  round trip is value-preserving and the digest is reproducible.

**[PROPOSED] Bind the canonical JSON of the parsed, validated record.** It is the
only one of the three that can be computed before the write and re-verified after
it.

### 5.3 YAML ambiguity

| Vector | Status |
|---|---|
| duplicate mapping keys | **closed** by `tools/common/yaml_strict.py` — **[I]**, and in the shared location |
| key ordering | **irrelevant** once the digest is over `sort_keys=True` canonical JSON |
| whitespace / block style | **irrelevant** — the digest is over the parsed value, not the file |
| anchors, aliases, merge keys (`<<`) | **open.** `SafeLoader` resolves them, so two different files yield one parsed structure. Harmless under a record digest; it means a *file*-bytes digest would be the wrong binding |
| scalar spellings (`yes`/`true`/`True`; `1.0` vs `1`) | **narrowed by the schema**, not by YAML: thresholds are **decimal strings** (`condition_value_representation: decimal-string`) and integers go through `_whole`. A YAML bool where a string is required is refused by `_decimal_text` |
| Unicode / lone surrogates | **open** for the YAML path. `canonical_json.py` refuses lone surrogates; a Health-local digest helper would not, unless it reuses that module |
| numeric representation | **narrowed**: no float ever reaches a threshold (decimal strings); `canonical_json` additionally refuses floats and exponents outright |

**[PROPOSED]** Read the input with `yaml_strict.load_strict`, not `yaml.safe_load`,
so a duplicate key is refused rather than silently last-wins. This is a
one-import change with an existing shared primitive.

---

## 6. Architecture alternatives, compared

### Design A — detached cryptographic approval, verified via existing Trust infrastructure

A signed approval object, verified with the platform's Trust machinery.

**The premise is false.** There is no Trust verification infrastructure to reuse
(§2.1). Design A would require: the platform's **first** cryptographic
dependency; a key-management story (generation, storage, rotation, revocation);
a public-key distribution mechanism; a verifier; and an operator ceremony to
establish the first key. The brief forbids creating signing keys, credentials,
certificates, or Trust records, and forbids initiating a Root Authority ceremony
— so Design A is not merely large, it is **not actionable under this
authorization**.

### Design B — approval through a governed operator ceremony with immutable evidence

Follow the Fabric's **implemented** model: a record carries `actor` and
`approving_authority` as declared identities, bound to a `request_digest`, with a
closed field set, refused self-governance, and replay resolved from the records
themselves.

### Design C — approved-directory and filesystem-identity controls, no approval object

Follow `tools/trust/root_authority.py` exactly: read from a trusted directory,
validate, persist. No approval evidence on the record.

### Comparison

| Criterion | **A** crypto | **B** governed evidence | **C** directory only |
|---|---|---|---|
| existing implementation reuse | **none** — would be the first | **high** — Fabric evidence, `request_digest`, replay, `_no_self_governance`, `trusted_source`, `yaml_strict`, `HealthStore` | **high** — `trusted_source`, `HealthStore` |
| authority strength | strongest *in principle*; unbuilt in practice | declared identity + checked file ownership + refused self-approval | checked file ownership only |
| payload integrity | signature over bytes | **digest over the canonical record**, re-verifiable on readback | **none** |
| replay resistance | nonce / expiry | **`request_id` + `request_digest`**: exact replay is idempotent, a digest conflict is refused | **none** |
| revocation | key revocation | Trust states exist, but no operator subject (§3) | none |
| auditability | strong, if keys are managed | **strong** — approver recorded immutably on the record itself | weak — nothing records *who* |
| complexity | very high (new dependency, key lifecycle, ceremony) | moderate (schema fields + ~3 helpers) | lowest |
| operational burden | high — key custody becomes a standing obligation | low — the operator names themselves in the file they already author | lowest |
| cross-plane separation | needs a verifier Health may reach | **clean** — pattern reused, no cross-plane import; optional read-only Trust adapter | clean |
| failure behaviour | refuse | refuse | refuse |

### 6.1 Recommendation — **Design B+**, not because it is cheapest

**B**, plus two elements that are strictly stronger than B as the Fabric
implements it:

- **B+1 — descriptor-verified input.** Read via `trusted_source.open_trusted_regular_file`
  with a **supplied** trusted UID, not `contained_path`. This closes the TOCTOU
  window and converts filesystem authority from assumed to checked (§2.3).
- **B+2 — a read-only Trust adapter**, permitted by R12, asking
  `gateway.query()` whether the named approving authority is usable. **This
  requires a new Trust domain** (§3), and is the one new contract.

I am not recommending B because A is more work. I am recommending it because
**A's stated reuse does not exist**, and because B delivers the two properties
C lacks — payload binding and replay resistance — using mechanisms already
built, reviewed and tested elsewhere in this repository. C is rejected: it cannot
satisfy R5's "approving identity" at all, and it cannot detect a modified or
replayed envelope.

**B+ is honestly weaker than A would be if A existed.** It authenticates no
human. Its authority rests on (i) a file owned by a declared trusted UID under a
non-world-writable tree, (ii) an operator identity the operator declares, (iii)
refusal of self-approval, and (iv) an immutable record of who claimed to approve.
That is **attributable, auditable, tamper-evident approval without
authentication** — and it is exactly the standard the rest of the platform
currently meets. H7 should not be the first plane required to exceed it, and
**should not be the place a cryptographic identity system is introduced**; that
is a platform-level decision (§15, Q-H7A-1).

---

## 7. Proposed approval evidence contract — **[PROPOSED]**

Evaluated against the brief's candidate field list, with each field judged
**required / optional / rejected** and justified.

| Candidate field | Verdict | Justification |
|---|---|---|
| approval purpose / domain | **required** | `approval_domain: "capability-health-envelope"`. Precedent: `request_identity.py` names participating fields "so semantically distinct inputs cannot collide". Prevents an approval for one purpose being replayed as another |
| exact canonical envelope digest | **required** | `approval_digest: sha256:…` over §5.2's canonical record. The only payload binding that is re-verifiable on readback |
| envelope identity | **required** | implicit — the evidence lives **on** the CHENV record (`envelope_id`). No separate field |
| subject identity | **required** | implicit — `subject_id`/`subject_type` are already required fields. A separate copy could disagree with the record carrying it |
| envelope version | **required** | implicit — `envelope_version` already required |
| approving operator identity | **required** | `approving_authority` — the Fabric's exact field name and semantics |
| authority / delegation reference | **optional, deferred** | `AuthorityType.DELEGATED` is **[DOC]**, "not implemented in v0.9.3". Declaring a field for an unimplemented mechanism would be a defaulted answer to an unasked question |
| approval issuance time | **required** | `approved_at`, offset-aware. `_instant` already validates this shape, and ADR-0013 requires offset awareness because "the same string means different moments on two hosts" |
| optional expiry | **rejected for C1** | Expiry on an *approval* implies re-approval machinery and a clock at evaluation time. `expiry.py` exists but needs a subject (§3). Omitting it is the Null-Policy-consistent choice: no declared expiry must not silently mean "never expires" **or** "expired" — so the field should not exist until the mechanism does |
| signature algorithm + key identifier | **rejected** | No signing exists (§2.1). Declaring the fields would invite a reader to believe a signature was checked. This is the `OFFLINE_SIGNATURE` trap in field form |
| signature over the canonical statement | **rejected** | same |
| **added:** `request_id` | **required** | Replay resolution without a ledger (`request_identity.py`). Opaque, bounded, compared in constant time — never parsed |
| **added:** `actor` | **required** | The Fabric separates who *acted* from who *approved*; `_no_self_governance` checks **both** |
| **added:** `canonicalisation` + `digest_algorithm` | **required** | `request_identity.py`: "the canonicalisation and digest versions are part of the payload so an unknown one fails closed rather than being guessed at" |

### 7.1 Where approval evidence is retained

**On the CHENV record itself, in the Health store.** Three candidates were
considered:

| Location | Verdict |
|---|---|
| the Trust store | **prohibited.** R11 — "Trust reads or writes Health **Never**, in either direction." Writing Health approval into Trust storage is a Health→Trust write |
| a new Health record family | **rejected.** It would be a seventh family, which ADR-0013's six-family closure forbids, and would reproduce the "ninth record class" the Fabric explicitly refused |
| **on the CHENV record** | **recommended.** Exactly the Fabric's reasoning: "the `request_id` and `request_digest` that prove a request was accepted live **on the record whose existence they justify**" |

**Is that storage location already authorized? Yes for the store, no for the
fields.** Health writing its own store is R12. But CHENV declares no such
fields, and `parse()` is a closed field set — so this requires a **schema
amendment** (§13).

---

## 8. Trust / Health separation model — **[PROPOSED]**

```
  ┌─ operator, out of band ────────────────────────────────────────┐
  │  authors envelope.yaml in a directory owned by TRUSTED_UID,    │
  │  not group/world-writable at any component                     │
  └──────────────────────────┬─────────────────────────────────────┘
                             │  (never a caller-chosen path; a bare name)
                             ▼
  ┌─ tools/health/ingest.py ───────────────────────────────────────┐
  │  trusted_source.open_trusted_regular_file(root, name,          │
  │                         expected_uid=TRUSTED_UID)   [common]   │
  │  yaml_strict.loads_strict(...)                      [common]   │
  │  records.parse("capability-health-envelope", data)  [health]   │
  │  digest = sha256(canonical_json(record))                       │
  │  verify approval fields; refuse self-approval                  │
  │  ── read-only authority query ──────────────┐                  │
  │                                             ▼                  │
  │                            tools/health/trust_adapter.py       │
  │                            (READ-ONLY, R12)                    │
  │                                             │                  │
  │  HealthStore.allocate_id / write_record     │   [health]       │
  │  readback + digest re-verification          │                  │
  └─────────────────────────────────────────────┼──────────────────┘
                                                │ query() only
                                                ▼
                                   tools/trust/gateway.query(...)
                                   ── no write path exists ──
```

**The ten invariants, and what actually enforces each:**

| # | Invariant | Enforced by | Prevention or detection |
|---|---|---|---|
| 1 | Health cannot grant itself authority | Health has no write path to Trust; the gateway's domain set is closed and code-owned | **prevention** |
| 2 | Health cannot mint operator approvals | approval fields are *validated*, never *generated*; refusal if absent | **prevention** |
| 3 | Health cannot access private signing keys | none exist anywhere (§2.1); no key material is read | **prevention**, vacuously |
| 4 | Health cannot modify Trust records | H6A import guard refuses `tools.trust` statically; `HealthStore` refuses a root at/inside `/var/lib/kyri/trust`; adapter exposes `query` only | **prevention**, three layers |
| 5 | Fabric cannot infer execution permission from Health approval | `may_execute: false`, `may_modify_trust_state: false` (CHENV `:75-76`); AC 25 proves the Fabric runs with Health **unimportable** | **prevention** |
| 6 | An approved envelope cannot bypass schema validation | `parse()` runs **before** any approval check in §10; ordering is the mechanism | **prevention** |
| 7 | A schema-valid envelope cannot bypass approval validation | approval check is unconditional and after `parse()`; no flag disables it | **prevention** |
| 8 | A subject cannot approve its own thresholds | `_no_self_governance` pattern **[P]**: refuse if `subject_id ∈ {actor, approving_authority}` | **prevention** |
| 9 | A compromised ingestion caller cannot fabricate approval | **PARTIAL — see §8.1** | — |
| 10 | Failure to verify authority refuses, never falls back | fail-closed everywhere: unknown domain denies; "Any failure to read is a denial, never a pass"; no default approver | **prevention** |

### 8.1 Invariant 9 cannot be fully satisfied, and this must be said plainly

An **in-process** caller that can construct an `IngestResult` or call
`write_record` directly can bypass any in-process check. Under Design B+ the
caller supplies the approval fields, so a compromised caller can supply whatever
it likes. What B+ actually achieves:

- **It is not an `authority=True` argument.** The approval fields travel **inside
  the operator-authored file**, read through a descriptor verified to be owned by
  the declared trusted UID. A caller cannot assert approval by *parameter*; it
  would have to write a file into a directory owned by the trusted UID.
- **The claim is recorded immutably.** Forgery is **detectable** afterwards: the
  record names an approver who can deny approving it, bound to a digest.
- **The digest makes substitution detectable**, since the approved digest and the
  stored record are compared on readback.

So invariant 9 is satisfied as **detection and attribution, not prevention**.
**Only Design A would make it prevention**, and only after key custody moved
outside the process. This is recorded as residual risk, not solved.

### 8.2 Where approval verification belongs

**Inside Health, with a read-only Trust adapter for the authority question.** A
new privileged service is **not** required and is not proposed:

- The brief's own instruction is to avoid one unless demonstrably required.
- The gateway is already "the single decision point", already read-only, and
  already fails closed. A Health-side service would be a second decision point.
- R12 permits exactly this shape: Health reads Trust "**only** through read-only
  adapters, never by direct record access". The adapter module *is* that
  read-only adapter — a thin boundary exposing one question, so no Health module
  touches a Trust record.

---

## 9. (reserved — see §10 and §11 for the C1 and C2 contracts)

---

## 10. Proposed C1 ingestion contract — **[PROPOSED]**

```python
def ingest_envelope(store, *, name, approved_directory, trusted_uid,
                    request_id, evaluated_at, trust_adapter=None) -> IngestResult
```

**No `authority` parameter exists.** Per the brief, an authority argument from an
arbitrary caller is not proof of anything; authority travels in the
operator-authored file, read through a verified descriptor.

| Stage | Mechanism | Enforceable today? |
|---|---|---|
| 1. approved input location | `trusted_source.open_trusted_regular_file(approved_directory, name, expected_uid=trusted_uid)` | **Yes** — **[I]**, needs a module-scoped import |
| 2. strict parse | `yaml_strict.loads_strict` | **Yes** — **[I]**, needs a module-scoped import |
| 3. schema + record validation | `records.parse(...)` — closed field set, 11 forbidden fields by name, conditions, aggregation, all four hysteresis members, `unit == DIMENSION_UNITS[dimension]` | **Yes** — **[I]** |
| 4. canonical digest | SHA-256 over canonical JSON of the parsed record | **Yes**, once Q-H7A-4 picks the source |
| 5. approval evidence present and well-formed | §7's fields | **No** — needs the schema amendment (§13) |
| 6. digest agreement | `approval_digest == computed digest` | **No** — no field to compare against |
| 7. self-approval refused | `subject_id ∉ {actor, approving_authority}` | **No** — no fields; the *pattern* is **[P]** |
| 8. authority usable | read-only `gateway.query(domain=…, subject_id=approving_authority)` | **No** — no domain exists (§3) |
| 9. replay resolution | `request_id` + `request_digest` over existing CHENV records | **No** — no fields; the *pattern* is **[I]** in the Fabric |
| 10. identifier allocation | `store.allocate_id("capability-health-envelope")` — flock'd, monotonic, 4-digit, refuses at `CHENV-9999`, skips an occupied name | **Yes** — **[I]** |
| 11. immutable write | `write_record` → `write_atomic`: O_EXCL temp, `fsync`, `os.link`; committing and refusing an overwrite are the **same atomic operation** | **Yes** — **[I]** |
| 12. readback verification | `read_record`, re-canonicalise, compare digest | **Yes** — new, ~10 lines |
| 13. version guard (C1 only) | refuse `envelope_version != 1`; refuse `supersedes`/`superseded_by` present | **Yes** — new, ~4 lines |

**Failure semantics:**

| Situation | Behaviour |
|---|---|
| duplicate submission, same `envelope_id` | `write_atomic` refuses — "already exists and is immutable" |
| duplicate submission, same `request_id` **and** same digest | `REPLAY_EXACT` — return the original outcome, write nothing (idempotent) |
| same `request_id`, **different** digest | `REPLAY_CONFLICT` — refuse |
| byte-identical content, new identifier, new `request_id` | **accepted**, by design. Content-level idempotency has no committed requirement (readiness Q-H7-7) |
| allocation succeeds, write fails | the sequence **stays advanced**; the identifier is never reused. A gap in the series is the correct auditable outcome |
| partial write | `.CHENV-NNNN.tmp` is **reported** by `validate()`, never repaired; a later write to that name **refuses** rather than truncating (O_EXCL) |
| missing or malformed approval | refuse, write nothing |
| verifier unavailable | **refuse** — "Any failure to read is a denial, never a pass" |
| unauthorized threshold change | C1 refuses **all** replacements (stage 13), because it has no mechanism to authorize some |

**Summary: 7 of 13 stages are enforceable with code that exists today. The 6
that are not (5, 6, 7, 8, 9) all depend on the one missing contract of §3.1 plus
the schema amendment of §13.**

---

## 11. Proposed C2 supersession contract — **[PROPOSED]**, and an exact incompatibility

| Question | Proposal |
|---|---|
| how a new envelope references the previous one | `supersedes: CHENV-NNNN`, validated as a **CHENV identifier** (today it is `_text` — readiness F-1) and required to exist in the store |
| how the previous stays immutable | nothing is written to it. Ever |
| how the operator approves the replacement | §7's evidence on the **new** record, with `approval_domain` distinguishing a replacement from a first ingestion |
| version progression | `new.envelope_version == prior.envelope_version + 1`, same `subject_id` and `subject_type`, and the prior record must be the current head |
| concurrent replacements | `ImmutableStore.request_critical_section(request_id)` — an existing seam, today a documented no-op: "A store that must serialise replay lookup, identifier allocation, and the accepted write acquires its lock in an override, so no call site moves when that arrives." **C2 is that occasion.** Without it, two concurrent replacements of the same head both succeed and fork the chain |
| duplicate / replayed replacements | the same `request_id` + `request_digest` resolution as C1 |
| how the active envelope is determined | **derived, never stored**: the CHENV for a subject that **no other CHENV supersedes**. Forward-only traversal of `supersedes` |
| failed replacement | the prior envelope remains active, untouched. Nothing was written to it, so there is nothing to roll back |
| prior evaluations stay bound | already guaranteed: CHSTATE requires **both** `envelope_id` and `envelope_version` (`records.py` REQUIRED), and `supersession_rewrites_prior_evaluations: false` (R9) |

### 11.6 The exact incompatibility — **C2 BLOCKER**

**The CHENV schema declares `superseded_by` as an optional field (`:93-98`), and
there is no way to set it without mutating an immutable record.**

`superseded_by` on envelope *N* can only become known when envelope *N+1* is
written — which is **after** *N* was committed. Setting it then would require
updating *N*, but `mutability: immutable`, `update_methods: none`,
`delete_methods: none` (R8), and `HealthStore` **has no update method at all**
(H6 asserts the absence of twelve such names). So the field is, as declared,
**unwritable in any consistent sequence**.

Three resolutions, all requiring a ruling (**Q-H7A-5**):

1. **Treat `superseded_by` as permanently unused** and derive the active envelope
   from `supersedes` chains (§11). The schema keeps a field nothing ever sets —
   honest, but a reader will reasonably expect it to be populated.
2. **Remove `superseded_by` from the schema.** A schema amendment; the cleanest
   outcome; needs approval.
3. **Permit it only on a record written already knowing its successor** — which
   is impossible for the general case and would invert the ordering.

**I recommend (1) for C2's implementation plus (2) as a separate, explicitly
approved schema correction, and I have changed nothing.** This is exactly the
"identify the exact incompatibility; do not silently change the schema"
instruction, and it is why C2 is **HOLD** independently of the approval gap.

---

## 12. Threat and negative-test matrix

**Prevention** = the attack cannot succeed. **Detection** = it succeeds and is
discoverable afterwards. Rows marked **[needs contract]** cannot be tested until
§3.1 and §13 are resolved — and must not be stubbed, per the readiness
assessment's reasoning.

| # | Threat | Enforcing component | Expected refusal | Negative test | P/D |
|---|---|---|---|---|---|
| 1 | forged operator identity | *(none authenticates identity)* | — | **[needs contract]** | **neither** — §8.1 |
| 2 | compromised ingestion caller | `trusted_source` descriptor checks; immutable attribution | refuse unless the file is owned by the trusted UID | a file owned by another UID is refused; a group-writable component is refused | **partial / detection** |
| 3 | subject-authored thresholds | `_no_self_governance` pattern | refuse when `subject_id ∈ {actor, approving_authority}` | subject equals actor; equals authority; equals both | **prevention** **[needs contract]** |
| 4 | modified approved envelope | `approval_digest` vs computed digest | digest mismatch refuses | flip one threshold digit; reorder dimensions (must **pass** — canonical); add whitespace (must pass) | **prevention** **[needs contract]** |
| 5 | replay of an old approval | `request_id` + `request_digest` | `REPLAY_CONFLICT` | same `request_id`, different digest → refuse; same both → idempotent, no second record | **prevention** **[needs contract]** |
| 6 | duplicate under a new identifier | *(accepted by design)* | none | assert two records exist and both are readable | **neither** — Q-H7-7 |
| 7 | unauthorized threshold widening | C1 version guard; C2 approval | `envelope_version != 1` refuses in C1 | v2 submitted to C1 refuses; `supersedes` present refuses | **prevention** |
| 8 | revoked operator or key | Trust states exist; **no operator subject** | — | **[needs contract]** | **neither** |
| 9 | expired approval | *(no expiry field proposed — §7)* | — | assert the field does not exist, so no stale approval is silently honoured | **n/a by design** |
| 10 | concurrent supersession | `request_critical_section` override | second replacement refuses | two threads replacing one head → exactly one succeeds | **prevention** **[C2]** |
| 11 | tampered approval evidence | digest + immutability | mismatch refuses; stored record cannot be edited | edit a stored record → `validate()` reports it | **prevention + detection** |
| 12 | cross-plane filesystem access | import guard; `HealthStore` root refusal | refuse a root at/inside Fabric or Trust | roots at both plane paths refuse; approved imports moved to another Health module refuse | **prevention** — **[I]**, tested |
| 13 | symlink / path traversal | `trusted_source` O_NOFOLLOW + `fstat`; `path_for` fullmatch | refuse | symlinked input; symlinked store root; symlinked record path; `../`; newline identifier | **prevention** — **[I]**, tested |
| 14 | missing or unavailable verifier | fail-closed | refuse, never accept | adapter raising → refusal; unknown domain → denial | **prevention** **[needs contract]** |
| 15 | approval of a schema-invalid envelope | **ordering**: `parse()` before approval | schema refusal wins | a valid approval over a forbidden-field envelope still refuses, and the refusal names the **schema** failure | **prevention** |

Row 15 is the sharpest invariant-6/7 test: it proves approval cannot buy
validation, and that the refusal reports the right reason.

---

## 13. Required schema or ADR changes

### 13.1 Schema — required for Design B+, **not made here**

CHENV needs five new **optional** fields to carry approval evidence. They must be
optional, not required, or every existing fixture and the whole H1–H6A test
corpus becomes invalid at once:

| Field | Shape |
|---|---|
| `actor` | non-empty text |
| `approving_authority` | non-empty text |
| `approved_at` | offset-aware instant |
| `request_id` | opaque, bounded, constant-time compared |
| `approval_binding` | mapping: `{approval_domain, digest_algorithm, canonicalisation, approval_digest}` |

Plus, for C2, a decision on `superseded_by` (§11.6), and tightening
`supersedes`/`superseded_by` from `_text` to CHENV identifiers (F-1).

**Tension to flag:** `parse()`'s closed field set means C1 could **require**
these at ingestion while the *schema* keeps them optional — enforcement at the
ingestion boundary rather than in the record model. That keeps the H1 corpus
valid and still refuses an unapproved envelope. **[PROPOSED]**, and it is
**Q-H7A-3**.

### 13.2 ADR impact

| Artifact | Change | Why |
|---|---|---|
| ADR-0013 | **none required** | R12 already permits a read-only Trust adapter; R7 already mandates the approved-input precedent |
| ADR-0011 / Trust vocabulary | **one new domain** | `SUPPORTED_DOMAINS` must gain a policy-approval domain, or the gateway cannot be asked the §3 question. This is a Trust-plane change, not Health's to make |
| CHENV schema | **required** (§13.1) | — |
| `operational-envelope.md` | **recommended** | R5 requires an "approving identity" and names no field. It should name one once §13.1 lands |

---

## 14. Required new interfaces and dependencies

| Need | Form | Precedent |
|---|---|---|
| `tools/health/ingest.py` | new module, **eighth** allowlist entry | one module per increment |
| `tools/health/trust_adapter.py` | new module, **ninth** allowlist entry; read-only, exposes one question | R12's "read-only adapters" |
| `tools/common/trusted_source` import | module-scoped: `tools/health/ingest.py:tools.common.trusted_source` | H6A's pair form |
| `tools/common/yaml_strict` import | module-scoped: `tools/health/ingest.py:tools.common.yaml_strict` | same |
| `tools.trust.gateway` import | module-scoped: `tools/health/trust_adapter.py:tools.trust.gateway` — **and only that module** | H6A made this expressible; **R12 permits the read, R11 governs the other direction** |
| `hashlib` + `json` | Health-local digest helper, or a promoted `tools/common` primitive — **Q-H7A-4** | the convention is reused, not invented (§5.1) |
| `yaml` for the ingest module | a second serialiser pair: `tools/health/ingest.py:yaml` | H6's `store.py:yaml` pair |

**All of these remain module-scoped**, which is precisely the capability H6A
added. No new privileged service, no daemon, no network listener, no background
writer. **Note for the guard:** permitting `tools.trust.gateway` to one Health
module is the first time a *plane* import is authorised; H6A's per-module
enumeration (which greps each pure module for storage names) should be extended
to refuse `tools.trust` in every Health module except the adapter.

---

## 15. Unresolved operator decisions

- **Q-H7A-1 — is H7 the place to introduce cryptographic identity?** Design A
  needs the platform's first crypto dependency, key custody, distribution and
  revocation. My recommendation is **no**: that is a platform decision, and
  making it inside a Health increment would decide it for every plane.
- **Q-H7A-2 — may a new Trust domain be added for policy approval?** Without one,
  `gateway.query()` cannot be asked the §3 question and B+2 is unavailable,
  leaving B+ resting on items (i), (iii) and (iv) of §6.1 only.
- **Q-H7A-3 — where is approval enforced?** Required by the CHENV schema (invalidating the existing fixture corpus), or required at the C1 ingestion boundary with the schema keeping the fields optional? I recommend the latter.
- **Q-H7A-4 — the digest primitive.** A fourth in-plane copy of the
  sha256-over-canonical-JSON convention (~6 lines, matching three existing
  planes), or promotion to `tools/common`? The `immutable_store` precedent argues
  that a fourth copy "would be indefensible".
- **Q-H7A-5 — `superseded_by`.** Leave it permanently unset and derive the active
  envelope, or remove it from the schema? (§11.6)
- **Q-H7A-6 — the trusted UID.** Who supplies it, and is it recorded on the
  record? `trusted_source` requires it to be supplied, never inferred — so
  something must declare it, and that declaration is an authority statement.
- **Q-H7A-7 — residual risk acceptance.** B+ gives invariant 9 as detection and
  attribution, not prevention (§8.1). Is that acceptable, recorded as residual
  risk?
- **Q-H7A-8 — H7 scope.** Still open from the readiness assessment (Q-H7-1):
  ENG-0006-D `:389` assigns H7 both C1 **and** C2; this brief's §1 restates that
  pairing, while §8 asks only for a C2 *contract*. Given §11.6, I recommend
  **C1 implementation + C2 contract only**.

---

## 16. Recommended implementation sequence

| Step | Content | Gate |
|---|---|---|
| **0** | Rulings on Q-H7A-1…8 | **operator** |
| **1** | Trust-plane increment: one new domain in `SUPPORTED_DOMAINS` + policy rule. **Not Health's to write** | Trust review |
| **2** | CHENV schema amendment (§13.1), with `optional_fields` only | schema review |
| **3** | **H7A — C1 ingestion.** `tools/health/ingest.py`: trusted input, strict YAML, `parse()`, digest, approval validation, self-approval refusal, replay resolution, allocate, write, readback, version guard. Two allowlist entries, four module-scoped import exceptions. Rows 2–7, 10–15 of §12 | standard |
| **4** | **H7B — read-only Trust adapter.** `tools/health/trust_adapter.py`, one question, fail-closed. Row 14; rows 1 and 8 become testable only if step 1 lands | **boundary gate** — first Health module reading another plane |
| **5** | **H7C — C2 supersession.** `supersedes` as a validated identifier, version progression, `request_critical_section` override, active-envelope derivation. Rows 5, 10 | **architecture gate** |

Steps 1 and 2 are **not Health increments** and gate steps 3–5. H7 cannot
proceed past readiness without them.

---

## 17. GO / HOLD

**GO for C1 — conditional.** Under Design **B+**, with rulings on Q-H7A-2, 3, 4
and 7, C1 is implementable: 7 of 13 contract stages already work, the remaining
6 need the schema amendment plus (for one stage) the Trust domain, and every
import stays module-scoped. Estimated ~200–260 lines across two modules with
roughly 40 negative tests. **Without those rulings, HOLD** — the approval fields
have nowhere to live and the authority question cannot be asked.

**HOLD for C2 — unconditional.** Independently of approval, `superseded_by` as
declared is unwritable without mutating an immutable record (§11.6). That must be
ruled on before C2 is designed further, let alone implemented.

**The honest summary.** The platform has no cryptographic authority and does not
pretend to: its approval model is *declared identity, bound to a digest,
recorded immutably, with self-approval refused and failure closed.* That model is
built, reviewed and tested — in the Fabric. H7 should adopt it rather than invent
something stronger in one plane, and the decision to go further is a
platform-level one that does not belong inside a Health increment.

---

=== REVIEW PACKAGE ===

**Task:** ENG-0006-H7 authority design — architecture investigation and proposed
design for C1 and C2. Documentation only; no implementation authorization.

**Files Changed:** this report only.

**Tests Executed:** documentation and static validation —
`test-docs-static` (994), `test-static` (877), `test-platform-model` (1003),
`test-capability-health` (647), `test-developer-experience` (141), all passing.
Full regression on the committed tree, suites unmodified: **159 executed, 131
passing, 28 failing**, identical to the published baseline by normalized
membership, 0 newly failing. AC 25: **20** assertions. `HEAD^{tree}` was
`0241989d5db437580e32afa243311e37fbe40799` before and after the run. The 28 are
the pre-existing generation-installer and helper-ceremony debt; **the suite as a
whole is not GREEN and is not described as GREEN.**

**Commands Run:** `git rev-parse`, `git log`, `git status`, `git fetch`,
`git ls-remote`, `git show --stat`; `grep`/`sed`/`cat` over the artifacts cited
in §2 and §4; `stat /var/lib/kyri/health`; the validation suites. No push,
merge, rebase, tag or deploy. No key, credential, certificate or Trust record
created. No Root Authority ceremony initiated. No code, test, schema, ADR,
ontology, security policy, provisioning or production change.

**Known Risks:** invariant 9 is detection, not prevention (§8.1); no operator
authentication exists (§3); C2's `superseded_by` incompatibility (§11.6).

**Architecture Decisions:** none taken. Every contract is **[PROPOSED]**; eight
questions referred (§15); two corrections made to the H7 readiness assessment
(§2.3, §4).

**Questions for Reviewer:** Q-H7A-1 through Q-H7A-8 — §15.
