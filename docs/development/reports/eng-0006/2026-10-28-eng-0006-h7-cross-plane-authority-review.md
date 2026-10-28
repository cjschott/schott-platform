# ENG-0006-H7 — Cross-Plane Authority Contract Review

**Date:** 2026-10-28
**Branch:** `arch/eng-0006-health-runtime`
**Starting HEAD:** `064ff2175a7ef1f9596c7d7cbeffb6df48ea3fdb` (H7 authority design)
**Published remote:** `e47679c18ee8cb77156adea00cd0b48caaadb88a` (H6A)
**Nature:** Architecture review. **Documentation only — no implementation authorization.**
**Recommendation:** **HOLD for H7 implementation (C1 and C2). GO for operator rulings** on §13. B+ *can* be made fail-closed. As the H7 authority design specified it, though, it **cannot** be made enforceable. §2 lists eleven corrections, and the revised contract (§6–§10) rests on six rulings.

> **Labelling.** **[I]** = implemented, verified by reading code. **[E]** =
> verified empirically by a scratch probe run against this tree (probes lived in
> the session scratchpad, outside the repository; nothing was written to the
> repository or to any production path). **[C]** = committed requirement.
> **[PROPOSED]** = this report's proposal, **not authoritative**. Every contract
> in §6–§10 is **[PROPOSED]**.
>
> **Classification vocabulary used throughout.** **Prevention** — the act cannot
> succeed. **Detection** — it can succeed, and a defined check discovers it
> afterwards. **Attribution** — a record names who is *claimed* to have acted.
> **Audit evidence** — material a human reviewer can examine; it decides nothing
> by itself.

---

## 1. Verified starting state and session recovery

| Gate | Result |
|---|---|
| repository / branch | `/opt/schott-platform`, `arch/eng-0006-health-runtime` |
| local HEAD | `064ff2175a7ef1f9596c7d7cbeffb6df48ea3fdb` ✓ |
| published remote | `origin/arch/eng-0006-health-runtime` = `e47679c…` ✓; local is **2 ahead, 0 behind** (H7 readiness `239bd48`, H7 authority design `064ff21`, both unpushed) |
| worktree / index | clean; 0 untracked; 0 staged; no stash; one worktree |
| `/var/lib/kyri/health` | **absent** (`/var/lib/kyri` is `root:root 0711`) |

**Recovery of the interrupted session.** The interrupted session's transcript
holds the authorizing brief (issued 2026-10-21T23:52Z) and exactly one
assistant turn after it: `Login expired · Please run /login`. **No tool was
called, no file was written, and no report was started.** No ignored file, no
scratchpad file, and no stash carried H7 work. Nothing needed reconciling.
This report is the first and only artifact of the review, created from scratch
against the recovered brief's seven investigations and twelve deliverables.

---

## 2. Corrections to the H7 authority design (`064ff21`)

These change conclusions, not wording. Each is verified.

| # | The authority design said | What is actually true | Evidence |
|---|---|---|---|
| **K-1** | B+2: ask `gateway.query()` whether the approving authority is usable, once a new domain exists | **A store-backed `gateway.query()` cannot return `allowed=True` for any domain or any subject.** `_from_runtime` calls `evaluate_subject(store, subject_id, evaluated_at=…, operation=action, activity_kind="normal")` and passes no `capability`, `data_classification` or `target`. `evaluate_scope` denies every unnamed dimension. A fully TRUSTED subject whose scope matches exactly is denied through the gateway and allowed when `evaluate_subject` is called directly | `gateway.py:152-155`; `query.py:171-183`; `scope.py:138-150`. **[E]**: seeded root + TRUSTED `user` subject; direct `evaluate_subject` with four dimensions → `True`; gateway in all six domains → `False`, "no capability was supplied" |
| **K-2** | The new domain is the one missing contract | The runtime path is **domain-blind and context-blind**. `domain` is checked only for membership in `SUPPORTED_DOMAINS`. It is never compared to the record's `subject_type`, and `context` is discarded. A domain added there establishes nothing about the subject | `gateway.py:121-131,139-169` **[I]**; **[E]**: record `subject_type=user` queried as `host` gives an identical evaluation |
| **K-3** | R12's read-only Trust adapter would be new | **It already exists, in the Fabric, and it does not use the gateway.** `tools/fabric/trust_adapter.py` reads through `trust.query.get_current_trust` / `get_trust_record`. It checks the record's `subject_type` against an expected domain and requires the cited record to be the subject's *current* record. It refuses incoherent answers and collapses every failure to `unverified`. **That** is the precedent R12 describes | `fabric/trust_adapter.py:409-524` **[I]** |
| **K-4** | `SUPPORTED_DOMAINS` must gain a domain | Trust record `subject_type` is **open text**. The Fabric's host domain, `fabric-node`, is **not** in `SUPPORTED_DOMAINS`, and it works because the Fabric bypasses the gateway | `fabric/admission.py:228,231`; `policy.py:223-237` **[I]** |
| **K-5** | B+ adopts the Fabric's approval model | The Fabric **never verifies `approving_authority`**. It is required non-empty text. Trust verification in the Fabric concerns the *subject* being admitted, never the approver. Reusing the field gives **attribution, not authorization** | `fabric/evidence.py:160-169`; `admission.py:380-384,1255-1266` **[I]** |
| **K-6** | `request_digest` binds approval to payload | `request_digest` is **computed by the Fabric** over the caller's authoritative inputs. It is an idempotency key, not a statement by an approver. It gives replay classification. It binds no approval | `fabric/request_identity.py:201-237` **[I]** |
| **K-7** | `trusted_source` with a supplied trusted UID converts filesystem authority from assumed to checked | Checked, yes. But **every Kyri principal is one UID.** `cschott` (1000) owns `fabric/` and `trust/` (`0700`), will own the Health root (ENG-0006-D:746-747), runs every evaluator and ingestor, is the operator's login, and is the UID any agent session runs as. `expected_uid=1000` therefore **separates nothing**, and R7 ("authoring a threshold and running the evaluator are not the same authority") is unmet | ENG-0006-D:87-93,508,746-747; `id` → `uid=1000(cschott)` |
| **K-8** | `request_critical_section` is "today a documented no-op" | True for the **shared base and for `HealthStore`**, which does not override it. **False for the Fabric**, which overrides it with a real store-global `fcntl.flock` (`sequences/request_identity.lock`), non-reentrant, held across replay, allocation and the write | `common/immutable_store.py:245-252`; `fabric/store.py:199-206,249-302` **[I]**; **[E]**: a second `HealthStore` caller entered the section while the first held it |
| **K-9** | C1 accepts byte-identical content under a new identifier, by design | That makes **two version-1 heads for one subject**, so C2's derived head selection is ambiguous from the first duplicate. **C1 must refuse a version-1 envelope for any subject that already has a CHENV**, and that check is a check-then-act. **C1 needs the lock too, not only C2** | §9 |
| **K-10** | The digest convention appears "identically in three planes" | **At least four variants**, and they disagree. Fabric and Trust escape non-ASCII (`ensure_ascii` default). Platform-model fingerprints emit it literally. Observation uses `default=str`, which **coerces** unencodable values. Capability `canonical_json` refuses floats, values outside int64, U+0000 and lone surrogates | `observation/evidence_builder.py:36`; `trust/models.py:195`; `platform_model/evidence_fingerprint.py:98`; `capability/execution/canonical_json.py:169-223` **[I]**; **[E]**: `notes: café` gives different strict and Fabric-style digests |
| **K-11** | `parse()` before the digest proves the record is digestible | `parse()` validates `provenance` only as a non-empty mapping. A YAML `date`, a float or `2**70` inside it is **accepted**, written, and read back. A strict canonicaliser refuses it. **The digest step can refuse, so it must run before `allocate_id`** | `records.py:153-158,531` **[I]**; **[E]** |

