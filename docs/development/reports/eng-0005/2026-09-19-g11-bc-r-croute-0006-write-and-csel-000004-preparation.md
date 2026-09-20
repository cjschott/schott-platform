# G11-BC-R — the CROUTE-0006 write, verified; CSEL-000004 prepared

ENG-0005. 2026-09-19. Branch `arch/eng-0005-execution-transition`.

The CROUTE-0006 production write was verified independently of the reviewer's
report and its mutation accounted for by content.

The CSEL-000004 freeze artifact was then prepared, **gated three times** rather
than twice, and rehearsed whole. A selection is the only record in this chain
whose correctness its own identity cannot settle, which is what the third gate
exists for.

Nothing was installed and nothing was written to production.

---

## 1. Starting source authority

| | |
| --- | --- |
| HEAD at start | `9fa18d873b40d30feb00a693a91730decc166f9d` |
| required source authority | `9fa18d873b40d30feb00a693a91730decc166f9d` ✔ |
| branch | `arch/eng-0005-execution-transition` ✔ |
| origin | contains HEAD at the same commit ✔ |
| working tree | clean; nothing staged, nothing untracked ✔ |
| G11-BC-Q report | present ✔ |

## 2. Prior preparation authority

G11-BC-Q prepared `provisioning/fabric/g11-bc-n-croute-0006-freeze.txt`,
recovered the reviewed CROUTE-0006 body as committed bytes, rehearsed the whole
block and proved it fails closed at every stage. That artifact was the
executable authority for the ceremony.

## 3. The freeze result

```
/etc/kyri/fabric/croute-0006.json
sha256  cd7a1f9a8cd5f982d3f62b7d02ff253bc6c33b006a9aa0717aff162a1e40a78c   ✔ reviewed
bytes   678                                                               ✔ reviewed
owner   root:cschott   mode 0640                                          ✔ reviewed
```

Verified read-only this checkpoint, directly from the live path.

**And it is byte-identical to `provisioning/fabric/g11-bc-n-croute-0006-input.json`.**
That is the first end-to-end proof that committing the reviewed bytes worked:
the body G11-BC-Q recovered — digest-only in G11-BC-N, never committed — is
literally the body that was frozen and written. The claim is now checkable
rather than reported, and the rehearsal suite asserts it on every run.

## 4. Current-time gate

PASS. At freeze time CADV-000007 was fresh, CINST-000006's admission was open,
the route's `recorded_at` lay inside that admission, and
`admitted_until <= valid_until`.

## 5. Current eligibility

```
eligible True | 12 of 12 met | unmet [] | reasons []
```

Recomputed this checkpoint against production through the released evaluator at
the current clock: unchanged, 12 of 12.

## 6. Final preflight

```
destination           /var/lib/kyri/fabric/capability-routes/CROUTE-0006.yaml
destination_exists    false
mutated               false
operation             create-route
outcome               preflight
predicted_record_id   CROUTE-0006
record_kind           capability-route
rehearsal_reason      null
would_accept          true
request_digest        sha256:4a81d1c7fc7c023de601ea004a8bbd3ee9d4bb150b9867e52e1c7075447035a9
```

Pre-write Fabric aggregate:
`1549986cf2119f9da4af805cf5cbb5733f9c0fa1d28b76e25dc3e78be7f2cb78`.

## 7. The production write

```
outcome        accepted
reason         null
record_id      CROUTE-0006
record_kind    capability-route
request_digest sha256:4a81d1c7fc7c023de601ea004a8bbd3ee9d4bb150b9867e52e1c7075447035a9
request_id     g11bcn-create-route-capdef-0001-ccon-0001-cinst-000006-supersedes-croute-0005
```

## 8. Persisted record and semantics

`/var/lib/kyri/fabric/capability-routes/CROUTE-0006.yaml`

```
sha256  ffa04e0f578b5ae420ef01f5d38ce0e547fef56a13d2976d2923d82fce7ff3f2   ✔ matches reviewer
```

Read back from the live record this checkpoint:

| field | value |
| --- | --- |
| `route_id` | CROUTE-0006 |
| `route_version` | 6 |
| `supersedes` | CROUTE-0005 |
| `capability_id` | CAPDEF-0001 |
| `contract_id` | CCON-0001 |
| `accepted_contract_versions` | ["1.0.0"] |
| `locality` | local-only |
| `candidate_instances` | ["CINST-000006"] |
| `data_classification` | internal |
| `recorded_at` | 2026-09-19T06:30:00-05:00 |
| stored `request_digest` | `sha256:4a81d1c7…447035a9` ✔ |

Every value matches the reviewer's record exactly.

## 9. Sequence transition

```
capability-route.seq           5 -> 6
capability-advertisement.seq   7   unchanged
capability-instance.seq        6   unchanged
capability-selection.seq       3   unchanged
```

## 10. Independent mutation accounting

By content, not by pathname or mtime. `capability-route.seq` is 2 bytes before
and after, so equal-size replacement is possible and enumeration would not
detect it.

The live store was copied, `CROUTE-0006.yaml` removed from the copy, and
`capability-route.seq` rewound to `5`. The canonical aggregate of that
reconstruction is:

```
1549986cf2119f9da4af805cf5cbb5733f9c0fa1d28b76e25dc3e78be7f2cb78
```

which is exactly the accepted pre-write aggregate. The aggregate hashes every
file's content, so reproducing it proves **no other file in the store differs by
a single byte**. The complete Fabric mutation was therefore:

1. creation of `capability-routes/CROUTE-0006.yaml`;
2. advancement of `capability-route.seq` from `5` to `6`.

Both are within the released `create-route` write contract. No unexpected
mutation.

The path renormalisation the reconstruction requires was validated first
against an *unmodified* copy of the live store, which reproduced the live
aggregate exactly, before it was trusted to judge a modified one.

The frozen-input store was accounted for the same way. `/etc/kyri/fabric` moved
from `292a0888ed3483a4d91e69d6c285b93f41fcbb3b6f328c0cfa0cc6737a2206d6` to
`81f86a8057227179c4ad798a016c01b2356b4d1e5b4f670db19d27fbe3f1d880`; removing
`croute-0006.json` from a copy of the current store reproduces the former
exactly. The freeze's only effect there was the one file it declared.

## 11. Post-write Fabric validation

```
status    reported
findings  []
reason    null
counts    CADV 7, CINST 6, CROUTE 6, CSEL 3,
          contract 1, definition 1, host 1, package 1
```

CADV-000007 remains the advertisement head, CINST-000006 the instance head, and
CROUTE-0006 is the route head. CSEL-000004 and CINV-000003 are absent.

## 12. Post-CROUTE Fabric aggregate

Computed with the established canonical command:

```bash
find /var/lib/kyri/fabric -type f -print0 | sort -z \
  | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
```

```
f122e53034eeca45ce7b1d8ac5afdc9562a16a086757e203291a8ce1b018cefb
```

**This is the required baseline for the CSEL-000004 freeze artifact.** No
earlier baseline is reused, and the suite now asserts that every artifact's
executable `FABRIC_BEFORE` is its own step's baseline.

## 13. No mutation outside Fabric

| authority | aggregate | agrees with G11-BC-Q |
| --- | --- | --- |
| `/usr/lib/kyri/python` (runtime) | `70011c72f8a1c9c4f29111c6ae0f6caa6c8ece6973611a64d0664e437f58e793` | yes |
| `/var/lib/kyri/evidence` (Platform Evidence) | `62c875851b83ca0d53c8b82469709be530cc6dad2957bb766fdb65fc2b5dc507` | yes |
| `/var/lib/kyri/artifacts` (Artifact authority) | `ef4297c611a2dd824f1c1e4960e64304f72b04d77c0f5f20dd650b0b3eb410df` | yes |
| `/data/kyri/capability-runtime` | cinv.seq 2, cres.seq 1 | yes |
| Root Authority | not mounted | yes |

