# ENG-0005 G11-F — CADV-000002 Governed Advertisement Renewal (Rehearsal and Preflight)

**Date:** 2026-08-28
**Checkpoint:** G11-F
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

> ## ⏱ THE REVIEWED BODY EXPIRES AT
> ## `2026-08-29T09:24:51-05:00`
>
> G11-A freshness requires `observed_at <= recorded_at < valid_until`, judged
> against the body's own `recorded_at` and never against a clock. The frozen
> `recorded_at` is `2026-08-28T09:24:51-05:00`, so the body remains registrable
> for **24 hours from preparation**.
>
> **If reviewer approval and operator publication cannot both complete before
> that instant, regenerate the body — do not weaken the freshness rule.** §12
> gives the exact regeneration procedure; it changes the timestamps, the body
> digest and the request digest, and nothing else.

---

## 1. Objective and outcome

**Objective.** Prepare, rehearse and freeze the first governed advertisement
renewal — `CADV-000002 supersedes CADV-000001` — and prove it against the real
released operation without spending production authority.

**Outcome: READY_FOR_OPERATOR_FREEZE.**

This checkpoint performed **step A only** — derive, rehearse, freeze the
candidate. Steps B (reviewer approval), C (operator publication of the input)
and D (the production write) remain separate acts.

- The G11-A3 renewal semantics were **reconstructed from source**, not assumed
  (§4), and the central question the brief posed is answered decisively:
  **an expired advertisement is a lawful predecessor.** `advertisement-not-fresh`
  is enforced in exactly two places, both of them *consumption* paths, and in
  neither of the renewal rules (§4.3).
- **22 fixture assertions pass** against the real
  `admission.register_advertisement`, covering all seventeen cases the brief
  named, in the actual released refusal vocabulary (§9).
- A **genuine read-only production preflight** was possible without publishing
  to `/etc/kyri/fabric` and without weakening approved-directory containment
  (§10). It returns `would_accept: true`, `mutated: false`,
  `predicted_record_id: CADV-000002`.
- The fixture rehearsal and the production preflight produce the **same request
  digest** — `sha256:4703c974…f80654` — which is the cross-check that the
  rehearsed body and the reviewed body are one body.
- **No source change was required or made.** `IMPLEMENTATION_COMMIT=NONE`.
- Production is **byte-identical** before and after: Fabric, Trust, Artifact,
  Platform Evidence and the installed runtime all unchanged; `CADV` count 1,
  sequence 1, `CADV-000002` absent, CINST/CROUTE/CSEL all zero.

**One correction was made, and it was to my own test harness, not to governed
behaviour** (§9.1): I asserted the conflict reason as `request-identity-conflict`
where the released vocabulary is `request_identity_conflict`. The behaviour was
correct; the expectation was wrong.

---

## 2. Starting authority

| Gate | Observed | |
|---|---|---|
| Repository | `/opt/schott-platform` | PASS |
| Branch | `arch/eng-0005-execution-transition` | PASS |
| HEAD | `f751e4bda02324d42e1135acbc172433008c7694` | PASS |
| Worktree | clean | PASS |
| G11-A…E authority ancestors of HEAD | `18abf0f e9e6405 16532ae 6016d4f 5f9347b ac60ec6 dd97482 f751e4b` — all YES | PASS |
| Installed runtime | **57** objects | PASS |
| `tools/fabric` installed | 9 files | PASS |
| Installed-only import closure | **PASS** — 40 `tools` modules, 0 strays | PASS |
| Implementation authority | `CGEN-000000000001`, digest `fc9a3ec3…0163` | PASS |
| CADV count / sequence | 1 / 1 | PASS |
| `CADV-000002` | **absent** | PASS |
| CINST / CROUTE / CSEL | 0 / 0 / 0 | PASS |
| Root Authority | unmounted | PASS |

```
Fabric   7780dacf274f57e000a0ab93208e7b89a6b1933ed2c181cec5f79a49119ab072
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact 30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
Runtime  80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b
```

