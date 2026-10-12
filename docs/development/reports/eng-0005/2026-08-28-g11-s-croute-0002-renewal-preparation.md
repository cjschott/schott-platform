# ENG-0005 G11-S — CROUTE-0002 Renewal Preparation, Cutover Semantics, Live Preflight, and Frozen Operator Input

- Checkpoint: ENG-0005 G11-S
- Date: 2026-08-28
- Branch: `arch/eng-0005-execution-transition`
- Starting authority: `96ed89654d64b1c0636da550f978f0b614c4b582`
- Host: `schai`
- Result: `OPERATOR_ACTION_REQUIRED` (freeze requires root; no production write performed)

## 1. Starting authority

| Check | Observed |
|---|---|
| Branch | `arch/eng-0005-execution-transition` |
| HEAD | `96ed89654d64b1c0636da550f978f0b614c4b582` — matched |
| Origin contains HEAD | yes |
| Worktree | clean; nothing staged, nothing untracked |
| G11-R report present | yes |
| Fabric inspection | `reported`, zero defects |
| Trust store | `valid: True`, zero problems |
| Generation 11 installed runtime | 57 `.py` files, unchanged |
| Root Authority | unmounted |

Inventory matched the brief exactly: CADV 3, CINST 2, CROUTE 1, CSEL 0;
`capability-advertisement.seq = 3`, `capability-instance.seq = 2`,
`capability-route.seq = 1`, `capability-selection.seq` absent.
`CROUTE-0002.yaml` absent; `/etc/kyri/fabric/croute-0002.json` absent.

Both manifests captured before any work: structural 27 entries, content 18 files.

## 2. ⚠ The dated routability deadline — the reviewer's stated instant is 4h21m too late

The brief rules the deadline at `2026-08-29T13:46:27-05:00`, being
`CINST-000001.admitted_until`, at which eligibility reports
`admission-window-expired`. That is ELIG-7 and it is correctly described.

**ELIG-6 bites first.** `CINST-000001` is bound to `CADV-000002`, whose window is:

```
CADV-000002.observed_at  = 2026-08-28T09:24:51-05:00
CADV-000002.valid_until  = 2026-08-29T09:24:51-05:00
```

`tools/fabric/eligibility.py::_advertised` (ELIG-6):

```python
if not observed <= instant < expires:
    return ConditionResult("", UNMET, REASON_ADVERT_STALE)
```

Therefore:

| Instant | `CINST-000001` |
|---|---|
| until `2026-08-29T09:24:51-05:00` | eligible |
| **`2026-08-29T09:24:51-05:00`** | **UNMET — `advertisement-not-fresh` (ELIG-6)** |
| `2026-08-29T13:46:27-05:00` | UNMET — `admission-window-expired` (ELIG-7) |

`CINST-000001` carries a non-zero **R17 tail of 4:21:36** — admitted but not
eligible, because its advertisement lapses before its admission does. This is
precisely the tail that G11-Q eliminated for `CINST-000002` by binding
`admitted_until` to `CADV-000003.valid_until`; `CINST-000001` predates that ruling
and still has one.

**The operative routability deadline is `2026-08-29T09:24:51-05:00`**, not
`13:46:27`. I have not changed anything to suit this; it is read from the committed
records and the released eligibility source. The reviewer's intent — CROUTE-0002
production-ready before the capability stops routing — is unchanged, but the
instant to plan against is 4 hours 21 minutes 36 seconds earlier than stated.

Nothing in this checkpoint was rushed or simplified to meet it. If the deadline is
missed, the platform continues fail-closed and the gap is reported.

## 3. Terminology — two separate facts, kept separate

**FACT A — immutable routes do not follow instance supersession.** `CROUTE-0001`
permanently names `CINST-000001`. `create_route`'s own docstring states the rule:
"**Cutover is a route change**, so a new version is a new record naming the one it
supersedes, and the prior route is left exactly as written." A new binding root
therefore requires a new route. This is released behaviour working as designed, and
it is what G11-S prepares.