Trust: `valid true`, `problems []`, counts authority 1, record 2, decision 2,
lineage 3, evidence 7, audit 4. TREC-000001 and TREC-000002 remain the
governing records. The runtime was not reinstalled, sudoers was not modified,
Root Authority was not mounted.

---

## 14. The CSEL-000004 reviewed input, re-verified

Already committed by G11-BC-Q; unchanged since, confirmed by diff against that
commit.

```
provisioning/fabric/g11-bc-n-csel-000004-input.json
sha256   d04171c50397be2d41f8d066b526f237d982ac1df113840eb81afa6ec44c2f29   ✔
bytes    605                                                               ✔
JSON     one document                                                      ✔
recorded_at / evaluated_at   2026-09-19T06:40:00-05:00                     ✔
```

Put through the released engine against a scratch copy of current production:

| | observed | reviewed |
| --- | --- | --- |
| `predicted_record_id` | CSEL-000004 | ✔ |
| `request_digest` | `sha256:2856ff77…1fd437` | ✔ |
| `selected_instance_id` | CINST-000006 | ✔ |
| `would_accept` / `mutated` | true / false | ✔ |

And written into the scratch store, so the resolution could be read out of the
persisted record rather than inferred:

```
selection_id           CSEL-000004
route_id               CROUTE-0006        route_version 6
selected_instance_id   CINST-000006
considered_candidates  [CINST-000006]
excluded_candidates    []
capability-selection.seq   3 -> 4
```

Production was byte-identical before and after.

---

## 15. The CSEL-000004 freeze artifact

`provisioning/fabric/g11-bc-n-csel-000004-freeze.txt`. Prepared, not executed.
The block copies the committed inert input; it does not restate the body.

What it pins:

| | |
| --- | --- |
| reviewed body sha256 | `d04171c50397be2d41f8d066b526f237d982ac1df113840eb81afa6ec44c2f29` |
| reviewed byte count | 605 |
| request digest | `sha256:2856ff77601e24e80f9414abf93a6eb4719d0514b386ceaca9472e712f1fd437` |
| predicted record id | CSEL-000004 |
| selected instance | CINST-000006 |
| route identity | CROUTE-0006 (route_version 6) |
| Fabric baseline | `f122e53034eeca45ce7b1d8ac5afdc9562a16a086757e203291a8ce1b018cefb` (post-CROUTE) |
| required predecessor input | `/etc/kyri/fabric/croute-0006.json` |
| destination | `/etc/kyri/fabric/csel-000004.json`, refused if it exists |

Refused **by name**:

```
60857d68…   the WITHDRAWN G11-BC-M CSEL-000004 body
4dbe0051…   the accepted CSEL-000001 input
5e3b3be1…   the accepted CSEL-000002 input
700a1390…   the accepted CSEL-000003 input, which selected CINST-000004
```

The withdrawn body is the dangerous one and it is dangerous in a way the others
are not: it carries the **same selection identity and the same 605 bytes**, it
was reviewed, and it was withdrawn only because its authority expired. It is
the body this ceremony replaces, not one it precedes.

---

## 16. The safety contract — why this ceremony has three gates

A selection can accept, match its reviewed request digest, and still be wrong.
Two things must hold, they can fail independently, so they are checked
separately.

**Route headship is structural, not temporal.** The selector resolves a route by
chain head — the record for this request class that nothing supersedes — and
that resolution is not time-bound. A CROUTE-0007 written after this artifact was
reviewed would move the head silently, and the reviewed bytes would then resolve
through a route nobody reviewed **while still matching their own request
digest**. No clock check catches that.

**Gate 1 — wall clock and binding. Four inputs, four channels.** The rendered
body is `argv[1]`; the inspected CADV-000007, CINST-000006 and CROUTE-0006 are
`argv[2..4]`; stdin carries the program and nothing else. It refuses on
malformed or unreadable authority, a missing field, an instant that does not
parse, an instant with **no timezone offset** (refused rather than guessed), an
expired advertisement, a closed admission, an admission outliving the
advertisement it rests on, a route that is not CROUTE-0006 or not
`route_version 6`, a route whose `candidate_instances` is not exactly
`["CINST-000006"]`, an instance not `admitted` or not resting on CADV-000007,
and a body whose request class differs from the route's in any field. It runs
as a plain command under `if !`, so its status is its own.

