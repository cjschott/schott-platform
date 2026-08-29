# ENG-0005 G11-U — CSEL-000001 First Governed Selection Preparation, Rehearsal, and Frozen Operator Input

- Checkpoint: ENG-0005 G11-U
- Date: 2026-08-28 (local date at report creation; midnight was not crossed)
- Branch: `arch/eng-0005-execution-transition`
- Starting authority: `e2dbebba340da4ede34912975b9c96daf08a1a43`
- Host: `schai`
- Result: `OPERATOR_ACTION_REQUIRED` (freeze requires root; no production selection performed)

## 1. Starting authority

| Check | Observed |
|---|---|
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `e2dbebba340da4ede34912975b9c96daf08a1a43` — matched |
| Origin contains HEAD | yes |
| Worktree | clean; nothing staged, nothing untracked |
| G11-T report present | yes |
| Fabric inspection | `reported`, zero defects |
| Trust store | `valid: True`, zero problems |
| Generation 11 runtime | 57 `.py` files, unchanged |
| Root Authority | unmounted |

Both manifests captured before any work: structural 28 entries, content 19 files.

## 2. Production inventory

| Kind | Count |
|---|---|
| CAPDEF / CCON / CPKG / CHOST | 1 / 1 / 1 / 1 |
| CADV | 3 |
| CINST | 2 |
| CROUTE | **2** |
| CSEL | **0** |

| Sequence | Value |
|---|---|
| `capability-advertisement.seq` | 3 |
| `capability-instance.seq` | 2 |
| `capability-route.seq` | 2 |
| `capability-selection.seq` | **ABSENT** |

`CSEL-000001` destination absent. `/etc/kyri/fabric/csel-000001.json` absent.
Unique route head `CROUTE-0002`, candidate list `[CINST-000002]`.

## 3. ⚠ Selection persists refusals — why the mutating path is not a preflight

This is the semantic that makes selection unlike every prior write ceremony, and it
is confirmed directly in `tools/fabric/selection.py::_decide`, which calls `_write`
on **all three** outcome paths:

```python
if route is None:
    # No route to name, and none is invented. The decision is still
    # written: silence is not an outcome.
    return _write(store, OUTCOME_NO_CANDIDATE, ...), None
...
outcome = OUTCOME_SELECTED if selected is not None else OUTCOME_REFUSED
return _write(store, outcome, ...), selected
```

```python
OUTCOME_CATEGORIES = {
    OUTCOME_SELECTED:     "selection",
    OUTCOME_REFUSED:      "selection-refusal",
    OUTCOME_NO_CANDIDATE: "no-candidate",
}
```

A governed refusal therefore **allocates and writes a `CSEL`**. Running the mutating
`select` against production to discover whether it would succeed would spend
`CSEL-000001` on the question. That is why the only production mechanism used in
this checkpoint is the released non-allocating rehearsal path, and why the future
authorised write will intentionally spend `CSEL-000001` **whichever way the decision
goes**.

This is proved empirically, not merely read, in section 18.

## 4. Selection contract reconstruction

Read from `tools/fabric/selection.py`, `tools/fabric/models.py::CapabilitySelection`,
`tools/fabric/cli.py::command_select`, `tools/fabric/eligibility.py`, and
`tools/fabric/identifiers.py`.