**FACT B — the G11-K route-head defect.** `create_route` validates that the named
predecessor resolves, shares the capability and contract
(`supersedes-different-subject`), and has a lower `route_version` — but it does
**not** check that the predecessor is the current chain head. A fork is therefore
admissible at write time and only refused later by selection as
`route-ambiguous-for-request-class`. I re-read `create_route` at
`tools/fabric/admission.py:1789-1935` in full and confirmed no head check exists.

**Why FACT B is unreachable here.** Production contains exactly one route, proved
three independent ways in section 4. A predecessor that is the only record of its
kind is necessarily the head, so `CROUTE-0002 supersedes CROUTE-0001` cannot
exercise the non-head-predecessor path.

`ROUTE_HEAD_HARDENING_BEFORE_CROUTE_0002 = NO`. Not patched here. Deadline
unchanged: before `CROUTE-0003` or any later route supersession, or before ENG-0005
closure, whichever comes first.

## 4. Proof that CROUTE-0001 is the current route head

**[1] Released helper** — `selection._chain_heads(store, "capability-route")`, which
computes heads from what points back:

```
heads = ['CROUTE-0001']    unique: True
```

**[2] Raw traversal / set difference over `supersedes`**:

```
all route ids           = ['CROUTE-0001']
superseded by someone   = []
heads = ids - superseded = ['CROUTE-0001']
dangling predecessors   = none
```

**[3] Direct inspection of CROUTE-0001**:

| Field | Value |
|---|---|
| `route_id` | `CROUTE-0001` |
| `route_version` | `1` |
| `capability_id` | `CAPDEF-0001` |
| `contract_id` | `CCON-0001` |
| `accepted_contract_versions` | `['1.0.0']` |
| `locality` | `local-only` |
| `data_classification` | `internal` |
| `candidate_instances` | `['CINST-000001']` |
| `supersedes` | `None` |
| `superseded_by` | `None` |
| `overlap_window` | `None` |
| `description` / `notes` | `None` / `None` |
| `evidence.reason_category` | `route-change` |

All four required conditions hold: unique current head is `CROUTE-0001`; no second
route; `CROUTE-0001` supersedes nothing; nothing supersedes `CROUTE-0001`.

## 5. Route succession semantics, derived from committed source

Read from `tools/fabric/admission.py::create_route`,
`tools/fabric/models.py::CapabilityRoute`, `tools/fabric/selection.py::_chain_heads`
and `::_resolve_route`, and `tools/fabric/eligibility.py`.

| Rule | Source | Consequence for CROUTE-0002 |
|---|---|---|
| `supersedes` optional, must resolve | `_optional_identifier` + `_resolve` | `CROUTE-0001` resolves |
| Predecessor must share capability and contract | `REASON_SUPERSEDES_SUBJECT` | both `CAPDEF-0001` / `CCON-0001` |
| `route_version` must be an int ≥ 1 and **strictly greater** than the predecessor's | `REASON_ROUTE_VERSION` | `2 > 1` |
| Predecessor need **not** be the chain head | *absence* of any head check | the G11-K defect; unreachable here |
| Candidate list must be non-empty, duplicate-free | `REASON_NO_CANDIDATE`, `REASON_DUPLICATE_CANDIDATE` | one candidate |
| Each candidate must share the capability and contract | `REASON_CANDIDATE_OWNER` | `CINST-000002` does |
| Each candidate must be **its own binding root** | `_binding_root(records, c) != c` → `REASON_NOT_BINDING_ROOT` | `CINST-000002` is |
| Each candidate must be `lifecycle_state == "admitted"` | same reason constant | it is |
| Order is authoritative and human-written | docstring; digested in order | single element |
| Reason category is `supersession` when `supersedes` is set, else `route-change` | `_evidence(...)` | `supersession` |
| Predecessor is left exactly as written; no `superseded_by` is emitted | `_commit` writes only the successor | confirmed in fixture |
| Selection resolves by **chain head** and exact request-class match | `_resolve_route` | `CROUTE-0002` becomes the sole head |
| Two current routes for one class → `route-ambiguous-for-request-class` | `_resolve_route` | avoided: supersession removes the predecessor from the head set |