All four governance authorities match the G11-E post-install capture exactly.

---

## 3. Predecessor state, and the proof that it has expired

`CADV-000001`, in full, as it stands in production:

```yaml
advertised_resource_profile:
  architecture: x86-64
advertisement_id: CADV-000001
capability_host_id: CHOST-0001
capability_package_id: CPKG-0001
contract_id: CCON-0001
evidence:
  actor: CHOST-0001
  approving_authority: null
  causal_references: [CHOST-0001, CPKG-0001, CCON-0001]
  reason_category: advertisement-registration
  recorded_at: '2026-08-26T14:13:53-05:00'
  request_digest: sha256:f8b1a42607ea287c00bc0f5af8145743af9cfcd869302b09ec2792ab7a23a38a
  request_id: s5b2-register-advertisement-cpkg-0001-chost-0001
kind: capability-advertisement
observed_at: '2026-08-26T14:13:53-05:00'
satisfied_contract_versions: [1.0.0]
valid_until: '2026-08-27T14:13:53-05:00'
```

```
valid_until  2026-08-27T14:13:53-05:00
now          2026-08-28T09:26:10-05:00
verdict      EXPIRED  (by ~19h 12m)
```

It carries **no `supersedes`** and **no `superseded_by`**: it is the root of its
chain and remains the chain head until a successor names it.

---

## 4. Reconstructed G11-A3 renewal semantics

Derived from `tools/fabric/admission.py` and `tools/fabric/evidence.py` at the
installed reviewed source, not assumed.

### 4.1 The operation

`register_advertisement(...)`, the **same** operation that created
`CADV-000001`, with the optional `supersedes` argument supplied. There is no
separate renewal verb. CLI: `register-advertisement`, present in
`WRITE_OPERATIONS` with `needs_trust=False` and in `CREATED_KINDS` as
`capability-advertisement` — so it is preflight-capable.

### 4.2 The renewal rules, in the order they run

Every rule a first advertisement is held to runs first; renewal adds three.

| # | Rule | Refusal |
|---|---|---|
| — | `approving_authority` must be absent | `unexpected-approving-authority` |
| — | all three instants timezone-aware | structural |
| — | `valid_until > observed_at` | `invalid-validity-window` |
| — | `observed_at <= recorded_at < valid_until` | `invalid-validity-window` |
| — | `supersedes` syntactically a `capability-advertisement` identifier | structural |
| — | `actor == capability_host_id` | `actor-is-not-the-subject` |
| — | host chain head is this host | `host-record-superseded` |
| — | `package.contract_id == contract_id` | `contract-not-of-package` |
| — | versions ⊆ package's declared versions | `versions-not-declared` |
| — | `satisfies(claim, host.verified_resource_profile)` | `resource-claim-not-verified` |
| **R1** | the predecessor resolves | `unresolved-reference` (NOT_FOUND) |
| **R2** | `prior.capability_host_id == capability_host_id` | `renewal-of-another-host` |
| **R3** | `prior.capability_package_id == capability_package_id` | `renewal-changes-package` |
| **R4** | `advertisement_head(store, supersedes) == supersedes` | `renewal-predecessor-not-current` |

**There is deliberately no contract rule at R-level.** The source states why: a
package names exactly one contract and the body's contract was already required
to be that one, so a renewal naming a different contract is refused earlier as
`contract-not-of-package`. *"A token nothing can emit is vocabulary that
documents a check the code does not make."* Proven in §9, case 12.

### 4.3 The load-bearing finding — expiry does not bar supersession

**No renewal rule reads `valid_until` of the predecessor.** `advertisement-not-fresh`
is defined twice and enforced in exactly two places, both of them consumption:

```
tools/fabric/admission.py:1596,1598   admit_instance — consuming an advertisement to admit a CINST
tools/fabric/eligibility.py:554       C5 eligibility — consuming it at selection time
```