Two findings outside the brief's direct questions are recorded because they
constrain the contract:

- **F-1. The Health import guard is stricter than the H7 design's interface list
  assumed.** Besides the AST pair allowlist, a grep rule refuses
  *any* absolute `import tools.(fabric|capability|trust|collectors)` in *any*
  Health module, with no pair exception (`tests/test-capability-health.sh:413-418`).
  Reusing `canonical_json` or reading Trust from Health therefore requires
  amending **both** rules, or moving the dependency into `tools/common`.
- **F-2. CHSTATE carries the same unwritable `superseded_by`.**
  `records.OPTIONAL["capability-health-state"]` includes `supersedes` and
  `superseded_by` (`records.py:480-481`). It is not in H7 scope. It has the
  same §8.4 incompatibility and should be ruled on together with CHENV's.

---

## 3. Existing authority evidence (inventory)

| Mechanism | Where | What it actually enforces | Class |
|---|---|---|---|
| Trust gateway | `trust/gateway.py` | closed domain set; deny-by-default; read-only; store mode always denies (K-1) | **[I]** |
| Trust evaluation | `trust/query.py:97-205` | lineage head → record → expiry → state → activity → scope, every dimension named | **[I]** |
| Trust decision write | `trust/evaluator.py:197-260` | actor must **equal** the active root's `authority_id` (public text, string equality); subject ≠ actor; written reason ≥5 words; evidence reference; verification method; approval source from a closed set; lineage; audit event | **[I]** |
| Operator Root Authority | `trust/root_authority.py`, `models.py:350-421` | "records what a human verified out of band"; one active root; no `approved_by` | **[I]** declaration only |
| Trust store write gate | `trust/store.py` over `immutable_store` | **filesystem permissions only** (`cschott 0700`) | **[I]** |
| Fabric Trust adapter | `fabric/trust_adapter.py` | read-only; subject-type match; current-record check; controlled refusal vocabulary | **[I]** |
| Fabric evidence | `fabric/evidence.py` | closed eight-field set; text shape; refuses an approver on unapproved kinds | **[I]** |
| Fabric replay | `fabric/request_identity.py` + `fabric/store.py` lock | `new` / `exact_replay` / `request_identity_conflict`, serialised by a store-global flock | **[I]** |
| Self-governance | `fabric/admission.py:521-541,1255` | declared-string inequality between subject and actor/approver | **[I]** |
| Governed evidence authority | `fabric/evidence_authority.py:108-190` | `open_trusted_regular_file(…, expected_uid, require_single_link=True, maximum_bytes, refuse_oversize=True)`; `loads_strict`; record id must equal the requested identity; fingerprint **recomputed** through the one released primitive | **[I]** |
| Root-owned publication ceremony | `provisioning/evidence/install-host-evidence.sh` | reviewed source pinned by **commit + sha256 + fingerprint**; published by root into `root:root 0755` / `0444`; `--verify`, `--install`, `--verify-installed`; nothing repaired | **[I]** |
| Lifecycle-locked authority transaction | `provisioning/authority_admission.py`, `authority_bootstrap.py:293` | flock'd transaction: precondition → allocate → publish immutable record → re-read with the **runtime reader** ("the reader is the authority on success") → advance pointer last | **[I]** |
| Strict canonical encoder | `capability/execution/canonical_json.py:211` | `serialise()`; already imported cross-package by `tools/provisioning/*` | **[I]** |
| Cryptographic signing / verification | — | **none exists** (unchanged from the authority design §2.1) | absent |
| Commit signing | repository | **not used** (`git log --format=%G?` → `N` on every recent commit) | absent |

---

## 4. Investigation 1 — Trust authority

### 4.1 `gateway.query()` traced

| Dimension | Code-owned mode (no store) | Store mode |
|---|---|---|
| **domain** | closed set; unknown → deny (`gateway.py:121`) | same membership gate, **then ignored** (K-2) |
| **subject** | `user` and `capability-package` → `_declared_policy`: a denial naming the gap, always (`policy.py:437-448`) | `current_lineage(store, subject_id)`: newest non-terminated lineage **by subject id alone** (`lineage.py:59-70`) |
| **authority** | none: reviewed code is the authority, and the verdict says so (`source: code-owned-policy`) | the decision chain to the active root; but see 4.3 for what "root" means at write time |
| **expiry** | n/a | `effective_state(stored, expiration, evaluated_at)`, no clock; caller must supply `evaluated_at` or the gateway denies (`gateway.py:144-150`) |
| **revocation** | n/a | REVOKED/EXPIRED/QUARANTINED etc. are unusable; state overrides scope (`scope.py:84-123`) |
| **scope** | n/a | four dimensions, each must be named; **the gateway names one** → always denied (K-1) |
| **failure** | deny with a reason | any exception → deny "unreadable state fails closed" (`gateway.py:156-162`) |

### 4.2 What a Health-policy approval domain would and would not establish

| Through the gateway, in either mode | Answer |
|---|---|
| Would it let the question be asked? | Yes, it would pass the membership gate |
| Would it ever answer *yes*? | **No.** Code-owned mode needs a new `evaluate_policy` branch, which means an approver list hard-coded in reviewed code. Store mode always denies (K-1) |
| Would a `yes` mean the approver approved *this envelope*? | **No.** The gateway answers "what is subject X's standing at T for action Y". It has no input for a payload, a digest, or an event |
| Would a `yes` mean X is a human? | **No.** A Trust subject is an identifier string |