```
observed_at <= now < valid_until            the advertisement
now < admitted_until                        the admission
admitted_until <= valid_until               the admission cannot outlive it
admitted_at <= evaluated_at < admitted_until   the selection lies inside it
```

**Gate 2 — current eligibility.** CINST-000006's eligibility recomputed by the
released evaluator at the current clock, read-only against production. Requires
`eligible is True`, `unmet == []`, and a non-empty condition list.

**Gate 3 — governed resolution.** The preflight reports `would_accept` and
`selected_instance_id` and **does not say which route it resolved through**. So
the released selector is run to completion against a **copy** of production and
the persisted record is read. That is the engine's own answer to "which route
governs this request now", obtained without reimplementing headship in the gate
— a gate that reimplements the thing it checks can only agree with itself. It
requires `selection_id CSEL-000004`, `route_id CROUTE-0006`, `route_version 6`,
`selected_instance_id CINST-000006`, `considered == [CINST-000006]` and no
exclusions.

All three run **before** the install. A preflight that resolved to some other
eligible instance cannot satisfy this ceremony: the instance is pinned by name
in Gate 3 and again against production after the install.

Fabric replay semantics are unchanged. The engine judges at the instant the
request names, which is correct for an append-only store; the protection against
a historical `evaluated_at` blessing an expired or superseded operational
authority belongs in the operator ceremony, which is where it is.

**Gate 3's record reader.** The persisted record is read as text rather than
parsed as YAML, because the block may not assume a YAML library is installed on
the operator's host, and the fields it reads are flat scalars and one-item
lists. It was executed against the real persisted record before anything was
committed, and against seven corruptions — a moved route head, a wrong route
version, a wrong persisted instance, a wrong selection id, a widened considered
set, a non-empty exclusion set, an unreadable file — refusing each **by its own
reason** and crashing on none.

---

## 17. Rehearsal

The whole block runs to completion against a fixture copied from the production
stores:

```
ok  observed_at <= now < valid_until
ok  now < admitted_until <= valid_until
ok  admitted_at <= evaluated_at < admitted_until
ok  CROUTE-0006 routes to exactly CINST-000006
ok  the body asks the request class CROUTE-0006 declares
eligible True | 12 of 12 met | unmet [] | reasons []
ok  CINST-000006 eligible at the current clock
ok  resolved route      CROUTE-0006 (route_version 6)
ok  selected instance   CINST-000006
ok  considered          CINST-000006, excluded none
ok  predicted_record_id   CSEL-000004
ok  selected_instance_id  CINST-000006
ok  request_digest        sha256:2856ff77…
```

The suite independently asserts of that run: the rendered block references no
production path; the installed frozen input is `d04171c5…`, 605 bytes, mode
0640, and is the committed inert input **copied, not restated**; the `select`
against production stayed a preflight; and **no selection record was written
even in the fixture**, with the fixture's `capability-selection.seq` still 3.

**The scratch write**, done deliberately so the identity and sequence the
operator's write will produce are known before it is authorised:

```
record_id CSEL-000004, digest sha256:2856ff77…, selected CINST-000006
capability-selection.seq 3 -> 4
persisted: route_id CROUTE-0006, route_version 6,
           considered [CINST-000006], excluded []
```

### Fail closed, by stage

Every case must refuse **for its own reason** and must not crash.