Neither is in `register_advertisement`. So the model the brief asked me to prove
is the model the source implements:

> **Expiry makes `CADV-000001` ineligible for consumption. It does not erase its
> historical identity, its chain position, or its capacity to be lawfully
> superseded.**

That is not merely permitted, it is necessary: if expiry barred supersession, an
advertisement that lapsed could never be renewed, and the chain would be
permanently stuck at a head nothing could replace. **No STOP condition. Source
does not contradict the model — it requires it.**

### 4.4 `supersedes` semantics, reverse lookup, and `superseded_by`

Supersession is **stated forward by the successor and read backwards**. The
predecessor is read and never written:

> *"nothing here gives the predecessor a `superseded_by`, because an immutable
> record that acquires a field later was not immutable."*

`_successors()` builds the reverse map by walking every record's `supersedes`
field. `advertisement_head()` walks it to the end. Refusals:

- two records naming one predecessor → `advertisement-chain-forked`
- a loop → `advertisement-chain-cyclic`
- a successor whose predecessor is absent, mis-kinded, or unreadable →
  `advertisement-chain-incoherent` — *"a record at the end of a broken chain is
  not evidence that it is current, it is evidence that something is missing"*

**`superseded_by` remains derived legacy structure** — present on the model,
written by nothing. Confirmed empirically in §9 (case 4b), and consistent with
G11-A §7 and G11-C §15.

### 4.5 Self-loop and cycle protection

There is deliberately **no `renewal-supersedes-itself`**. The source's reasoning:
a new record's identity is minted by the store *after* every check has passed, so
a claim cannot name itself as its predecessor — there is nothing to name yet. A
self-loop can exist only in a store damaged into holding one, and that is a
cycle, refused by the traversal as `advertisement-chain-cyclic`.

I did not take that on faith: §9 case 9 **constructs** the damaged store and
confirms the refusal comes from the governed traversal.

### 4.6 Evidence semantics

`evidence.py` enforces the pairing **symmetrically** — a record naming a
predecessor must declare the supersession category, and one declaring the
category must name a predecessor, *"so a record that supersedes another cannot
hide the fact by declaring some other reason."* Additionally the predecessor
must appear among `causal_references`.

So the successor's evidence differs from `CADV-000001`'s in exactly two ways:

```
reason_category    : "advertisement-registration"  ->  "supersession"
causal_references  : [CHOST-0001, CPKG-0001, CCON-0001]
                     -> [CHOST-0001, CPKG-0001, CCON-0001, CADV-000001]
```

Both are produced by the operation, not by the operator body.

### 4.7 Identity, request identity, replay

Identity is allocated by the store after all checks pass; `peek_next_id` predicts
it read-only by applying the allocator's own rule without advancing the sequence.
Request identity is the governed digest over the body; an identical replay is
`exact-replay` returning the original identity, and the same `request_id` with a
changed body is `conflict` / `request_identity_conflict`.

---

## 5. Validity policy

**The 24-hour bootstrap window is unchanged**, and no committed authority since
G11-B revises it. It was an explicit reviewer/operator ruling recorded in
S5-B2A §"Advertisement duration — exactly 24 hours", and reaffirmed in S5-B2B
§"valid_until − observed_at == 24 hours".

The expired timestamps were **not reused**. A fresh instant was taken once from
the real clock at preparation time and frozen into the reviewed bytes; nothing
downstream reads a clock.

```
T = observed_at = recorded_at = 2026-08-28T09:24:51-05:00
V = valid_until                = 2026-08-29T09:24:51-05:00

valid_until - observed_at  : 1 day, 0:00:00   (exactly 24 hours)
observed_at == recorded_at : True
observed_at <= recorded_at < valid_until : True
all instants timezone-aware : True  (-05:00)
```

---

## 6. The exact candidate body

`cadv-000002.json` — the only difference in kind from `CADV-000001`'s body is
the `supersedes` field; everything else is the same binding, restated with a
fresh window and a new request identity.