Derived values, each proved rather than assumed: identity `CROUTE-0002`
(store prediction), predecessor `CROUTE-0001` (section 4), route version `2`
(strict-increase rule), candidate `CINST-000002` (section 7), request class
`CAPDEF-0001` / `CCON-0001` / `["1.0.0"]` / `internal` / `local-only` (copied from
the predecessor so `_resolve_route` matches exactly).

## 6. Complete overlap-window analysis

Ten questions, answered from source only.

**1. Optional or mandatory on route supersession?** Optional. Both parameters
default to `None`. They are both-or-neither:

```python
if (overlap_starts_at is None) != (overlap_ends_at is None):
    _refuse(INVALID, REASON_OVERLAP_MALFORMED)      # malformed-overlap-window
```

**2. Exact invariants, including any relation to `recorded_at`?** Four, all in
`create_route`:

- both aware instants (`_aware`);
- `overlap_ends_at > overlap_starts_at`, else `REASON_WINDOW`;
- `supersedes` must be present, else `overlap-window-without-supersession`;
- at accept time, `arrived = candidates - prior_candidates` must be non-empty
  (`overlap-window-without-cutover`) **and** `carried = candidates ∩ prior_candidates`
  must be non-empty (`overlap-window-without-coexistence`).

**There is no invariant relating the window to `recorded_at` at all.** A window may
be entirely in the past or entirely in the future and nothing objects. That is a
direct consequence of answer 3.

**3. What does selection do during an overlap?** Nothing. I grepped every
occurrence of `overlap` in `tools/`:

```
eligibility.py:262   — a prose comment only
models.py:629,654-5  — the field, and freezing it
admission.py         — the reason constants, validation, and the write
cli.py:95-96         — naming the two instants so a body cannot smuggle one
```

`selection.py` contains **zero** references. `overlap_window` is written, frozen,
and read by nothing. `create_route`'s docstring says so plainly: "It is evidence:
nothing here schedules, activates, or reroutes anything."

**4. Can both predecessor and successor be current during an overlap?** No.
`_chain_heads` computes heads purely structurally from `supersedes`. The instant the
successor exists, the predecessor is not a head, window or no window.

**5. Does overlap affect chain-head determination?** No — see answer 4.

**6. Does it change which candidate list selection uses?** No. Selection uses the
head route's `candidate_instances`. Coexistence during a cutover is expressed by
*putting both instances in the successor's candidate list*, not by the window.

**7. Migration mechanism or metadata?** Metadata — specifically, evidence. The
window *asserts* a coexistence that the candidate lists must independently
demonstrate; the accept-time checks exist to stop the record claiming a coexistence
it does not show. It never causes one.

**8. Is a zero-duration or no-overlap cutover lawful?** No-overlap: yes, and it is
the default. Zero-duration: **no** — `overlap_ends_at <= overlap_starts_at` is
refused, so a window can never be instantaneous.

**9. What did G11-K's valid supersession fixture actually prove?** At
`tests/test-fabric-route-preflight.sh:493-518` it proved exactly three things about
windows, and only at the record-acceptance layer: a cutover carrying one candidate
forward and adding one is accepted; an overlap adding nothing refuses
`overlap-window-without-cutover`; an overlap carrying nothing forward refuses
`overlap-window-without-coexistence`. **It proved nothing about selection
behaviour during a window**, because there is none to prove.

**10. Does our specific cutover benefit from an overlap?** No — and for this
candidate list a window is not merely unnecessary, it is **unlawful**. I ran both
controls in fixtures:

```
the SAME body plus an overlap window is REFUSED
      [refused/overlap-window-without-coexistence]
```

`candidate_instances = ["CINST-000002"]` and `prior_candidates = ["CINST-000001"]`
intersect in nothing, so `carried` is empty and the accept-time check fires.

The lawful alternative was also constructed and measured, so that declining it is a
decision rather than an omission:

```
the lawful alternative (carry both + window) IS accepted
the alternative stores an overlap_window
      {"starts_at": "2026-08-28T20:11:43-05:00", "ends_at": "2026-08-29T13:46:27-05:00"}
under the alternative, selection prefers the OLDER binding CINST-000001
```

That last line is the reason to reject it. Selection takes the **first eligible
candidate in declared order**, so a route naming `[CINST-000001, CINST-000002]`
keeps sending work to the binding that goes stale in under 13 hours, and only falls
through afterwards. The window would sit in the record asserting a coexistence that
changes nothing.