**Conclusion: adding a domain to `SUPPORTED_DOMAINS` is neither necessary (K-4)
nor sufficient (K-1, K-2). B+2 as written is withdrawn.**

### 4.3 Can Trust distinguish a verified approval event from a self-declared approval record?

**Partly — and the part it can distinguish is not identity.**

What Trust *can* hold that a Health field cannot is a **governed decision**: a
`TrustDecision` written through `create_decision`. It names the active root as
actor, carries a written reason, at least one evidence reference, a verification
method and an approval source from a closed set, extends a lineage, and emits an
audit event. It is revocable, it is expirable, and it is evaluated by the one
evaluator. A field in a Health file has none of that.

What Trust *cannot* do is establish who wrote that decision.
`create_decision`'s authority check is `actor_authority_id ==
root["authority_id"]`, a **public identifier compared by string equality**
(`evaluator.py:220-225`). The Trust store's only write gate is filesystem
ownership (`cschott 0700`). So **any process running as `cschott` can mint a
root-authorized Trust decision.** A Trust-recorded approval is distinguishable
from a Health self-declaration by **provenance path, structure, revocability and
audit trail**, and indistinguishable by **who acted**.

### 4.4 Trust-domain feasibility, by option

| Option | Mechanism | Establishes | Does not establish | Verdict |
|---|---|---|---|---|
| **T0** — no Trust involvement | — | — | — | feasible; loses revocation |
| **T1** — gateway domain | `SUPPORTED_DOMAINS` + policy branch | nothing in store mode; a hard-coded list in code-owned mode | anything about this envelope | **infeasible** (K-1/K-2) |
| **T2** — approver standing | Fabric-style adapter: is the declared `approving_authority` a TRUSTED Trust subject of an `operator` type with scope `health.envelope.approve`? | "a root-chained decision says a subject *named* X may approve Health envelopes at T" | that X approved this envelope; that X is a person; that X is the one acting | feasible; **weak**: binds a name, not an act |
| **T3** — content-addressed approval | the approval **is** a Trust decision whose subject is the canonical approval digest (`subject_type` e.g. `capability-health-envelope-approval`, scope target = the Health subject). Health verifies it with a Fabric-style `verify_trust_record(…, expected_subject_type=…)` and requires `subject_id == computed digest` | a governed, revocable, root-chained Trust decision exists **about these exact bytes**, current at `evaluated_at` | who wrote it (4.3); that a human did | feasible; **mirrors the Fabric's package-trust pattern** (`admission.py:1684-1696`); **recommended if Trust is used at all** |

T3 respects R11 (Trust never reads Health; Health reads Trust) and R12 (read-only
adapter, released query interfaces only). It needs a production Root Authority.
**Whether the production Trust store has one was not inspected**: reading it is
outside a documentation review. It needs an ADR-0011 vocabulary ruling on the new
`subject_type`, and an import-guard amendment (F-1). **Operator decision O-4.**

---

## 5. Investigation 2 — Fabric precedent: what is enforced, and what is only recorded

| Mechanism | Enforceable property | Audit / attribution property | Survives an adversary running as `cschott`? |
|---|---|---|---|
| `actor` | shape; for advertisements, **equality** with the record's own subject field | names who is claimed to have acted | no: chosen by the caller |
| `approving_authority` | shape; **refused** on unapproved kinds | names who is claimed to have approved | no: never authenticated, never checked against Trust (K-5) |
| `_no_self_governance` | the declared subject is neither declared actor nor declared approver | — | no: defeated by declaring any other name. **It prevents honest self-approval, not forged approval** |
| `request_id` | bounded, safe, constant-time compared | links resubmissions | n/a: an idempotency key |
| `request_digest` | server-computed; a reused id with changed inputs is a conflict | records what was asked | yes, as replay classification; **it is not approval binding** (K-6) |
| store-global request lock | replay → allocate → write are serialised for every **cooperating** writer | — | no: `flock` is advisory, and the store is `cschott`-writable |
| Trust adapter on the subject | the admitted subject has usable, current, correctly typed standing | cites the Trust record | as strong as Trust's write gate (4.3) |
| governed evidence authority | the bytes come from a root-owned, single-link, size-bounded file whose fingerprint recomputes | — | **yes, against non-root writers**, because the trusted UID is not `cschott` |

**Reusing Fabric field names reproduces Fabric's audit and attribution
properties and none of its enforcement.** The Fabric's enforcement lives
elsewhere: in the lock, the server-computed digest, the subject's Trust
verification, and above all the **root-owned evidence authority**. That last one
is the only Fabric mechanism that separates principals, and it is the one the
H7 design did not adopt.

---

## 6. Investigation 3 — Proposed operator ceremony — **[PROPOSED]**

Modelled on `install-host-evidence.sh` (root-owned authority, pinned digest,
verify / install / verify-installed) and on `authority_admission.py` (locked
transaction, re-read by the runtime reader).

### 6.1 Principals and trusted execution boundary

| Principal | Is | May |
|---|---|---|
| **P-review** | a Git commit to a reviewed source | propose envelope content. Unsigned commits mean authorship is a self-declared `user.name` |
| **P-root** | root on `schai`, reached by the operator through `sudo` | publish an approval statement into the approval authority. **The only principal that can** |
| **P-health** | `cschott` (1000): ingestion, store, evaluators, and any agent session | read approvals; write CHENV records; **never** write the approval authority |

**Trusted execution boundary:** the kernel's enforcement of file ownership and
mode on the approval authority, plus `sudo`'s authentication of the operator.
Nothing inside Kyri is in the trusted boundary for the approval act itself.

### 6.2 The approval authority

`/var/lib/kyri/health-approvals/`: `root:root 0755`, every component root-owned
and not group- or world-writable, statements `root:root 0444`, single link.
Created once by an operator ceremony (H18-class), never by a library call. **The
identity is the location:** statement `<request_id>.yaml`, and nothing else.
Statements are **retained forever** and never deleted by Health. This resolves
the authority design's "submitted bytes are not retained" problem (§5.2 there):
the approved bytes *are* retained, root-owned, and re-verifiable.

### 6.3 The ceremony

| Step | Actor | Action | Writes |
|---|---|---|---|
| 1 | operator | author the approval statement (§7.1) from reviewed envelope content | nothing governed |
| 2 | P-health | `… health envelope digest <file>`: read-only; prints the canonical `approval_digest` and the raw-bytes sha256 | nothing |
| 3 | operator | inspect; place `approval_digest` in the statement; re-run step 2 and confirm agreement | nothing governed |
| 4 | **P-root** | `sudo …/publish-health-approval.sh --install <file> --sha256 <hex>`: refuses unless the bytes hash to the pinned value, the name equals `request_id`, the target name is free, and the statement parses strictly. Publishes `0444`, single link. **Writes nothing else; repairs nothing** | one root-owned statement |
| 5 | P-health | `ingest_envelope(store, request_id=…, approval_root=…, trusted_uid=0, evaluated_at=…)` (§7.3) | one CHENV, or nothing |
| 6 | P-health | `verify`: read-only. For every CHENV, re-derive the digest from the record, open the retained statement through `trusted_source`, compare digests, and confirm one CHENV per statement | nothing |

`sudo` records the invocation in the system journal. That is **audit evidence
outside Kyri**: tamperable by root, and not consulted by any check.

### 6.4 What the ceremony establishes

| Property | Established? |
|---|---|
| human identity | **No.** Nothing authenticates a person |
| operating-system identity | **Partly.** A principal able to create root-owned files on `schai` acted. Through `sudo`, that normally means someone who knew the password of an account in the `sudo` group at that moment. Not verified here: whether `NOPASSWD` is configured and what `timestamp_timeout` is (**O-1**) |
| control of an approved filesystem location | **Yes.** That is exactly what `trusted_source(expected_uid=0)` checks |
| the approver's declared name | **Attribution only**: text in a root-owned file |
| separation of authoring from evaluating (R7) | **Yes, for the first time**: P-health cannot produce an approval, and P-root does not run the evaluator |

### 6.5 Residual risk of a compromised operator or privileged caller — **not resolved**

| Adversary | Can forge an approval? | Can bypass ingestion and write CHENV directly? | Outcome |
|---|---|---|---|
| A1 honest mistake | — | — | **prevented** by digest agreement, strict parse, lock and version rules |
| A2 buggy Health caller (in-process) | **no**: approval comes from a root-owned file, not a parameter | yes, by calling `write_record` | bypass **detected** by `verify` (no matching statement) |
| A3 any process as `cschott`, including an agent session | **no**, unless it can reach root | **yes**: the store is `cschott 0700` | **detected** by `verify`. Forging a passing CHENV needs a root-owned statement for that exact digest |
| A4 `cschott` with a usable `sudo` credential: password known, `NOPASSWD`, or a **cached `sudo` ticket in the same terminal an agent is running in** | **yes** | yes | **neither prevented nor detected by Kyri.** Journal attribution only |
| A5 root | yes | yes | nothing in Kyri constrains root |

**A3's detection depends on `verify` being run.** Nothing runs it automatically
in H7. A4 is the realistic one on this host, because the operator's account is
in the `sudo` group and agent sessions run as that account. **Do not run step 4
from a terminal that hosts an agent session**, and invalidate the ticket
(`sudo -k`) before and after. That is procedure, not control. **Operator decision O-1.**

---

## 7. Exact approval verification contract — **[PROPOSED]**

### 7.1 The approval statement (approved input, closed schema)

```yaml
approval_statement_version: 1
approval_domain: capability-health-envelope
operation: initial                    # initial | replacement
request_id: "REQ-…"                   # Fabric rules: 1–200 printable ASCII, no space; equals the file stem
actor: "<declared identity>"
approving_authority: "<declared identity>"
approved_at: "2026-11-02T09:00:00-06:00"   # offset-aware; a YAML timestamp is refused (must be a string)
canonicalisation: kyri-strict-canonical-json/v1
digest_algorithm: sha256
approval_digest: "sha256:…"
trust_record_id: "TREC-…"             # present iff O-4 selects T3; absent otherwise
envelope:                             # CHENV content WITHOUT envelope_id and WITHOUT approval
  envelope_version: 1
  subject_type: capability-instance
  subject_id: CINST-000007
  # supersedes: CHENV-0003            # required iff operation == replacement
  dimensions: {…}
  evaluation: worst-dimension-wins
  provenance: {…}