```json
{
  "request_id": "g11f-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000001",
  "actor": "CHOST-0001",
  "recorded_at": "2026-08-28T09:24:51-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-08-28T09:24:51-05:00",
  "valid_until": "2026-08-29T09:24:51-05:00",
  "supersedes": "CADV-000001",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-28"
  }
}
```

### Why the resource claim is architecture and nothing else

`tools/fabric/resources.py` governs six dimensions — `architecture`,
`accelerator_class`, `accelerator_compute_capability`, `host_memory_mb`,
`host_cpu_cores`, `accelerator_memory_mb`. **`CHOST-0001`'s
`verified_resource_profile` declares exactly one:**

```yaml
verified_resource_profile:
  architecture: x86-64
```

`register_advertisement` requires `satisfies(claim, verified)` — the operator's
verified profile must satisfy the self-report, never the reverse. Claiming CPU,
RAM or an accelerator would be refused as `resource-claim-not-verified`, and
rightly: **a self-report may not enlarge what an operator attested.** No
ungoverned claim was added.

`x86-64` is the governed token — not `uname -m`'s `x86_64`, not `dpkg`'s
`amd64`.

### Candidate digest

```
BODY_SHA256 = ee84563981736b0b065933352412b2445be3b1bf1e6db7395d9cc6ce111cc00c
```

---

## 7. Request digest

Computed by the governed operation over the body, identically in the fixture
rehearsal and against the production store:

```
REQUEST_DIGEST = sha256:4703c974330f820fec70730c00bba3084a5c9fc1051e7567c7db79dc48f80654
```

The agreement between the two is not decoration — it is the check that the body
rehearsed in a fixture and the body preflighted against production are the same
body.

---

## 8. Predicted identity, read-only

```
peek_next_id("capability-advertisement")  ->  CADV-000002
```

Six digits, derived from the store's own sequence and the allocator's rule —
not taken from the brief, which explicitly said not to assume the width.

**Prediction mutated nothing.** Proven in §10 against production and in §9
against the fixture: the advertisement sequence read `1` before and `1` after,
the Fabric tree digest was byte-identical, and `CADV-000002.yaml` did not exist
at any point.

---

## 9. Fixture rehearsal — 22 assertions, all passing

An isolated copy of the production lineage (`CAPDEF-0001`, `CCON-0001`,
`CPKG-0001`, `CHOST-0001`, `CADV-000001`) under a temporary root, exercising the
**real released** `admission.register_advertisement`. Production was never opened
for writing.

All seventeen brief cases, in the actual refusal vocabulary:

```
PASS:  1. CADV-000001 exists in the lineage
PASS:  2. its freshness window has expired
         [valid_until=2026-08-27T14:13:53-05:00 now=2026-08-28T09:26:10-05:00]
PASS:  3. CADV-000002 supersedes the expired CADV-000001      [accepted]
PASS:  3b. the successor names its predecessor
PASS:  3c. evidence declares the supersession category         [supersession]
PASS:  3d. evidence causally references the predecessor
PASS:  4. the expired predecessor is byte-identical after supersession
PASS:  4b. the predecessor acquired no superseded_by field
PASS:  4c. the chain head moved to the successor
PASS:  5. the new advertisement is fresh at its own recorded_at
PASS:  6. the new advertisement receives the predicted identity
         [predicted=CADV-000002 allocated=CADV-000002]
PASS:  7. renewing an already-superseded predecessor refuses
         [refused/renewal-predecessor-not-current]
PASS:  8. a nonexistent predecessor refuses  [not-found/unresolved-reference]
PASS:  9. a self-referential chain refuses as a cycle
         [refused/advertisement-chain-cyclic]
PASS: 10. renewing another host's advertisement refuses
         [refused/renewal-of-another-host]
PASS: 11. a renewal that changes the package refuses
         [refused/renewal-changes-package]
PASS: 12. a renewal that changes the contract refuses as contract-not-of-package
         [refused/contract-not-of-package]
PASS: 13. a malformed window (valid_until <= observed_at) refuses
         [refused/invalid-validity-window]
PASS: 14. an already-closed window refuses     [refused/invalid-validity-window]
PASS: 15. a window that opens after recorded_at refuses
         [refused/invalid-validity-window]
PASS: 16. an identical replay is deterministic and allocates nothing new
         [exact-replay -> CADV-000002]
PASS: 17. the same request_id with a changed body conflicts
         [conflict/request_identity_conflict]
```