| Aspect | Source finding |
|---|---|
| CLI operation name | `select` (`cli.py:429`) |
| Governed operation identity | `OPERATION = "select-candidate"` (`selection.py:54`) |
| Body → call | `select_candidate(store, trust_store, **body)`; a mismatched key raises `TypeError` → `"the decision body does not match this operation"` |
| **Required** body fields | `request_id`, `actor`, `recorded_at`, `evaluated_at`, `capability_id`, `contract_id`, `accepted_contract_versions`, `data_classification`, `locality`, `provenance` |
| **Optional** body fields | `local_node_identity` (default `None`), `health_removals` (default `()`), `notes` (default `None`) |
| **`approving_authority`** | **Does not exist.** `_write` passes `approving_authority=None` explicitly to `assemble_evidence` |
| **`operation`** (e.g. `execute`) | **Does not exist.** See section 4.1 |
| Request class | `capability_id`, `contract_id`, `accepted_contract_versions`, `data_classification`, `locality` |
| Instants | `recorded_at` (persisted as `selected_at`) and `evaluated_at` (what eligibility judges) — both required, both must be timezone-aware |
| Locality input | `locality` ∈ `LOCALITIES`; `local_node_identity` is a separate authoritative input |
| Provenance | required mapping |
| Request digest | over `actor`, `recorded_at`, `evaluated_at`, `capability_id`, `contract_id`, `accepted_contract_versions`, `data_classification`, `locality`, `local_node_identity`, `health_removals`, `provenance`, `notes` |
| Identity width | `^CSEL-[0-9]{6}$` — **six digits**, unlike `^CROUTE-[0-9]{4}$` |
| Allocation boundary | `_commit` constructs against probe identity `CSEL-000000`, then `if is_rehearsing(): return None` **before** `store.allocate_id` |
| Persisted on success | `selection_id`, `route_id`, `route_version`, `request_class`, `considered_candidates`, `excluded_candidates`, `selected_instance_id`, `selection_reason`, `selected_at`, `provenance`, `local_node_identity`, `evidence` |
| Persisted on refusal | same shape with `selected_instance_id` absent and `refusal_reason` present |
| Evidence | `actor`, no `approving_authority`, `reason_category` from `OUTCOME_CATEGORIES`, `request_id`, `request_digest`, `causal_references` = route id followed by considered candidates, `trust_evidence_references = ()` |
| Replay | `replay_lookup` in a critical section on the mutating path only; a rehearsal deliberately does not classify replay |

### 4.1 Two fields the brief expects that the contract does not have

**`operation`.** The brief's expected request includes `operation = execute`. The
released selection contract has no such field, and `eligibility._request` refuses a
request whose key set is not exactly `REQUEST_FIELDS`:

```python
if not isinstance(value, Mapping) or set(value) != set(REQUEST_FIELDS):
    return None
```

Including `operation` in the decision body would raise `TypeError` in
`select_candidate` and be reported as `"the decision body does not match this
operation"`. **The body therefore carries no `operation` field.** The operation is
not part of the governed request class; a selection chooses a binding for a request
class, and `execute` appears only inside the instance's own
`effective_scope.permitted_operations`.

**`approving_authority`.** Every prior ceremony body carried one. Selection does not
accept it, and `_write` hard-codes `approving_authority=None`. The body omits it.

### 4.2 What ELIG-8 actually enforces — reported, not glossed

The brief asks to verify "scope execute/internal/HOST-0001". Those three facts are
true of `CINST-000002` and are shown in section 7. But the eligibility engine does
**not** check all three. `_scope_permits` (ELIG-8) validates that all four scope
dimensions are well-formed, then tests membership on exactly one:

```python
for dimension in SCOPE_DIMENSIONS:
    if _members(scope.get(dimension)) is None:
        return ConditionResult("", UNMET, REASON_EMPTY_SCOPE)
if asked["data_classification"] not in scope[SCOPE_CLASSIFICATIONS]:
    return ConditionResult("", UNMET, REASON_SCOPE_REFUSES)
```

Grepping the whole of `eligibility.py`, `permitted_capabilities`,
`permitted_operations`, and `permitted_targets` appear **only** in the
`SCOPE_DIMENSIONS` tuple. No ELIG condition tests membership on any of them.

Where those dimensions *are* enforced:

- **capability / target scope membership** — at admission time. `admit_instance`
  checked the Trust scope against `CAPDEF-0001` and node identity `HOST-0001`
  (the G11-A2 rule, re-verified in G11-R). Instances are immutable, so the check is
  not repeated at selection time.
- **node identity** — by selection, not eligibility: `_locality_permits` requires
  exact equality `host["node_identity_reference"] == local_node_identity` for
  `local-only`, surfaced as the `route-locality` condition.