```

Unknown fields refuse; missing fields refuse. No field defaults.

### 7.2 Verification stages, in order

| # | Stage | Refusal | Writes before refusal |
|---|---|---|---|
| V1 | `request_id` passes the Fabric's `validate_request_id` rules | `request-id-malformed` | nothing |
| V2 | open `<request_id>.yaml` via `open_trusted_regular_file(approval_root, name, expected_uid=0, require_single_link=True, maximum_bytes=65536, refuse_oversize=True)` | `approval-unavailable` | nothing |
| V3 | read once, decode UTF-8, `loads_strict` | `approval-unreadable` | nothing |
| V4 | closed statement schema; `approval_statement_version`, `canonicalisation` and `digest_algorithm` are each the one supported value; `approval_domain` matches; statement `request_id` equals the file stem | `approval-schema-invalid` / `approval-version-unsupported` | nothing |
| V5 | `records.parse("capability-health-envelope", {**envelope, "envelope_id": "CHENV-0000"})`: full record validation, against a **probe identity** that is never allocated (the Fabric's `PROBE_IDS` pattern) | the schema refusal, **named as such** | nothing |
| V6 | `operation` agrees with the envelope: `initial` ⇔ no `supersedes` ⇔ `envelope_version == 1` | `approval-operation-mismatch` | nothing |
| V7 | compute `approval_digest` (§8); **refusal-capable** (K-11) | `approval-not-canonicalisable` | nothing |
| V8 | computed digest equals the declared one, constant-time | `approval-digest-mismatch` | nothing |
| V9 | `subject_id ∉ {actor, approving_authority}` | `self-approval` | nothing |
| V10 | *(T3 only)* Fabric-style `verify_trust_record(trust_store, trust_record_id, evaluated_at, expected_subject_type=…)` is `verified`, its `subject_id == approval_digest`, and its scope contains the operation and the Health subject as target | `approval-trust-unverified` (adapter reason preserved) | nothing |
| — | **enter `HealthStore.request_critical_section`** (store-global flock, §9) | — | — |
| V11 | replay: a CHENV whose `approval.request_id` matches → same digest = **exact replay** (return that CHENV id); different digest = **conflict** | `request_identity_conflict` | nothing |
| V12 | chain rules (§9.3): `initial` → the subject has **no** CHENV; `replacement` → the subject's chain is well-formed, `supersedes == head`, `envelope_version == head.version + 1` | `envelope-subject-exists` / `envelope-chain-ambiguous` / `envelope-not-head` / `envelope-version-not-successor` | nothing |
| V13 | **pre-commit simulated readback**: `safe_dump` → `safe_load` in memory → re-parse → recompute digest → equal | `approval-roundtrip-unstable` | nothing |
| V14 | `allocate_id("capability-health-envelope")`; construct the record with `approval` (§8.3) | allocation refusal (`CHENV-9999`) | sequence advanced; gap is permanent and correct |
| V15 | `write_record` (O_EXCL temp, fsync, `os.link`) | store refusal | sequence advanced; possible `.tmp` debris, reported by `validate()` |
| V16 | `read_record` → `parse` → recompute digest → equal to `approval.approval_digest` | **`committed-unverified`** (§9.5) | **the record exists and is immutable** |
| — | release the section; return `accepted(CHENV-NNNN)` | — | — |

**Fail-closed properties.** No stage has a default, a skip flag or a fallback.
An exception anywhere before V14 writes nothing. The schema (V5) runs before any
approval stage, so an approval cannot buy validation and the refusal names the
schema failure (authority design §12 row 15, preserved). The verifier being
unavailable (V2, V10) is a refusal.

### 7.3 Interface

```python
def ingest_envelope(store, *, request_id, approval_root, trusted_uid,
                    evaluated_at, trust_store=None) -> IngestResult