**Case 4 is the one that matters most.** The expired predecessor is
byte-identical after being superseded — supersession is a forward statement by
the successor, and the immutable record it names is never touched.

**Case 12 confirms the source's own reasoning** rather than a reason invented for
it: changing the contract never reaches a renewal rule, because a package names
one contract and the body's contract had to be that one.

**Case 9 was constructed, not argued.** A self-loop was written into a fixture
store's `CADV-000001` and the governed traversal refused it as a cycle — the
mechanism the source says covers this, exercised rather than cited.

### Negative-control lineage

Cases 10–12 need a second host, package and contract, which the production
lineage does not have. Fixture-only alternates (`CHOST-0002`, `CPKG-0002`,
`CCON-0002`) were derived from the real records so the mismatch branches are
genuinely reachable. **They exist only inside temporary fixture roots and were
never written to production.**

### 9.1 The one correction — to the harness, not the source

My first run reported case 17 as a failure:

```
FAIL: 17. the same request_id with a changed body conflicts
      [conflict/request_identity_conflict]
```

The outcome and reason were **correct**; my assertion expected
`request-identity-conflict` with hyphens where the released vocabulary uses
underscores. I corrected the expectation. **No governed behaviour was changed,
and no source file was touched** — which is exactly the discipline the brief
required: a discrepancy is investigated before it is treated as a defect.

---

## 10. Genuine read-only production preflight

The brief permits this only if safe under released architecture. **It is**, and
without weakening approved-directory containment.

`--approved-directory` is an operator-named parameter; `_decision_body()`
resolves the input file fully and refuses anything that lands outside *whatever
directory was named* — a traversing name, an absolute path, or a symlink
pointing out. Containment is enforced **against the named directory**, so
pointing it at an isolated preparation directory does not weaken it; it applies
the same rule to a different, tighter root. `/etc/kyri/fabric` is the production
convention for **published** operator input, not a precondition of the reader.

`register-advertisement` needs no trust store, and the preflight opens the
production store through `FabricStore.open_for_read`.

```bash
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000002.json \
  --approved-directory <isolated preparation directory>
```

```json
{
  "destination": "/var/lib/kyri/fabric/capability-advertisements/CADV-000002.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "register-advertisement",
  "outcome": "preflight",
  "predicted_record_id": "CADV-000002",
  "record_kind": "capability-advertisement",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:4703c974330f820fec70730c00bba3084a5c9fc1051e7567c7db79dc48f80654",
  "request_id": "g11f-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000001",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

**exit 0.** `would_accept: true`, `mutated: false`,
`predicted_record_id: CADV-000002` — exactly the conceptual result the brief
expected, obtained from the real store rather than asserted.

This is the G11-C rehearsal architecture doing its job: the real operation ran
against the real production store under `admission.rehearsing()`, so every field
check, vocabulary check and reference resolution executed — including R1–R4
against the real `CADV-000001` — and stopped at the first irreversible act.

### Production before / after the preflight

| | Before | After | |
|---|---|---|---|
| Fabric full-tree digest | `7780dacf…ab072` | `7780dacf…ab072` | **BYTE-IDENTICAL** |
| Advertisement sequence | `1` | `1` | **UNADVANCED** |
| Every path's size/mtime/mode | — | — | **IDENTICAL** |
| `CADV-000002.yaml` | absent | **absent** | not created |

The metadata comparison is deliberate: a digest of file contents alone would not
notice a sequence file rewritten to the same value, or a lock left behind.

**Nothing was published to `/etc/kyri/fabric`. `cadv-000002.json` is not there.**

---

## 11. Operator freeze — the exact command

Publishes **only** the reviewed operator input. It does **not** run
`register-advertisement`: publishing the input and spending a CADV identity are
separate acts, and this block performs the first only.

### Destination metadata, verified rather than assumed

```
/etc/kyri/fabric              root:cschott  0750
/etc/kyri/fabric/cadv-000001.json  root:cschott  0640
/etc/kyri/fabric/capdef-0001.json  root:cschott  0640   (and every sibling)
```

So the destination metadata is **`root:cschott 0640`**, matching every existing
operator input.

### The block

Self-contained: it reconstructs the reviewed bytes inline, verifies the reviewed
digest **before** installing, refuses if the destination already exists, and does
not depend on `/tmp` surviving reviewer handoff.

```bash
set -Eeuo pipefail