| sabotage | exits nonzero | own refusal | no traceback | gate 2 | gate 3 | install | fixture store |
| --- | --- | --- | --- | --- | --- | --- | --- |
| gate 1: advertisement expired | yes | yes | yes | **no** | **no** | **no** | byte-identical |
| gate 1: admission expired | yes | yes | yes | **no** | **no** | **no** | byte-identical |
| gate 1: route no longer points at CINST-000006 | yes | yes | yes | **no** | **no** | **no** | byte-identical |
| gate 1: `inspect` itself fails | yes | yes | yes | **no** | **no** | **no** | byte-identical |
| gate 2: not currently eligible | yes | yes | yes | yes | **no** | **no** | byte-identical |
| gate 2: `compute-eligibility` fails | yes | yes | yes | yes | **no** | **no** | byte-identical |
| gate 3: the selector itself fails | yes | yes | yes | yes | yes | **no** | byte-identical |
| wrong body / digest mismatch | yes | yes | yes | **no** | **no** | **no** | byte-identical |
| changed Fabric baseline | yes | yes | yes | yes | yes | (after) | byte-identical |

No selection record was created in any run. An expired advertisement stops the
block before Gate 2 and before the install on **3 of 3** runs.

Gate 3's own failures — a moved route head, a selector that chose another
eligible instance — cannot be produced by sabotaging the live store, because
they are states this host is not in and must not be put into. They are judged
by running Gate 3's extracted check directly against crafted engine output.

---

## 18. Defects found and fixed in this checkpoint

**A spent ceremony must not pin a whole-store aggregate.** G11-BC-Q gave the
CINST-000006 rehearsal a spent-ceremony mode that asserted the post-write
aggregate `1549986c…`. Writing CROUTE-0006 moved the store, and that suite
began failing for the one reason that is not a defect — the same class of
problem the spent mode was introduced to solve, reintroduced one level up.

Fixed in both spent suites. A spent ceremony now asserts only what stays true
forever: its own record is still present and byte-for-byte what was accepted
(Fabric records are immutable, so that never expires), the frozen input is still
the reviewed body, the committed inert input still matches both, and the
sequence is **at or past** the identifier the write allocated rather than
exactly equal to it — sequences are monotonic and later records legitimately
raise them.

**The existence guard was replaced by the property it stood for.** The
freeze-artifact suite asserted that no CSEL-000004 freeze artifact existed,
which was how "its baseline does not exist until CROUTE-0006 is written" was
expressed. That is now false by design. It is replaced by a stronger check that
outlives it and applies to every row: the executable `FABRIC_BEFORE` of each
artifact must be that step's own baseline. An artifact prepared before its
predecessor landed pins a superseded aggregate and fails there — checked
directly rather than by absence. Prose may still discuss an earlier baseline,
because every block explains which one it replaces; only the pin must be
current.

**A sabotage that never reached its target.** Two sabotages in the new suite
produced no refusal at all: over-escaped backslashes turned a line continuation
into a literal backslash argument, so the released command died under `set -e`
before its `||` handler could state a reason. The block still failed closed —
nonzero, no install, no record — but it failed *silently*, which is exactly what
the expected-refusal column exists to catch. Both are corrected and now state
their own refusal.

---

## 19. Tests

| suite | result |
| --- | --- |
| `test-fabric-freeze-artifacts.sh` | 241 PASS, 0 FAIL (193 → 241) |
| `test-fabric-freeze-gate-execution.sh` | 0 FAIL |
| `test-fabric-freeze-csel-000004-rehearsal.sh` | **new** — 127 PASS, 0 FAIL |
| `test-fabric-freeze-croute-0006-rehearsal.sh` | 0 FAIL (spent-ceremony mode) |
| `test-fabric-freeze-cinst-000006-rehearsal.sh` | 0 FAIL (spent-ceremony mode) |
| `test-capability-fabric.sh` | 0 FAIL |
| `test-fabric-route-head.sh` | 0 FAIL |
| `test-fabric-route-preflight.sh` | 0 FAIL |
| `test-fabric-preflight.sh` | 0 FAIL |
| `test-fabric-g11-integrity.sh` | 0 FAIL |
| `test-fabric-instance-admission-integrity.sh` | 0 FAIL |
| `test-fabric-admission-dependency-bound.sh` | 0 FAIL |
| `test-capability-invoke-current-eligibility.sh` | 0 FAIL |
| `test-capability-invoke-preflight.sh` | 0 FAIL |
| `test-capability-execution-payload-operation-contract.sh` | 0 FAIL |
| `test-static.sh` | 0 FAIL |
| `tools/dev/run-shellcheck.sh` | clean, exit 0 |