```

There is no `authority`, `actor` or `approving_authority` parameter. All three
come from the root-owned statement. `trusted_uid` is supplied, never inferred.
**[PROPOSED]**: refuse `trusted_uid == os.geteuid()`, because that is the
configuration in which the check separates nothing (K-7). Fixtures run without
root, so they would need an explicit, named fixture opt-in, as
`allow_repository_root` already is.

---

## 8. Canonical payload-binding contract — **[PROPOSED]**

### 8.1 Representation

`kyri-strict-canonical-json/v1` = exactly the bytes of
`capability/execution/canonical_json.serialise`:

- UTF-8, with non-ASCII emitted literally
- object keys ordered by their UTF-8 bytes
- no insignificant whitespace
- integers within signed 64-bit only
- **no floats, no NaN or Infinity, no U+0000, no lone surrogates, no non-string keys, no other types**

It **refuses; never repairs**. It is the only one of the four existing variants
(K-10) that refuses rather than coerces, and the only one already imported across
packages (`tools/provisioning/*`).

### 8.2 Preimage: exactly what is covered

```
approval_digest = "sha256:" + hex(SHA-256(serialise({
    "approval_statement_version": 1,
    "approval_domain":     <statement>,
    "operation":           <statement>,
    "request_id":          <statement>,
    "actor":               <statement>,
    "approving_authority": <statement>,
    "approved_at":         <statement, the exact string>,
    "canonicalisation":    "kyri-strict-canonical-json/v1",
    "digest_algorithm":    "sha256",
    "envelope":            <parsed envelope content, every field present>
})))
```

| Field | Covered? | Why |
|---|---|---|
| every envelope content field, including `envelope_version`, `subject_type`, `subject_id`, `dimensions`, `evaluation`, `provenance`, `description`, `notes`, `review_due_at` | **yes** | the content being approved |
| `supersedes` | **yes** | a *prior*, already-allocated identifier, known at approval time. Covering it stops an approval to replace CHENV-0003 being applied to CHENV-0004 |
| `envelope_id` (the new record's) | **no** | it is **generated after approval** (V14). Including it is impossible, and guessing it would make allocation part of the approval. It is bound instead by placement (the evidence lives on the record) and by uniqueness (one CHENV per `request_id`, V11, enforced by `verify`) |
| `request_id`, `actor`, `approving_authority`, `approved_at`, `operation`, `approval_domain` | **yes** | the statement is approved along with the content. An identical envelope under a new `request_id` has a new digest |
| `approval_digest` | **no** | self-reference |
| `trust_record_id`, `approval_source` | **no** | they *locate* corroboration; they are not what is approved. Under T3 the Trust subject *is* the digest |
| `canonicalisation`, `digest_algorithm` | **yes**, as constants | an unknown version fails closed (the `request_identity.py` precedent) |

`approved_at` is covered as the **exact string**, never normalised, matching
`_instant`'s "returned unchanged" rule (`records.py:181-200`).

### 8.3 Placement on the record

```yaml
approval:
  approval_statement_version: 1
  approval_domain: capability-health-envelope
  operation: initial
  request_id: "REQ-…"
  actor: "…"
  approving_authority: "…"
  approved_at: "…"
  canonicalisation: kyri-strict-canonical-json/v1
  digest_algorithm: sha256
  approval_digest: "sha256:…"
  approval_source:
    authority: health-approvals        # a name, not a path
    name: "REQ-….yaml"
    sha256: "<64 hex of the exact retained bytes>"
  trust_record_id: "TREC-…"            # T3 only
```

**Two digests, two jobs.** `approval_digest` binds *meaning*: it is recomputable
from the stored record alone, on readback and forever. `approval_source.sha256`
binds the *retained bytes*: an operator can check it with `sha256sum` against the
root-owned file and no Kyri code. Together they close the authority design's
three-digest problem without binding to stored YAML bytes, which would be
circular.

### 8.4 Verification before persistence and after readback

Before: V7, V8, V13. After: V16, and `verify` (§6.3 step 6) at any later time.
**[E]**: on a temporary `HealthStore`, the strict digest of `parse(...).to_dict()`
before `write_record` equals the strict digest of `read_record(...)` afterwards,
for plain and non-ASCII content. Content the strict encoder cannot represent is
refused **before** any write.

### 8.5 Reuse or new utility

| Option | Verdict |
|---|---|
| import `tools.capability.execution.canonical_json` from Health | **rejected**: F-1 forbids it, and making Health depend on the Capability Runtime package inverts plane independence |
| fifth in-plane copy | **rejected**: K-10 is what four copies produced |
| **promote to `tools/common/canonical_json.py`** | **recommended.** A reviewed shared-library increment. Capability keeps its module path as a re-export, so no importer moves, and golden vectors prove byte equality on both paths. **O-3** |

`hashlib.sha256` is the standard library; no new dependency.

---

## 9. CHENV schema proposal and C2 supersession contract — **[PROPOSED]**

### 9.1 Exact proposed schema changes (not applied)

Against `platform-model/schemas/capability-health-envelope.schema.yaml`:

```diff
 required_fields:
   - envelope_id
   - envelope_version
   - subject_type
   - subject_id
   - dimensions
   - evaluation
   - provenance
+  # ENG-0006-H7. Immutable approval, carried on the record whose existence it
+  # justifies. Required, not optional: an envelope in the store without it is
+  # an envelope nobody approved. See approval_fields.
+  - approval

 optional_fields:
   - description
   - review_due_at
   - supersedes
-  - superseded_by
   - notes

+# ENG-0006-H7. The successor of an envelope is derived, never stored: it is
+# known only after the predecessor is immutable, so no consistent sequence can
+# write it. Named here so its presence is refused by name, not as "unknown".
+successor_representation: derived-from-supersedes
+supersedes_form: envelope-identifier       # fullmatch '^CHENV-[0-9]{4}$'
+supersedes_required_when: envelope_version-greater-than-1
+supersedes_forbidden_when: envelope_version-equals-1
+version_progression: predecessor-plus-one
+
+approval_fields:
+  required:
+    - approval_statement_version   # 1
+    - approval_domain              # capability-health-envelope
+    - operation                    # initial | replacement
+    - request_id
+    - actor
+    - approving_authority
+    - approved_at                  # offset-aware instant string
+    - canonicalisation             # kyri-strict-canonical-json/v1
+    - digest_algorithm             # sha256
+    - approval_digest              # '^sha256:[0-9a-f]{64}$'
+    - approval_source              # {authority, name, sha256}
+  optional:
+    - trust_record_id              # present iff the T3 ruling is adopted
+approval_signature_fields: forbidden       # no signing exists; see ENG-0006-H7 review
+
 forbidden_fields:
   - learned_threshold
   …
   - command
+  - superseded_by
```

The model mirror (`records.REQUIRED`, `OPTIONAL`, `FORBIDDEN`, and a new
`_approval` validator) belongs to the implementing increment, not here.

### 9.2 Versioning and backwards compatibility

- **There is no persisted CHENV anywhere.** `/var/lib/kyri/health` is absent, so
  there are no records to migrate and no prior record to mutate. The only
  consumers are the H1–H6A fixture corpus and the evaluators' tests.
- **Making `approval` required breaks those fixtures once, deliberately.** The
  alternative is optional in the model and required only at ingestion (authority
  design Q-H7A-3). That leaves `parse()`, and therefore the evaluators, accepting
  a CHENV nobody approved. An unapproved record written straight into the store
  would then be honoured. **Required is the fail-closed choice. O-2.**
- Statement and record version: `approval_statement_version: 1`. An unknown
  version refuses (V4). CHENV records carry no record-level schema version today.
  None is proposed; the approval block's version is the only new contract.
- `superseded_by`: moving it to `forbidden_fields` refuses it **by name**. No
  record carrying it exists, so nothing is invalidated. **F-2 (CHSTATE) is left
  for its own ruling.**

### 9.3 Chain model and deterministic active-head selection

For subject `S = (subject_type, subject_id)`, let `E(S)` be every CHENV with that
subject. `E(S)` is **well-formed** iff:

- **W1** exactly one member has `envelope_version == 1` and no `supersedes`
- **W2** every other member's `supersedes` names a member of `E(S)`
- **W3** each successor's version is its predecessor's plus one
- **W4** no two members name the same predecessor (**no fork**)
- **W5** every member carries a verifying `approval` (V16 / `verify`)

W1–W4 make `E(S)` a single path, which is acyclic because versions strictly
increase. **Head(S)** is the unique member that no member supersedes.

- `E(S) = ∅` → no envelope → `unmonitored` (CHENV `absent_envelope_means`).
- `E(S)` not well-formed → **no head.** Ingestion refuses every write for `S`
  (`envelope-chain-ambiguous`). The binding layer must **not** choose one. In
  particular, it must not use the highest id or the highest version as a
  tie-break. What evaluation reports for an ambiguous subject is **O-5**.
  `unmonitored` would be false, since envelopes exist; the candidates are a
  refusal or `review_required`.

### 9.4 Write protocol and the concurrency proof

`HealthStore` overrides `request_critical_section` with the Fabric's primitive:
one **store-global, non-reentrant `fcntl.flock(LOCK_EX)`** on
`sequences/request_identity.lock`, held from V11 through V16 for **every** CHENV
write, initial or replacement (K-8, K-9). `allocate_id`'s own sequence flock is a
different file, so nothing nests.

**Claim.** Two replacements `R1`, `R2` of the same head `H` cannot both be
accepted as the unique successor.

**Proof sketch.**

1. Every accepted CHENV write happens inside the section, and `LOCK_EX` admits
   one holder at a time. Without loss of generality, `R1` enters first.
2. If `R1` is accepted, its `os.link` returned before `R1` released the section,
   so the new name is in the directory.
3. `R2` enters only after that release. At V12 it lists `E(S)` from the
   directory, fresh: nothing is cached across sections. That listing includes
   `R1`, and `R1.supersedes = H`, so `H` is no longer the head; the head is `R1`.
4. `R2.supersedes = H ≠ Head(S)` → `envelope-not-head`. Nothing is written.
5. If `R1` was refused or crashed before its link, nothing of `R1` is visible and
   `R2` may legitimately succeed. If `R1` crashed after its link, `R1` exists, `R2`
   is refused, and `R1`'s submitter resolves its own outcome by resubmitting the
   same `request_id` and digest (V11 → exact replay).

The same argument shows two `initial` submissions for one subject cannot both
succeed (V12, "subject exists"). **So at most one successor per head, and at most
one root per subject. ∎**

**Conditions the proof depends on. Each is an assumption, not a guarantee:**

- (a) **every** writer goes through the section; `flock` is advisory
- (b) one host and a local filesystem; `flock` across NFS is not this primitive
- (c) V12 reads the directory inside the section
- (d) no nested acquisition

**(a) is false for adversary A3**, who can write the store directly. Against A3
the property is **detection**: `verify` reports a W4 fork or a W5 failure. It is
not prevention.

**Optional structural backstop: S2, not recommended for H7.** A lock-independent
**succession claim**: `successions/CHENV-NNNN` created `O_EXCL` / `os.link`,
naming the successor, makes a second successor fail `EEXIST` even if the lock is
bypassed. It also introduces a new persisted artifact class, a pending-disposition
state for a claim whose record never landed (the CIMP precedent), and a second
input to head selection. **That is an ADR-level ruling (O-6), not an H7 detail.**

### 9.5 Replay and failure recovery

| Situation | Outcome |
|---|---|
| same `request_id`, same digest | exact replay. Return the original CHENV id **even if the head has since moved**, because replay answers for the request, not the head |
| same `request_id`, different digest | `request_identity_conflict`; nothing written |
| new `request_id`, identical content, `initial` | `envelope-subject-exists`. **Closes readiness Q-H7-7 for the collision case** |
| new `request_id`, identical replacement after the first was accepted | `envelope-not-head` |
| refusal at V1–V13 | nothing written; no identifier consumed |
| failure after V14 | gap in the series, permanent and correct |
| `.tmp` debris after V15 | reported by `validate()`; later writes to that name refuse (O_EXCL) |
| process death holding the section | the kernel releases `flock` when the descriptor closes; the lock file is never deleted |
| **V16 mismatch (`committed-unverified`)** | the record **exists and cannot be removed**. Ingestion reports failure, not success. `verify` flags W5, the subject has no well-formed chain, and writes refuse until an operator rules. **Recovery is an operator decision (O-5)**, because the immutable model has no undo |

---

## 10. Investigation 7 — Security review

### 10.1 Control classification

| Control | Prevention | Detection | Attribution | Audit evidence |
|---|---|---|---|---|
| root-owned approval authority + `trusted_source(expected_uid=0)` | **yes**, against A1–A3 forging an approval | — | — | retained statements |
| `sudo` for publication | **yes** against A3; **no** against A4 | — | OS account, in the journal | journal |
| strict parse + closed statement schema (V3–V6) | **yes** (malformed or ambiguous input) | — | — | — |
| canonical `approval_digest` (V7, V8) | **yes**, against accidental drift between approval and ingestion | yes, on readback | — | in the record |
| **digest against a deliberate adversary** | **no**: whoever can write the statement can recompute the digest. **Its strength is the write protection of the file it sits in** | — | — | — |
| `approval_source.sha256` | — | **yes**: record ↔ retained bytes, checkable outside Kyri | — | yes |
| self-approval refusal (V9) | **yes**, against honest self-approval only | — | — | — |
| declared `actor` / `approving_authority` | **no** | — | **yes (claimed)** | yes |
| T3 Trust decision (V10) | **yes** against approval of unrecorded, revoked or expired content, **for cooperating writers**; **no** against A3 (the Trust store is `cschott`-writable, 4.3) | yes: Trust audit and lineage | root actor (claimed) | Trust audit events |
| store-global lock (V11–V16) | **yes** for cooperating writers (§9.4); **no** against A3 | — | — | — |
| chain rules W1–W4 | **yes** at ingestion | **yes** via `verify` / `validate()` | — | — |
| readback (V16) | — | **yes** | — | — |
| `verify` command | — | **yes**, against A2/A3 bypass, **when run** | — | — |
| immutability (`os.link`, no update or delete) | **yes** against in-API mutation; **no** against A3 at the filesystem | yes, via digest | — | — |
| import guard (H4A/H4B/H6A) | **yes**, statically, against an in-tree Health module reaching another plane | — | — | — |

### 10.2 Properties that cannot be established without cryptographic operator authentication

These are **not provided by B+R, T3, or any combination of existing mechanisms**:

1. **That a specific human approved.** Every identity in this design is either
   OS-level (root via `sudo`) or a self-declared string.
2. **Non-repudiation.** An operator can deny an approval. The only counter-evidence
   is root-tamperable journal text.
3. **Prevention of approval forgery by A4 or A5.** Possession of root, or of a
   usable `sudo` credential, *is* approval.
4. **Integrity of approvals and records against root.** Root can rewrite both the
   statement and the record consistently.
5. **Prevention of direct store writes by A3**, while the Health store is
   `cschott`-owned. That would need a separate store UID (H18-class) or signed
   records.
6. **Off-host verification of approval provenance.** Nothing verifiable leaves
   `schai`.
7. **Distinguishing an operator from an agent acting in the operator's session**
   when that session holds a `sudo` ticket.

**Design A** (detached signatures) would address 1, 2, 3 for A4, 6 and 7.
Prevention against A5 would still need key custody outside the host. Design A
remains a platform-level decision outside H7 (authority design Q-H7A-1,
unchanged).

### 10.3 Residual risks — recorded, **not resolved**

| # | Risk | Severity on this host | Mitigation available | State |
|---|---|---|---|---|
| RR-1 | A4: the operator account is in `sudo`; agent sessions share that account; a cached ticket approves | **high** | procedure (`sudo -k`; never from an agent terminal; `timestamp_timeout=0` for the ceremony); not enforceable by Kyri | **open — O-1** |
| RR-2 | A3 writes CHENV records directly | medium | `verify` detects; nothing runs `verify` automatically | **open** |
| RR-3 | A3 mints a T3 Trust decision | medium | none inside Trust (4.3) | **open; inherited from the Trust plane** |
| RR-4 | `committed-unverified` leaves an immutable bad head | low probability, high cost | operator ruling | **open — O-5** |
| RR-5 | No human identity; declared names are attribution only | inherent | Design A | **accepted only if O-7 accepts it** |
| RR-6 | Revocation after ingestion has no effect: T3 is checked once, at V10 | medium | re-check at evaluation, which is outside H7 and would make evaluation depend on Trust availability | **open, by design choice** |
| RR-7 | `verify`'s own correctness is unaudited code running as `cschott` | inherent | — | **open** |

---

## 11. Revised design B+R, against the brief's question

> *Can the proposed B+ approval model be made into an enforceable, fail-closed
> contract using the existing Trust and Fabric mechanisms?*

- **Fail-closed: yes.** Every stage in §7.2 refuses without defaults, and every
  refusal before V14 writes nothing.
- **Enforceable: only after three corrections to B+.**
  1. Replace "trusted UID supplied" with **trusted UID = root, through a
     root-owned approval authority** (K-7). This is the one change that turns
     B+'s filesystem check into a separation of principals.
  2. Replace B+2's gateway query with **either nothing (T0) or a Fabric-style
     content-addressed Trust adapter (T3)** (K-1–K-4).
  3. **Give `HealthStore` the Fabric's store-global lock and apply it to C1 as
     well as C2** (K-8, K-9).
- **Using existing mechanisms: almost entirely.** `trusted_source`,
  `yaml_strict`, `canonical_json`, the Fabric's replay rules and lock, the
  Fabric's Trust adapter shape, the evidence-authority read pattern and the
  `install-host-evidence.sh` ceremony shape all exist. What is new: one schema
  amendment, one shared-library promotion, one `HealthStore` override, two Health
  modules, one root ceremony script, one provisioning step for the approval
  authority, and (T3 only) one Trust vocabulary ruling.
- **What it still is: prevention against A1–A3 forging approval; detection of A2
  and A3 bypassing ingestion; nothing against A4 or A5; and no human identity at
  all.**

---

## 12. Required changes

| Plane | Change | Gate |
|---|---|---|
| **Trust** | T0: none. T3: ADR-0011 vocabulary ruling for an approval `subject_type`; no code change, because the released query interface suffices. **No change to `SUPPORTED_DOMAINS`** (K-4) | Trust review |
| **Trust (informational)** | K-1: a store-backed `gateway.query()` cannot allow anything. Not Health's to fix; it should be **reported to the Trust plane** as a latent defect or an undocumented design property | Trust owner |
| **Shared library** | promote `canonical_json` to `tools/common`, with a capability re-export and golden byte-equality vectors | shared-library review |
| **Health — schema** | §9.1 | schema review |
| **Health — model** | `approval` validator; `supersedes` as a CHENV identifier; `superseded_by` forbidden; V6 rules in `parse()` | standard |
| **Health — store** | `request_critical_section` override (store-global flock), mirroring `fabric/store.py:199-302` | standard |
| **Health — ingest** | new `tools/health/ingest.py` (V1–V16) and `verify` | standard |
| **Health — Trust adapter** | *(T3 only)* `tools/health/trust_adapter.py`, reading `tools.trust.query` / `identifiers` / `models` only | **boundary gate**: first Health module to read another plane |
| **Health — guard** | pair allowlist entries for `tools.common.trusted_source`, `tools.common.yaml_strict`, `tools.common.canonical_json` (ingest); a `yaml` serialiser pair for ingest; *(T3)* the grep rule (F-1) and the AST allowlist amended for the adapter module alone, with every other Health module still refusing `tools.trust` | standard + boundary gate |
| **Provisioning** | create `/var/lib/kyri/health-approvals` `root:root 0755` (H18-class); `publish-health-approval.sh` with `--verify`, `--install` and `--verify-installed`, `set -Eeuo pipefail`, nothing repaired | **operator gate** |
| **Docs** | `operational-envelope.md` R5: name `approval.approving_authority` as the "approving identity" and say plainly that it is attribution; ADR-0013: none required (R7 and R12 are satisfied as written) | doc review |

---

## 13. Explicit operator decisions

Each one either replaces or confirms the authority design's questions.

| # | Decision | Recommendation | Supersedes |
|---|---|---|---|
| **O-1** | Is root, through `sudo`, the approval principal? And under what `sudo` policy: password required, `timestamp_timeout`, and never from an agent session? Verify that `NOPASSWD` is **not** configured for the operator | **yes, root**; the procedural controls in RR-1 | Q-H7A-6 |
| **O-2** | Is `approval` **required** in the CHENV schema, accepting a one-time fixture update? | **required** | Q-H7A-3 (reversed) |
| **O-3** | Promote `canonical_json` to `tools/common`? | **yes** | Q-H7A-4 |
| **O-4** | Trust involvement: T0 (none) or T3 (content-addressed Trust approval, needing a production Root Authority and an ADR-0011 vocabulary ruling)? | **T0 for the first H7 increment, T3 as a separate later increment.** T3 adds revocation before ingestion and a governed audit trail, but not authentication (4.3) | Q-H7A-2 (reframed) |
| **O-5** | What evaluation reports for an ambiguous chain, and how an operator recovers a `committed-unverified` head | refusal plus `review_required`; recovery by an approved replacement whose `supersedes` names the bad head, with W5 relaxed for that one link and the fact recorded | new |
| **O-6** | S2 succession claims (§9.4)? | **no** for H7 | new |
| **O-7** | Accept RR-1…RR-7 as residual risk: approval without human authentication, and detection rather than prevention for A3 bypass | the operator's call; this report does not presume it | Q-H7A-7 |
| **O-8** | Report K-1 (gateway store mode cannot allow) to the Trust plane? | **yes** | new |
| **O-9** | H7 scope: C1 and C2 together, or C1 first? | **one increment for C1 + C2**, because the lock, the chain rules and the replay rules are shared, and K-9 means C1 cannot be correct without C2's head rules | Q-H7A-8 (reversed) |
| **O-10** | CHSTATE `superseded_by` (F-2) | rule on it with §9.1, and implement it separately | new |

Q-H7A-1 (no crypto in H7) and Q-H7A-5 (`superseded_by`: here, forbid it and
derive the successor) are carried forward. The first is unchanged; the second is
now concrete.

---

## 14. GO / HOLD

**HOLD — H7 implementation, both C1 and C2.** Three reasons:

- The H7 authority design's B+ is not enforceable as specified (K-1, K-7).
- C1 cannot be made correct without C2's head rules and a lock `HealthStore`
  does not have (K-8, K-9).
- Its contract depends on O-1, O-2, O-3, O-4, O-5 and O-7, and on two
  non-Health prerequisites: the `canonical_json` promotion and the approval
  authority's provisioning.

**GO — for the rulings in §13.** Once they are made, the contract in §6–§9 is
complete enough to implement without further design. It uses existing,
reviewed mechanisms for every step except the six listed in §11.

**C2's former unconditional HOLD is reduced to conditional.** The `superseded_by`
incompatibility now has a concrete, non-mutating resolution (§9.1), and the
concurrency contract has a stated primitive and proof (§9.4). Both still need
rulings.

**The honest summary.** The platform's approval model is attribution, bound to a
digest, recorded immutably, with self-approval refused and failure closed. That
is real, and it is **not authorization**. On this host, every Kyri principal is
one UID, so the one move that makes approval mean something is to put it behind
a principal Health cannot be: root, through a reviewed ceremony. The platform
already does exactly that for Platform Evidence. Beyond that line, approval is
whoever holds root or a live `sudo` ticket. Closing that gap needs cryptographic
operator authentication, and this report does not claim otherwise.

---

=== REVIEW PACKAGE ===

**Task:** ENG-0006-H7 Cross-Plane Authority Contract Review: resumed after an
interrupted session that never started work (§1). Documentation only.

**Files Changed:**
`docs/development/reports/eng-0006/2026-10-28-eng-0006-h7-cross-plane-authority-review.md`
(new). Nothing else.

**Tests Executed:** documentation and static validation suites. The results are
in the commit message and the session report, not restated here, because this
file is committed after they run.

**Commands Run:** `git rev-parse`, `git status`, `git log`, `git show --stat`,
`git worktree list`, `git stash list`, `git fetch --dry-run`; transcript
inspection of the interrupted session; `ls`/`stat` on `/var/lib/kyri`; `grep`,
`sed` and `cat` over the sources cited; two scratch Python probes **outside the
repository** against temporary stores (gateway verdicts; digest round-trip,
canonicalisation variants, YAML-native types, `HealthStore` section exclusivity).
No `sudo`. The production Trust, Fabric or Health store was not read. No push,
merge, rebase, tag or deploy. No key, credential, certificate or Trust record
created outside temporary directories. No Root Authority ceremony. No code, test,
schema, ADR, ontology, security policy or provisioning change.

**Known Risks:** RR-1…RR-7 (§10.3), unresolved.

**Architecture Decisions:** none taken. Eleven corrections to the H7 authority
design (§2); every contract is **[PROPOSED]**.

**Questions for Reviewer:** O-1…O-10 (§13).