DEST=/etc/kyri/fabric/cadv-000002.json
EXPECTED=ee84563981736b0b065933352412b2445be3b1bf1e6db7395d9cc6ce111cc00c

[[ -e "${DEST}" ]] && { printf 'REFUSING: %s already exists\n' "${DEST}" >&2; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11f-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000001",
  "actor": "CHOST-0001",
  "recorded_at": "2026-08-28T09:24:51-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-08-28T09:24:51-05:00",
  "valid_until": "2026-08-29T09:24:51-05:00",
  "supersedes": "CADV-000001",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-28"
  }
}
BODY

OBSERVED="$(sha256sum "${TMP}" | cut -d' ' -f1)"
[[ "${OBSERVED}" == "${EXPECTED}" ]] || {
  printf 'REFUSING: reconstructed digest %s != reviewed %s\n' "${OBSERVED}" "${EXPECTED}" >&2
  rm -f "${TMP}"; exit 1; }

sudo install -o root -g cschott -m 0640 "${TMP}" "${DEST}"
rm -f "${TMP}"

sudo sha256sum "${DEST}"
sudo stat -c '%n %U:%G %a' "${DEST}"
```

**Validated in a sandbox before being written here** — with `DEST` redirected to
a scratch path, the block reconstructed the bytes to
`ee84563981736b0b065933352412b2445be3b1bf1e6db7395d9cc6ce111cc00c`,
**byte-identical to the candidate** (`cmp` clean), installed at mode `0640`, and
refused on a second run because the destination existed. The `/etc/kyri/fabric`
destination was never written.

### After freezing — the production preflight from the published input

Read-only, and the last check before any write:

```bash
cd /opt/schott-platform
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000002.json \
  --approved-directory /etc/kyri/fabric
```

Expect `would_accept: true`, `mutated: false`,
`predicted_record_id: CADV-000002`, and request digest
`sha256:4703c974…f80654`. **A different request digest means the frozen bytes
are not the reviewed bytes — stop.**

### The write — step D, NOT authorised by this checkpoint

```bash
# NOT RUN. Requires reviewer approval and operator authorisation.
python3 -m tools.fabric.cli register-advertisement \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000002.json \
  --approved-directory /etc/kyri/fabric