- **operation** — nowhere, because no operation is ever asked.

I am reporting this rather than claiming ELIG-8 verified all three dimensions. It is
**not** treated as a blocking defect: the scope was validated where the decision was
made, the records are immutable, and re-deriving a settled fact is not what this
plane does. It is recorded so a future reviewer does not assume selection re-checks
capability or target membership. The one genuinely absent concept — a governed
*operation* in the request class — is a design question for a dedicated checkpoint,
not a defect in this ceremony.

## 5. Identity derivation

```
peek_next_id('capability-selection')  = CSEL-000001
six digits (CSEL width)               = True
destination /var/lib/kyri/fabric/capability-selections/CSEL-000001.yaml : absent
capability-selection.seq              : still ABSENT after prediction
```

`peek_next_id` predicts `CSEL-000001` from an absent sequence without creating it.
Four-digit route width was not used.

## 6. Route-head and read-only route-resolution proof

Performed independently of the rehearsal, because G11-T established that the
rehearsal path intentionally returns incomplete route metadata.

```
_chain_heads(store,'capability-route')      = ['CROUTE-0002']
_resolve_route(request class)               -> CROUTE-0002   route_version = 2
candidate_instances                         = ['CINST-000002']
CINST-000001 is NOT a candidate             = True
exactly one match, no ambiguity             = True
```

`_resolve_route` refuses with `route-ambiguous-for-request-class` if more than one
current route matched; it returned a single route, so no ambiguity exists. The
request class matched on all five dimensions — no mismatch.

Supporting authority:

```
CHOST-0001.node_identity_reference = HOST-0001   <- the local_node_identity input
CHOST-0001 is the current host head = True
host.location_class / data_classification = on-premises / internal
host.availability_intent = in-service
CCON-0001.effect_class = computational  (routable: read-only, computational, content-generating)
```

`HOST-0001` (node identity) and `CHOST-0001` (Fabric host record) are kept distinct
throughout; `local_node_identity` carries the former.

## 7. Full eligibility proof

`evaluate_eligibility` run against `CINST-000002` at the governed instant
`2026-08-28T20:47:35-05:00`:

```
eligible = True   unmet = none   reasons = none
ELIG-1 met   ELIG-2 met   ELIG-3 met   ELIG-4  met
ELIG-5 met   ELIG-6 met   ELIG-7 met   ELIG-8  met
ELIG-9 met   ELIG-10 met  ELIG-11 met  ELIG-12 met
conditions met: 12/12
```

| Condition | What it tested | Observed authority |
|---|---|---|
| ELIG-1 | package Trust standing | `TREC-000002`, `CPKG-0001`, trusted |
| ELIG-2 | host Trust standing | `TREC-000001`, `HOST-0001`, trusted |
| ELIG-3 | contract offers this capability/version | `CCON-0001`, `1.0.0` |
| ELIG-4 | package satisfies the version | `CPKG-0001`, `1.0.0` |
| ELIG-5 | resource predicates host vs package | satisfied |
| ELIG-6 | advertisement current and fresh | `CADV-000003`, valid_until `2026-08-30T16:19:19-05:00` |
| ELIG-7 | admission window open | `2026-08-28T19:29:09` .. `2026-08-30T16:19:19-05:00` |
| ELIG-8 | scope permits the classification | `internal` ∈ `['internal']` (see §4.2) |
| ELIG-9 | host handles that classification | host `internal` |
| ELIG-10 | host not quarantined | not quarantined |
| ELIG-11 | package not quarantined | not quarantined |
| ELIG-12 | host in service | `in-service` |
| lifecycle | authoritative, decided not derived | `admitted` |

Directly observed on the record, independent of which condition tests them:

```
effective_scope: caps=['CAPDEF-0001'] ops=['execute'] cls=['internal'] tgt=['HOST-0001']
```

Zero unmet conditions. No request field was altered to make anything pass.

## 8. The governed selection instant