## 7. Chosen cutover behaviour and rationale

**`OVERLAP_POLICY = NONE`.** Immediate supersession, single candidate.

This is the smallest behaviour that achieves the cutover, and it is the only lawful
one for a route that replaces its candidate set outright. Three reasons, in order of
weight:

1. **A window is refused for this body.** Not a preference — `create_route` rejects
   it (`overlap-window-without-coexistence`).
2. **A window would be inert.** No selection or eligibility code reads
   `overlap_window`. Adding one would record an assertion nothing acts on.
3. **The alternative routes to the wrong binding.** Carrying `CINST-000001` forward
   would prefer it by declared order until `2026-08-29T09:24:51-05:00`, keeping the
   platform on the binding with the earlier deadline and the stale advertisement.
   Cutting over immediately puts work on `CINST-000002`, which is fresh until
   `2026-08-30T16:19:19-05:00`.

The cutover is therefore atomic at the instant of the production write, and there is
no gap: `CINST-000002` is admitted and eligible now.

## 8. Field-by-field body derivation

| Field | Value | Derived from |
|---|---|---|
| `request_id` | `g11s-create-route-capdef-0001-ccon-0001-cinst-000002-supersedes-croute-0001` | G11-L naming convention, extended to name this supersession |
| `actor` | `primary-platform-operator` | established operator identity (`CROUTE-0001`) |
| `approving_authority` | `primary-platform-operator` | same |
| `recorded_at` | `2026-08-28T20:11:43-05:00` | one fresh instant, America/Chicago |
| `capability_id` | `CAPDEF-0001` | predecessor; required to match |
| `contract_id` | `CCON-0001` | predecessor; required to match |
| `accepted_contract_versions` | `["1.0.0"]` | predecessor; request class must match exactly for `_resolve_route` |
| `locality` | `local-only` | predecessor; part of the request class |
| `candidate_instances` | `["CINST-000002"]` | the renewed binding root (section 7) |
| `data_classification` | `internal` | predecessor; part of the request class |
| `route_version` | `2` | strict-increase rule over the predecessor's `1` |
| `supersedes` | `CROUTE-0001` | the proved current head |
| `provenance` | `{class: declared, source: ADR-0012…, recorded_at: 2026-08-28}` | current accepted convention |
| `description` / `notes` | **omitted** | not required; nothing consumes them |
| `overlap_starts_at` / `overlap_ends_at` | **omitted** | section 6/7 — refused for this candidate list, and inert |

## 9. The exact body

```json
{
  "request_id": "g11s-create-route-capdef-0001-ccon-0001-cinst-000002-supersedes-croute-0001",
  "actor": "primary-platform-operator",
  "approving_authority": "primary-platform-operator",
  "recorded_at": "2026-08-28T20:11:43-05:00",
  "capability_id": "CAPDEF-0001",
  "contract_id": "CCON-0001",
  "accepted_contract_versions": [
    "1.0.0"
  ],
  "locality": "local-only",
  "candidate_instances": [
    "CINST-000002"
  ],
  "data_classification": "internal",
  "route_version": 2,
  "supersedes": "CROUTE-0001",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-28"
  }
}
```

## 10. Bytes

| Property | Value |
|---|---|
| SHA-256 | `dcbdae8c274f3fffbd3f67c31a72f88be290aa74b2377d34ca4c22cd5b702c5e` |
| Size | 676 bytes |
| JSON validity | parses |
| Formatting | two-space indent, matching `croute-0001.json` |
| Trailing newline | present |
| Overlap fields | zero occurrences of the string `overlap` |

A byte-identical copy is retained in the session scratchpad for `cmp` after the
freeze.

## 11. Request digest

```
sha256:a7abf7966d4c82510c0f4cc26dfffd67e0d89eb560fda9e1c0ef3a13bbcd52b6
```

Identical across all three computations: fixture rehearsal, independent fixture
write, live production preflight.

## 12. Faithful fixture history

Carrying the G11-Q lesson: a chain-sensitive fixture must reproduce the production
*sequence*, not the terminal graph. The fixture builds, in order:

```
base authority (root, two Trust grants, CAPDEF, CCON, CPKG, CHOST)
CADV-000001
CADV-000002                       supersedes CADV-000001
CINST-000001                      admitted against CADV-000002 while it was current
CROUTE-0001                       naming CINST-000001, route_version 1
CADV-000003                       supersedes CADV-000002
CINST-000002                      against CADV-000003, supersedes CINST-000001
```

Building the three advertisements up front and admitting afterwards would trip R16
(`advertisement-record-superseded`), exactly as it did in G11-Q. Verified in the
fixture:

```
PASS: the fixture reproduces the production identities in production order
PASS: CINST-000001 was admitted against CADV-000002 while it was current
PASS: CROUTE-0001 names CINST-000001 only
PASS: CINST-000002 was admitted against CADV-000003 and supersedes CINST-000001
PASS: CINST-000002 is its own binding root
PASS: CROUTE-0001 is the unique current route head
PASS: the fixture predicts CROUTE-0002
```

## 13. Fixture rehearsal

```
PASS: rehearsal outcome is preflight            [preflight/None]
PASS: rehearsal reason is none
PASS: rehearsal names no record
PASS: no allocation and no write
PASS: the route sequence is unchanged (still 1)
PASS: the route count is unchanged (still 1)
PASS: CROUTE-0001 is unchanged
      rehearsal request digest: sha256:a7abf796…52b6
```

## 14. Independent fixture write

A **second** world, so the rehearsal world is never mutated to prove the write.

```
PASS: the identical body is accepted in a second fixture   [accepted/None]
PASS: the written identity is CROUTE-0002
PASS: the write carries the same request digest as the rehearsal
PASS: the successor names CROUTE-0001
PASS: route_version is 2
PASS: candidate_instances is exactly [CINST-000002]
PASS: no overlap window was stored
PASS: the successor is filed as supersession
PASS: the predecessor acquires no superseded_by backlink
PASS: the request class is identical to the predecessor's
```

## 15. Resulting route-chain proof

```
PASS: the unique current route head becomes CROUTE-0002    [['CROUTE-0002']]
PASS: CROUTE-0001 is no longer a head
PASS: selection resolves the request class to exactly one route   [CROUTE-0002]
PASS: resolution is neither ambiguous nor unreadable
```

No `route-chain-unreadable`, no `route-ambiguous-for-request-class`.

## 16. Fixture selection proof

Fixture only. **No CSEL was created in production**; production still holds zero
selections and has no `capability-selection.seq`.

Evaluated at an instant where `CINST-000002` is admitted and `CADV-000003` is fresh,
with `local_node_identity = HOST-0001`:

```
PASS: selection is accepted                                  [accepted/None]
PASS: selection resolved via CROUTE-0002
PASS: selection chose CINST-000002
PASS: CINST-000001 was not considered (route does not name it)
      considered_candidates = ['CINST-000002']
      excluded_candidates   = []
```

`CINST-000001` produces no exclusion record because the route never offers it — it
is not a rejected candidate, it is not a candidate.

A method note: my first pass asserted against `considered_instances`, which is not a
field of `CapabilitySelection`; the check passed vacuously. Re-run against the real
field `considered_candidates` (`tools/fabric/models.py:669`), it passes on evidence.

## 17. Live production preflight

Run from an isolated approved preparation directory, before any freeze:

```json
{
  "destination": "/var/lib/kyri/fabric/capability-routes/CROUTE-0002.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "create-route",
  "outcome": "preflight",
  "predicted_record_id": "CROUTE-0002",
  "record_kind": "capability-route",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:a7abf7966d4c82510c0f4cc26dfffd67e0d89eb560fda9e1c0ef3a13bbcd52b6",
  "request_id": "g11s-create-route-capdef-0001-ccon-0001-cinst-000002-supersedes-croute-0001",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

Every required condition holds, including `would_accept: true` and
`rehearsal_reason: null`.

## 18. No-mutation proof

Both manifests re-captured after the preflight and diffed against the pre-work
capture:

```
structural: IDENTICAL
content:    IDENTICAL
capability-route.seq = 1
CROUTE count = 1
CSEL count   = 0
```

## 19. Frozen input evidence

**Not completed — the freeze requires root.** The write probe failed closed:

```
cp: cannot create regular file '/etc/kyri/fabric/croute-0002.json': Permission denied
/etc/kyri/fabric/croute-0002.json: ABSENT
```

Boundary precedent re-derived from the live directory rather than assumed:

```
dir   /etc/kyri/fabric              root:cschott 0750
file  /etc/kyri/fabric/croute-0001.json   root:cschott 0640
```

The operator block below was validated in a sandbox first — it produced mode `0640`,
676 bytes, digest `dcbdae8c…02c5e`, byte-identical to the retained candidate.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

SRC='<session scratchpad>/g11s-approved/croute-0002.json'
DST=/etc/kyri/fabric/croute-0002.json

# Fail closed: refuse to overwrite an existing frozen input.
[[ -e "${DST}" ]] && { echo "refusing: ${DST} already exists" >&2; exit 1; }

# Fail closed: refuse anything but the reviewed bytes.
echo 'dcbdae8c274f3fffbd3f67c31a72f88be290aa74b2377d34ca4c22cd5b702c5e  '"${SRC}" \
  | sha256sum --check --status || { echo "refusing: source digest mismatch" >&2; exit 1; }

install -o root -g cschott -m 0640 "${SRC}" "${DST}"

stat -c '%n %U:%G %a %s' "${DST}"
sha256sum "${DST}"
```

## 20. Post-freeze preflight

Not performed — no freeze occurred this session. After the operator applies the
block above, re-run before any write:

```bash
python3 -m tools.fabric.cli create-route \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0002.json --approved-directory /etc/kyri/fabric --preflight
```

Require `predicted_record_id: CROUTE-0002`, `would_accept: true`,
`mutated: false`, and request digest
`sha256:a7abf7966d4c82510c0f4cc26dfffd67e0d89eb560fda9e1c0ef3a13bbcd52b6`, then
`cmp` the frozen file against the retained candidate.

## 21. CINST-000001 disposition

**Unchanged.** Not withdrawn, not retired, not modified, not lifecycle-transitioned.
It remains `admitted`, remains its own binding root, and remains the sole candidate
named by `CROUTE-0001` until `CROUTE-0002` is written. It was read read-only for
comparison only:

| | `CINST-000001` | `CINST-000002` |
|---|---|---|
| `lifecycle_state` | `admitted` | `admitted` |
| own binding root | yes | yes |
| advertisement | `CADV-000002` (superseded) | `CADV-000003` (head) |
| advertisement fresh until | `2026-08-29T09:24:51-05:00` | `2026-08-30T16:19:19-05:00` |
| `admitted_until` | `2026-08-29T13:46:27-05:00` | `2026-08-30T16:19:19-05:00` |
| R17 tail | **4:21:36** | zero |

Lifecycle disposition remains open, to be decided after `CROUTE-0002` and
`CSEL-000001` prove the new path.

## 22. Replay finding — deferred

Recorded, not patched. G11-R observed that replaying the exact `CINST-000002` body
refuses structurally as `supersedes-already-superseded` rather than through
request-digest replay detection. The digest is unchanged across both invocations and
the plane does not treat repetition as disqualifying on its own. Registered as a
separate deferred Fabric semantic question. No change was made to admission, replay
lookup, request identity, or digest semantics.

## 23. Route-head defect deadline

`ROUTE_HEAD_HARDENING_BEFORE_CROUTE_0002 = NO`, as ruled. The hardening deadline is
unchanged: **before `CROUTE-0003` or any later route supersession, or before ENG-0005
closure, whichever comes first.** After `CROUTE-0002` exists there will be two
routes, so the next supersession is the first one where a non-head predecessor is
genuinely selectable and the defect becomes reachable.

## 24. Actions not performed

- No `CROUTE-0002` production write.
- No `CSEL-000001`; no selection record in production at all.
- No `CROUTE-0003`, no `CINST-000003`, no `CADV-000004`.
- `CINST-000001` not withdrawn, retired, or modified.
- No patch to route-head enforcement, replay semantics, or withdrawn-binding routing.
- No mutation of Trust, Artifact authority, or Evidence authority.
- No runtime reinstall; no Root Authority mount (remained unmounted).
- No package staged, no capability invoked.
- No ENG-0006 work; no TrustGateway cutover.
- No source or test change — `create-route --preflight` is already permanently
  covered by `tests/test-fabric-route-preflight.sh`, and nothing needed correcting.