```

---

## 12. Expiration and the remaining review window

```
recorded_at   2026-08-28T09:24:51-05:00
valid_until   2026-08-29T09:24:51-05:00
report time   2026-08-28T09:27:24-05:00
remaining     ~23h 57m from report time
```

**If the window will close before steps B–D complete, regenerate — do not
weaken freshness.** Regeneration is mechanical: take a fresh `T`, set
`observed_at = recorded_at = T` and `valid_until = T + 24h`, update
`provenance.recorded_at` to `T`'s date, and leave every other field byte-identical.
That changes `BODY_SHA256` and `REQUEST_DIGEST`, so §11's `EXPECTED` and the
expected preflight digest must be updated with it, and the fixture rehearsal and
production preflight re-run. The `request_id` may be reused **only** if no write
was ever submitted under it; if one was, a changed body under the same
`request_id` is `request_identity_conflict` by design (§9, case 17).

---

## 13. Production non-mutation proof

| Authority | Before | After | Result |
|---|---|---|---|
| Fabric | `7780dacf…ab072` | `7780dacf274f57e000a0ab93208e7b89a6b1933ed2c181cec5f79a49119ab072` | **BYTE-IDENTICAL** |
| Trust | `cffd362c…fbbc39` | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` | **BYTE-IDENTICAL** |
| Artifact | `30732e2c…6257f` | `30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f` | **BYTE-IDENTICAL** |
| Platform Evidence | `227abde8…20984b` | `227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b` | **BYTE-IDENTICAL** |
| Installed runtime | `80f9dee2…07f5b` | `80f9dee23a3e7934ee779c90284d152c1f13508ed1bcecc100fa7de5b0107f5b` | **BYTE-IDENTICAL** |

`diff` of the before and after captures: **identical**.

```
CADV count            : 1
CADV sequence         : 1
CADV-000002 present   : NO
CINST count           : 0
CROUTE count          : 0
CSEL count            : 0
installed runtime .py : 57
/etc/kyri/fabric      : cadv-000001.json capdef-0001.json ccon-0001.json
                        chost-0001.json cpkg-0001.json
cadv-000002.json      : absent (not frozen)
Root Authority        : unmounted
```

Every Phase 8 assertion holds. `CADV-000001` was not overwritten; it is
byte-identical and remains the chain head.

---

## 14. Source changes

**NONE**, as expected. This checkpoint exercised already-accepted G11-A3
behaviour and found it correct on every one of the seventeen cases. The single
correction was to my test harness's expected string (§9.1).

No governed behaviour was modified, and no convenience change was made to the
ceremony path.

---

## 15. Actions explicitly NOT performed

- **`CADV-000002` not created in production.** No identity spent; sequence still 1.
- **`cadv-000002.json` not published to `/etc/kyri/fabric`.** The freeze is the
  operator's act, after reviewer approval.
- **`CADV-000001` not overwritten, not modified, not superseded in production.**
- **No CINST, no CROUTE, no CSEL.**
- **No CINST admission attempted against the expired `CADV-000001`**, as the
  brief forbids.
- **Generation 11 not reinstalled**; installed runtime byte-identical.
- **Trust, Artifact and Platform Evidence not mutated.**
- **Root Authority not mounted.**
- **Approved-directory containment not weakened** (§10) — the same rule was
  applied to a tighter, isolated root.
- **No privileged operation.** Every command ran as uid 1000; the only `sudo`
  in this report is inside the operator block, which was **not run**.
- **No source file changed.**
- **No ungoverned resource dimension claimed** (§6).
- **No secrets recorded.**

---

## 16. Unresolved findings

1. **The Artifact authority digest discrepancy** carried from G11-D §18 and
   G11-E §18. `30732e2c…` is stable and unchanged across three checkpoints; the
   `63db66fd…` recorded in G11-A/B/C reproduces under no method that reproduces
   the other three. The bytes have not moved. Still awaiting a reviewer ruling on
   whether the earlier records need correcting.
2. **Two installed execution helper modules lag the repository source**
   (G11-E §10.1) — a matrix decision for whichever generation next corrects the
   transition path. Unrelated to this checkpoint.

No new finding was discovered in G11-F.

---

## 17. Recommended next checkpoint

**Reviewer approval of this candidate (step B), then operator freeze (step C).**

In order:

1. **Reviewer approves** the body in §6, its digest, and the semantics in §4 —
   in particular the ruling that an expired advertisement is a lawful predecessor.