```
recorded_at  = 2026-08-28T20:47:35-05:00
evaluated_at = 2026-08-28T20:47:35-05:00
```

One fresh ceremony instant, used for both, which is the shape the source permits:
`recorded_at` is persisted as `selected_at`, and `evaluated_at` is what eligibility
judges. No earlier instant was inherited.

**Remaining useful lifetime** from the governed instant to
`2026-08-30T16:19:19-05:00` (both `CADV-000003.valid_until` and
`CINST-000002.admitted_until`, bound together by the G11-Q ruling):

```
1 day, 19:31:44
```

The R17 tail is zero, so freshness and admission expire together.

## 9. The exact decision body, field by field

```json
{
  "request_id": "g11u-select-capdef-0001-ccon-0001-internal-local-only-host-0001",
  "actor": "primary-platform-operator",
  "recorded_at": "2026-08-28T20:47:35-05:00",
  "evaluated_at": "2026-08-28T20:47:35-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": [
    "1.0.0"
  ],
  "data_classification": "internal",
  "locality": "local-only",
  "local_node_identity": "HOST-0001",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-28"
  }
}
```

| Field | Authority |
|---|---|
| `request_id` | naming convention carried from G11-L/S, describing this G11-U selection |
| `actor` | established operator identity across every prior ceremony |
| `recorded_at` | fresh ceremony instant; persisted as `selected_at` |
| `evaluated_at` | same instant; what eligibility judges (§8) |
| `capability_id` | request class; matches `CROUTE-0002` |
| `contract_id` | request class; matches `CROUTE-0002` |
| `accepted_contract_versions` | request class; exact set match in `_resolve_route` |
| `data_classification` | request class; the one dimension ELIG-8 enforces |
| `locality` | request class; `local-only` demands exact node identity |
| `local_node_identity` | `HOST-0001` from `CHOST-0001.node_identity_reference` |
| `provenance` | current accepted convention |

**Deliberately absent**, per section 4:

| Omitted | Reason |
|---|---|
| `approving_authority` | not a parameter; `_write` hard-codes `None` |
| `operation` | not a parameter; would raise `TypeError` |
| `route_id`, `route_version` | derived decision output, not operator input |
| `selected_instance_id`, `considered_candidates`, `excluded_candidates` | derived output |
| `outcome`, `refusal_reason` | derived output |
| `health_removals`, `notes` | optional; nothing requires them |

Source is authoritative and none of the derived fields is an operator input — the
brief's caution holds exactly.

## 10. Body bytes

| Property | Value |
|---|---|
| SHA-256 | `4dbe005137e16c13156318176280f90bf4216a6195d4756efaf3a8d2da3a5a7e` |
| Size | 591 bytes |
| JSON validity | parses |
| Encoding | JSON text data, ASCII |
| Line endings | LF only (zero CR bytes) |
| Indentation | two spaces, matching every prior frozen input |
| Trailing newline | present |
| `operation` / `approving_authority` keys | zero occurrences |

A byte-identical copy is retained in the session scratchpad for `cmp`.

## 11. Production rehearsal

Run through `select --preflight` — the released non-allocating path. The mutating
path was **not** run against production.