- No write into `/etc/kyri/fabric`.

## 25. Readiness for the separately authorised CROUTE-0002 write

Ready, pending two operator steps.

1. **Operator freezes** `/etc/kyri/fabric/croute-0002.json` using the block in
   section 19 — `root:cschott 0640`, 676 bytes, `dcbdae8c…02c5e`.
2. **A subsequent authorised checkpoint** re-preflights from the approved directory
   and, if the digest matches, executes once:

```bash
python3 -m tools.fabric.cli create-route \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0002.json --approved-directory /etc/kyri/fabric
```

**Timing.** The write should land before `2026-08-29T09:24:51-05:00` (section 2),
not the `13:46:27` in the brief. Roughly 13 hours remained at the time of this
report. If the deadline passes first, the platform fails closed — selection will
report `no-eligible-candidate` rather than route to a stale binding — and the
cutover simply restores service when it lands. No ceremony should be shortened to
beat the clock.

**Open question for the reviewer**: `CINST-000001`'s 4h21m R17 tail exists because
it was admitted before the G11-Q dependency-bounding ruling. Should a general
invariant — an instance's `admitted_until` may never exceed its advertisement's
`valid_until` — be enforced in `admit_instance` rather than left to ceremony policy?
That would make the tail structurally impossible instead of merely avoided by
convention. It is out of scope here and I have not implemented it.

## Appendix A — commands executed

```bash
# Starting checks, inventory, both manifests
git rev-parse HEAD; git status --porcelain
git branch -r --contains 96ed89654d64b1c0636da550f978f0b614c4b582
( cd /var/lib/kyri/fabric && find . -mindepth 1 -printf '%y %m %U:%G %s %p\n' | sort )
( cd /var/lib/kyri/fabric && find . -type f -print0 | sort -z | xargs -0 sha256sum )
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust

# Head proof (three ways), semantics, candidate validity — all read-only
#   selection._chain_heads / raw set-difference / direct record read
#   create_route, CapabilityRoute, _resolve_route, _advertised, _admitted
grep -rn 'overlap' tools/ --include=*.py

# Fixture rehearsal, independent fixture write, chain proof
python3 <scratchpad>/rehearse-g11s.py <scratchpad>/g11s-approved/croute-0002.json

# Fixture selection proof + overlap controls
python3 <scratchpad>/select-g11s.py <scratchpad>/rehearse-g11s.py \
        <scratchpad>/g11s-approved/croute-0002.json

# Live production preflight, from an isolated approved directory
python3 -m tools.fabric.cli create-route \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file croute-0002.json --approved-directory <scratchpad>/g11s-approved \
  --preflight

# Freeze probe (failed closed) and sandbox validation of the operator block
cp <candidate> /etc/kyri/fabric/croute-0002.json      # Permission denied, as expected
install -m 0640 <candidate> <sandbox>/croute-0002.json
```

## Appendix B — the fabric, stated once

```
CAPDEF-0001  kyri-execution-boundary-verification
CCON-0001    1.0.0, computational, deterministic
CPKG-0001    1.0.0
CHOST-0001   node identity HOST-0001
CADV-000001 → CADV-000002 → CADV-000003   head CADV-000003, valid_until 2026-08-30T16:19:19-05:00
CINST-000001 admitted, adv CADV-000002 (stale from 2026-08-29T09:24:51-05:00),
             admitted_until 2026-08-29T13:46:27-05:00, binding root CINST-000001
CINST-000002 admitted, adv CADV-000003, admitted_until 2026-08-30T16:19:19-05:00,
             binding root CINST-000002, supersedes CINST-000001
CROUTE-0001  route_version 1, local-only, candidate_instances ['CINST-000001'], current head
CROUTE-0002  PREPARED, not written — route_version 2, candidate_instances ['CINST-000002'],
             supersedes CROUTE-0001, no overlap window
CSEL         none
```