2. **Operator freezes** the input with the block in §11 → `root:cschott 0640`.
3. **Production preflight from `/etc/kyri/fabric`** (§11) — confirm
   `would_accept: true` and request digest `sha256:4703c974…f80654`.
4. **Step D: the governed write** — `register-advertisement` without
   `--preflight`, spending `CADV-000002`. Independently authorised.
5. Then **`CINST-000001`** against the fresh `CADV-000002`, rehearsed first.

**Watch the clock at step 4.** If `2026-08-29T09:24:51-05:00` passes first,
regenerate per §12 rather than registering a body that no evaluation could ever
find fresh — `register_advertisement` will refuse it as
`invalid-validity-window`, which is correct behaviour and a wasted round trip.

---

## Appendix A — commands executed

All read-only against production. Writes went to fixture roots and the
scratchpad only. **No `sudo` at any point.**

```bash
# Phase 0
git rev-parse HEAD ; git status --porcelain
git merge-base --is-ancestor <each G11-A..E commit> HEAD
find /usr/lib/kyri/python -type f -name '*.py' | wc -l          # 57
cd / && unset PYTHONPATH && python3 -E -c "<installed-only closure proof>"
( cd <authority root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )
cat /var/lib/kyri/fabric/sequences/capability-advertisement.seq  # 1

# Phase 1 — renewal semantics, from source
sed -n '1316,1470p' tools/fabric/admission.py            # register_advertisement
grep -n "REASON_ADVERT_STALE" tools/fabric/*.py          # consumption paths only
sed -n '278,305p' tools/fabric/evidence.py               # supersession pairing
sed -n '<_successors>,<_head_of>' tools/fabric/admission.py
sed -n '45,80p' tools/fabric/resources.py                # governed dimensions

# Phases 2/3 — the candidate
python3 - <<'PY' ... PY                                   # body from a single clock read
sha256sum <candidate>                                     # ee845639…cc00c

# Phase 5 — fixture rehearsal, real released operation
python3 <rehearse-g11f.py> <candidate>                    # 22 assertions

# Phase 6 — genuine read-only production preflight
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000002.json --approved-directory <isolated dir>
<fabric tree digest + per-path size/mtime/mode, before and after>

# Phase 7 — freeze block validated in a sandbox, DEST redirected
<heredoc reconstruction; sha256sum; cmp against candidate; re-run refusal>

# Phase 8
<authority digests re-taken and diffed against the Phase-0 capture>
```

## Appendix B — the renewal, stated once

```
register-advertisement, supersedes = CADV-000001
        │
        ├── structure        approving_authority absent; instants aware
        │                    valid_until > observed_at
        │                    observed_at <= recorded_at < valid_until
        │                    supersedes syntactically a CADV identifier
        │
        ├── request identity digest over the governed body
        │                    replay -> exact-replay | conflict
        │
        ├── first-advertisement rules, ALL of them
        │      actor == capability_host_id        actor-is-not-the-subject
        │      host chain head is this host       host-record-superseded
        │      package names this contract        contract-not-of-package
        │      versions declared by the package   versions-not-declared
        │      verified profile satisfies claim   resource-claim-not-verified
        │
        ├── renewal rules, and ONLY these three more
        │      R1 predecessor resolves            unresolved-reference
        │      R2 same host                       renewal-of-another-host
        │      R3 same package                    renewal-changes-package
        │      R4 predecessor is the chain head   renewal-predecessor-not-current
        │
        │      NOT a rule: the predecessor's freshness.
        │      advertisement-not-fresh lives in admit_instance and C5
        │      eligibility -- the CONSUMPTION paths -- and nowhere here.
        │      An expired claim cannot be consumed. It can be superseded.
        │
        └── commit           identity minted AFTER every check
                             evidence reason_category = "supersession"
                             causal_references += CADV-000001
                             CADV-000001 read, never written; no superseded_by

Forward-stated by the successor. Read backwards by traversal.
The predecessor is immutable, expired, and still lawful lineage.
```