```json
{
  "destination": "/var/lib/kyri/fabric/capability-selections/CSEL-000001.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "select",
  "outcome": "preflight",
  "predicted_record_id": "CSEL-000001",
  "record_kind": "capability-selection",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:507b29dbfb5e57be436b4fa3192959b0db7ea0ebddf371c85625c9c2d33c5c21",
  "request_id": "g11u-select-capdef-0001-ccon-0001-internal-local-only-host-0001",
  "selected_instance_id": "CINST-000002",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

| Requirement | Observed |
|---|---|
| outcome | `preflight` |
| selected decision | **`CINST-000002`** |
| refusal reason | `null` |
| no CSEL record | CSEL count 0 |
| no allocation | `capability-selection.seq` still ABSENT |
| destination absent | yes |
| structural manifest | IDENTICAL |
| content manifest | IDENTICAL |

## 12. Production rehearsal request digest

```
sha256:507b29dbfb5e57be436b4fa3192959b0db7ea0ebddf371c85625c9c2d33c5c21
```

## 13. Why the rehearsal's returned metadata is intentionally incomplete

The `select --preflight` output carries `selected_instance_id` but no `route_id`,
`route_version`, `considered_candidates`, or `excluded_candidates`. That is by
design, and `_commit`'s docstring states the reason:

> Under a rehearsal it stops at that proof and returns no identity. Allocation is
> the first act that cannot be taken back… what a rehearsal has left to learn from
> allocating is nothing, and what it would cost is a spent sequence position.

There is no persisted record to read those fields back from. `select_candidate`'s
rehearsal branch adds:

> Route resolution, candidate judgement and every exclusion still run against the
> real store, so what this reports is what the write would decide.

**Empty rehearsal metadata is not negative evidence.** Route resolution was proved
independently in section 6 (`_resolve_route` → `CROUTE-0002`, candidates
`['CINST-000002']`), eligibility independently in section 7 (12/12), and the full
persisted shape independently in sections 15–17.

## 14. Faithful fixture construction

The fixture reproduces the production **sequence**, with production-accurate
absolute instants so that its windows genuinely contain the governed selection
instant and the request digest is comparable:

```
base authority (root, two Trust grants, CAPDEF, CCON, CPKG, CHOST)
CADV-000001   observed 2026-08-26T14:13:53-05:00  valid_until 2026-08-27T14:13:53-05:00
CADV-000002   observed 2026-08-28T09:24:51-05:00  valid_until 2026-08-29T09:24:51-05:00   supersedes 1
CINST-000001  admitted 2026-08-28T13:46:27-05:00  until 2026-08-29T13:46:27-05:00  against CADV-000002
CROUTE-0001   recorded 2026-08-28T15:07:19-05:00  candidates [CINST-000001]  version 1
CADV-000003   observed 2026-08-28T16:19:19-05:00  valid_until 2026-08-30T16:19:19-05:00   supersedes 2
CINST-000002  admitted 2026-08-28T19:29:09-05:00  until 2026-08-30T16:19:19-05:00  against CADV-000003, supersedes CINST-000001
CROUTE-0002   recorded 2026-08-28T20:11:43-05:00  candidates [CINST-000002]  version 2, supersedes CROUTE-0001
```

Order matters, not just the terminal graph: building the advertisements up front
would trip R16 (`advertisement-record-superseded`), as G11-Q proved.

```
PASS: the fixture reproduces the production sequence through CROUTE-0002
PASS: CINST-000001 was admitted against CADV-000002 while it was current
PASS: CROUTE-0001 named CINST-000001 at the time it was written
PASS: CROUTE-0002 supersedes CROUTE-0001 and names CINST-000002
PASS: the unique route head is CROUTE-0002
PASS: capability-selection.seq is absent, as in production
PASS: the fixture predicts CSEL-000001
```

## 15. Independent fixture selection write

The exact body, run through the **mutating** selection path in an isolated fixture:

```
PASS: the identical body is accepted                              [accepted/None]
PASS: the allocated identity is CSEL-000001
PASS: the fixture digest equals the production rehearsal digest
      sha256:507b29dbfb5e57be436b4fa3192959b0db7ea0ebddf371c85625c9c2d33c5c21
PASS: selected_instance_id is CINST-000002
PASS: route_id is CROUTE-0002
PASS: route_version is 2
PASS: refusal_reason is absent on a successful selection
PASS: considered_candidates == ['CINST-000002']
PASS: excluded_candidates is empty
PASS: selection_reason names the declared-order rule
PASS: evidence.reason_category is 'selection'
PASS: no approving_authority was recorded
PASS: local_node_identity persisted as HOST-0001
PASS: the selection sequence FILE WAS CREATED
PASS: the selection sequence contains 1                           ['1\n']
PASS: exactly one CSEL record exists
```

Rehearsal and independent fixture write agree on every comparable value, including
the digest. No disagreement, so no stop.

## 16. Successful persisted CSEL shape

```
selection_id          CSEL-000001
route_id              CROUTE-0002
route_version         2
request_class         {"accepted_contract_versions": ["1.0.0"],
                       "capability_id": "CAPDEF-0001",
                       "contract_id": "CCON-0001",
                       "data_classification": "internal",
                       "locality": "local-only"}