The regression loop that runs each committed gate against an expired and an
open window now detects **arity 4** and builds the fixture a selection gate
actually takes — body, advertisement, instance, route. This follows the
principle G11-BC-P established rather than extending a special case: the gate
says what it reads, and the test does not guess. The CSEL gate is proved to
refuse an expired window **and** proved not to be a brick.

The new suite is registered in `tests/host-only.manifest`,
`tools/dev/run-validation.sh` and `.github/workflows/ci.yml`. Validator totals
were re-measured by running it, not incremented.

---

## 20. Remaining authority window

```
CADV-000007 valid_until      2026-09-23T06:00:00-05:00
CINST-000006 admitted_until  2026-09-23T06:00:00-05:00
now                          2026-09-19T19:3x-05:00
remaining                    ~3 days 10 hours
```

Still to fit inside it: the CSEL-000004 freeze and write, then CINV-000003
Stages 0–3. Gate 1 refuses rather than extends when the window closes.

## 21. Actions NOT performed

```
/etc/kyri/fabric/csel-000004.json     NOT installed
CSEL-000004                           NOT written to production
CINV-000003                           NOT allocated
staging, invocation, execution        none
existing Fabric records               unaltered
Trust / Artifact authority            unaltered
Platform Evidence                     unaltered
runtime                               not reinstalled
sudoers                               not modified
Root Authority                        not mounted
ENG-0006 / TrustGateway cutover       not begun
```

## 22. Production no-mutation proof

Measured at the start of this checkpoint and again at the end, after every
rehearsal and every sabotage run:

```
/var/lib/kyri/fabric   f122e53034eeca45ce7b1d8ac5afdc9562a16a086757e203291a8ce1b018cefb   unchanged
/etc/kyri/fabric       81f86a8057227179c4ad798a016c01b2356b4d1e5b4f670db19d27fbe3f1d880   unchanged
capability-selection.seq                                          3   unchanged
/etc/kyri/fabric/csel-000004.json                                 absent
/var/lib/kyri/fabric/capability-selections/CSEL-000004.yaml       absent
CINV-000003                                                       not allocated
```

Trust, Platform Evidence, Artifact authority and the installed runtime match the
aggregates in §13. The rehearsal suite re-asserts every line above on each run.

## 23. Known risks

**The window is the binding constraint.** Roughly three days remain, with the
CSEL write and four CINV stages to go.

**The rehearsal is not the production run.** It substitutes two roots and shims
`sudo`. The privileged `install` as root and the real `/etc/kyri/fabric`
permissions are first exercised in the live ceremony.

**Gate 3 copies the whole production store per run.** Correct, and not cheap. At
six routes and six instances it is not a problem; on a larger store the freeze
would get slow.

**Gate 3 reads the persisted record with a small hand-written parser** rather
than a YAML library, deliberately, so the block does not depend on one being
installed. It is narrow by design — flat scalars and one-item lists, which is
all the engine writes for these fields — and it is executed against the real
record and seven corruptions rather than reasoned about. A future schema that
nested these fields would need it revisited.

**Route headship is checked through the engine, once, at freeze time.** If a
route were written between the freeze and the operator's separate write
authorisation, this ceremony would not see it. The write step is where that
window closes, and it is a separate authorisation by design.

## 24. Readiness for CSEL-000004

The artifact is committed, gated three times, rehearsed whole, and proved to
fail closed at every stage with a stated reason. The reviewed body has been
committed since G11-BC-Q and is unchanged. The baseline it pins is the current
production aggregate.

What remains is the reviewer's verification of the committed artifact, and then
a single operator freeze of CSEL-000004 — which installs one file and writes
nothing.