considered_candidates ['CINST-000002']
excluded_candidates   []
selected_instance_id  CINST-000002
selection_reason      "first eligible candidate in declared order"
selected_at           2026-08-28T20:47:35-05:00
local_node_identity   HOST-0001
refusal_reason        absent
evidence.actor              primary-platform-operator
evidence.approving_authority  absent
evidence.reason_category      selection
evidence.causal_references    ['CROUTE-0002', 'CINST-000002']
evidence.trust_evidence_references  []
```

Note the request class persists `locality`, which `eligibility._request` does not
accept — the selection record keeps the fuller five-field class, while eligibility
is asked the four-field one.

## 17. Fixture CSEL SHA-256

```
e08a4df4ab758cb0d25609e3cc02b4adca7568ff464b312ac3a2c88b8bbe79bb
```

Fixture record only. It will not equal the eventual production record — the
`selection_id` is the same but the fixture's other records differ in provenance
detail — and it is recorded as evidence of shape, not as a value to compare against
production.

## 18. Refusal-persistence control

A **separate disposable fixture**, never the successful one. The cleanest refusal
the released semantics offer: the identical governed request evaluated after the
candidate's windows have closed. **Nothing was modified — only the instant moved**
(`2026-08-31T09:00:00-05:00`), so the control tests the contract rather than a
damaged fixture.

```
PASS: the control fixture starts with no selections and no sequence file
PASS: a governed refusal still returns an ACCEPTED write outcome   [accepted/None]
PASS: a CSEL identity was SPENT on the refusal                     [CSEL-000001]
PASS: the refusal PERSISTED a capability-selection record
PASS: no instance was selected
PASS: refusal_reason is recorded                                   [no-eligible-candidate]
PASS: evidence.reason_category is 'selection-refusal'
PASS: the route and its candidate are still recorded on the refusal
PASS: the excluded candidate names why
PASS: the refusal ALSO created the sequence file at 1              ['1\n']
```

The refused record's detail:

```
excluded_candidates: [{"instance_id": "CINST-000002",
                       "reasons": ["advertisement-not-fresh",
                                   "admission-window-expired"]}]
selection_reason:    'no candidate in declared order was eligible'
```

Both reasons are reported, not just the first — `_exclusions` collects every reason
so an operator clearing one finds the next.

**This is the empirical proof of section 3**: a refusal costs `CSEL-000001` exactly
as a success does. Production cannot use the mutating path as a preflight.

## 19. Both outcomes allocate a selection decision

| Outcome | Record written | Identity spent | Sequence after |
|---|---|---|---|
| `selected` | yes | `CSEL-000001` | `1\n` |
| `refused` (`no-eligible-candidate`) | yes | `CSEL-000001` | `1\n` |
| `no-candidate` (no route resolves) | yes, per `_decide` | would be `CSEL-000001` | `1\n` |

The third row is read from source rather than executed; production has a resolvable
route, so constructing a no-route case would have tested a world we are not in.

**Both successful and refused first selection consume sequence 1.**

## 20. First-selection mutation model for the future write

Because `capability-selection.seq` is currently **absent**, the first production
selection differs from the last three writes. It will create **two** new files:

```
ADD  capability-selections/CSEL-000001.yaml
ADD  sequences/capability-selection.seq        containing "1\n"
```

Not one addition plus an in-place replacement. Both appear in the **structural**
manifest as additions, so — unlike G11-P, G11-R, and G11-T — the sequence change is
visible structurally. The content manifest will show two additions and zero
replacements. Confirmed in both fixtures: the sequence file was created, not
replaced, on the successful path and on the refusal path alike.

The G11-V verifier should expect two additions, zero removals, zero modifications,
and should not look for a sequence replacement that will not be there.

## 21. Production no-mutation proof

Both manifests re-captured after every action in this checkpoint and diffed against
the pre-work capture:

```
structural: IDENTICAL
content:    IDENTICAL
CSEL count = 0
capability-selection.seq = ABSENT
fabric inspection: reported, zero defects
```

No mutating selection was executed against production at any point.

## 22. Frozen input evidence

**Not completed — the freeze requires root.** The write probe failed closed:

```
cp: cannot create regular file '/etc/kyri/fabric/csel-000001.json': Permission denied
/etc/kyri/fabric/csel-000001.json: ABSENT
```

Approved-input authority re-derived from all eleven existing frozen inputs rather
than assumed:

```
dir  /etc/kyri/fabric   root:cschott 0750
distinct owner:group across inputs : root:cschott
distinct modes across inputs       : 640
```

Uniform, so `root:cschott 0640` is precedent, not guesswork.

The operator block below was sandbox-validated end to end: it verified the source
digest, installed at mode `0640`, re-verified hash, size 591, JSON validity, and
`cmp` against the retained candidate — all byte-identical.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SRC='<session scratchpad>/g11u-approved/csel-000001.json'
DST=/etc/kyri/fabric/csel-000001.json
WANT=4dbe005137e16c13156318176280f90bf4216a6195d4756efaf3a8d2da3a5a7e

# Fail closed: refuse to overwrite an existing frozen input.
[[ -e "${DST}" ]] && { echo "refusing: ${DST} already exists" >&2; exit 1; }

# Fail closed: refuse anything but the reviewed bytes.
echo "${WANT}  ${SRC}" | sha256sum --check --status \
  || { echo "refusing: source digest mismatch" >&2; exit 1; }

install -o root -g cschott -m 0640 "${SRC}" "${DST}"

# Verify what actually landed.
echo "${WANT}  ${DST}" | sha256sum --check --status \
  || { echo "FAILED: installed digest mismatch" >&2; exit 1; }
[[ "$(stat -c '%U:%G %a %s' "${DST}")" == "root:cschott 640 591" ]] \
  || { echo "FAILED: ownership/mode/size mismatch" >&2; exit 1; }
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${DST}" \
  || { echo "FAILED: not valid JSON" >&2; exit 1; }

stat -c '%n %U:%G %a %s' "${DST}"
sha256sum "${DST}"
```

## 23. Post-freeze rehearsal

Not performed — no freeze occurred this session. After the operator applies the
block above, re-run **only** the non-mutating path:

```bash
python3 -m tools.fabric.cli select --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file csel-000001.json --approved-directory /etc/kyri/fabric
```

Require `selected_instance_id: CINST-000002`, `rehearsal_reason: null`, request
digest `sha256:507b29db…5c21`, CSEL count 0, `capability-selection.seq` still
absent. Then `cmp` the frozen file against the retained candidate.

**Do not** invoke plain `select` as a final preflight — it would spend
`CSEL-000001` (sections 3 and 18).

## 24. Remaining useful lifetime

```
governed instant   2026-08-28T20:47:35-05:00
expiry             2026-08-30T16:19:19-05:00
remaining          1 day, 19:31:44
```

`CADV-000003.valid_until` and `CINST-000002.admitted_until` are the same instant, so
freshness and admission lapse together — the zero R17 tail from G11-Q. Should the
freeze and the authorised write slip past that expiry, the prepared body would
refuse (`advertisement-not-fresh`, `admission-window-expired`) and would still spend
`CSEL-000001` doing so. Re-preparation, not retry, would be required.

## 25. Route-head hardening gate

`ROUTE_HEAD_HARDENING_REQUIRED_BEFORE_NEXT_ROUTE_SUPERSESSION = YES`, carried
forward unchanged and **not** patched here.

`NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING = YES`. No route was created or
modified in this checkpoint.

Selection is permitted despite that gate because it is a read-and-decide operation
over the existing unique route head: it resolves `CROUTE-0002`, judges the
candidates that route declares, and writes only a `capability-selection`. It cannot
alter route topology, so it cannot reach the non-head-predecessor defect.

## 26. Readiness for the authorised CSEL-000001 production decision

Ready, pending the operator freeze. The next checkpoint should:

1. verify the frozen bytes and `cmp`;
2. re-run `select --preflight` and confirm `CINST-000002` and the digest;
3. re-run `evaluate_eligibility` at the body's governed instant — it must still be
   12/12, and if it is not, **stop**, because the write would spend `CSEL-000001` on
   a refusal;
4. execute the mutating `select` exactly once, knowing it spends `CSEL-000001`
   **whatever the decision**;
5. expect **two** file additions and no sequence replacement (section 20).

## 27. Actions not performed

- No mutating production selection; no `CSEL-000001`; no CSEL record of any kind.
- No `CROUTE-0003`; no route successor; `CROUTE-0001` and `CROUTE-0002` untouched.
- `CINST-000001` not withdrawn, retired, or modified.
- No `CINST-000003`, no `CADV-000004`.
- No patch to route-head enforcement, replay semantics, or withdrawn-binding routing.
- No mutation of Trust, Artifact authority, or Platform Evidence.
- No runtime reinstall; no sudoers modification; no Root Authority mount.
- No package staged, no capability invoked.
- No ENG-0006 work; no TrustGateway cutover.
- No source or test change; no implementation commit.
- No write into `/etc/kyri/fabric`.

## Appendix A — commands executed

```bash
# Starting checks, inventory, both manifests
git rev-parse HEAD; git status --porcelain
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust

# Contract reconstruction (read-only)
#   selection.py: select_candidate, _decide, _write, _commit, _resolve_route,
#                 _chain_heads, _exclusions, _locality_permits, _usable_node_identity
#   models.py: CapabilitySelection;  cli.py: command_select, INSTANT_FIELDS
#   eligibility.py: evaluate_eligibility, _request, _scope_permits, _advertised, _admitted
grep -rn 'permitted_capabilities|permitted_targets|permitted_operations' tools/fabric/eligibility.py

# Identity, route resolution, eligibility — all read-only against production
#   store.peek_next_id('capability-selection')
#   selection._chain_heads / selection._resolve_route
#   eligibility.evaluate_eligibility at 2026-08-28T20:47:35-05:00

# Production rehearsal (non-mutating)
python3 -m tools.fabric.cli select --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --trust-store-root /var/lib/kyri/trust \
  --input-file csel-000001.json --approved-directory <scratchpad>/g11u-approved

# Fixtures: faithful history, successful write, refusal control
python3 <scratchpad>/fixture-g11u.py <scratchpad>/g11u-approved/csel-000001.json

# Freeze probe (failed closed) and sandbox validation of the operator block
cp <candidate> /etc/kyri/fabric/csel-000001.json     # Permission denied, as expected
install -m 0640 <candidate> <sandbox>/csel-000001.json
```

## Appendix B — the fabric, stated once

```
CAPDEF-0001  kyri-execution-boundary-verification
CCON-0001    1.0.0, computational (routable), deterministic
CPKG-0001    1.0.0
CHOST-0001   node identity HOST-0001, on-premises, internal, in-service
CADV-000001 → CADV-000002 → CADV-000003   head CADV-000003, valid_until 2026-08-30T16:19:19-05:00
CINST-000001 admitted, adv CADV-000002, ineligible from 2026-08-29T09:24:51-05:00, not routed
CINST-000002 admitted, adv CADV-000003, until 2026-08-30T16:19:19-05:00, ELIG 12/12
CROUTE-0001 → CROUTE-0002                 head CROUTE-0002, candidates ['CINST-000002']
CSEL-000001  PREPARED, not written — request class CAPDEF-0001 / CCON-0001 / ["1.0.0"]
             / internal / local-only, local_node_identity HOST-0001
capability-selection.seq  ABSENT — the first write creates it
```
