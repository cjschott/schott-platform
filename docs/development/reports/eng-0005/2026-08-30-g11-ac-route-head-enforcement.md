# ENG-0005 G11-AC — Route-head supersession enforcement

**Date:** 2026-08-30
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `295ad73bf17a0d93bd527fff7cac8e12aeb805c7`
**Implementation commit:** `bffb3c1ec86d55d4330fa3a5b6d175892b7fc868`

A route may now supersede only the current head of its chain, and a request
class may have only one current route. Both fork paths are closed, both were
reproduced first, and neither is reachable through the released write path any
more.

The checkpoint also found a **second** way to fork the chain that the brief did
not name, and it is the one that produces the exact symptom the brief describes.

---

## 1. Starting authority

| Check | Observed |
| --- | --- |
| HEAD / origin | `295ad73b…`, clean, synchronized |
| G11-AB report | present, ancestor of HEAD |
| Installed runtime | 70 objects, `9cbfd043…33830` |
| Production routes | `CROUTE-0001`, `CROUTE-0002`; sequence `2` |
| Chain | CROUTE-0002 supersedes CROUTE-0001; unique head CROUTE-0002 |
| Both routes' class | CAPDEF-0001 / CCON-0001 / internal / local-only |

## 2. Why it became critical

G11-K recorded the gap as *observed behaviour* rather than a defect to fix,
because with one production route it was unreachable. Production has two, and
the first-invoke path now runs straight through it: CINST-000002 expires,
CROUTE-0002 permanently names only CINST-000002, so a renewed binding needs
CROUTE-0003 — a supersession written against exactly the state this let an
operator get wrong.

A fork is not recoverable through the released path. Routes are immutable,
nothing merges them, and selection refuses to resolve one because picking a
winner nobody chose would be the selector deriving its own authority. The class
would simply stop being routable.

## 3. Head semantics

Defined from the released selector rather than invented. `_resolve_route`
matches a **request class** exactly — capability, contract, accepted version
set, data classification, and locality — and `_chain_heads` reads the chain
backwards, since immutability means nothing points forward. A **head** is a
record nothing supersedes.

So the invariant a new route must satisfy is:

> Either it is the first route for its request class, or it supersedes the
> unique current head of that class.

Deliberately not "the latest route id". Two classes each holding one current
route is normal and must stay allowed.

## 4. RED — both forks reproduced

**Path A, the one G11-K named.** `CROUTE-0003 supersedes CROUTE-0001` while
`CROUTE-0002` already does:

```
FAIL: superseding a stale predecessor is refused (accepted/None)
FAIL: and the chain still has exactly one head (['CROUTE-0002', 'CROUTE-0003'])
```

It was accepted, and the chain forked.

**Path B, found here.** A second route for the same class naming **no
predecessor at all**:

```
SECOND NO-PREDECESSOR ROUTE: accepted   heads: ['CROUTE-0001', 'CROUTE-0002']
selection refuses: route-ambiguous-for-request-class
```

This one an operator trips by omission rather than by naming the wrong record,
and it is what actually produces `route-ambiguous-for-request-class`.

**A correction to the brief's framing.** Path A does *not* produce ambiguity. Two
records superseding one predecessor is a forked chain, and `_chain_heads`
refuses it as `route-chain-unreadable` before ambiguity is ever considered.
Ambiguity is Path B: two independent heads. Both leave the class un-routable;
they are simply named differently, and the tests now pin which is which.

## 5. Failure vocabulary

Reused rather than invented, because `admit_instance` already enforces this
invariant for bindings:

| Condition | Reason |
| --- | --- |
| Predecessor already superseded | `supersedes-already-superseded` — the existing constant, used verbatim by `admit_instance` |
| Class already has a current route | `request-class-already-routed` — new |
| Chain forked while reading | `route-chain-forked` — new, matching `advertisement-chain-forked` / `instance-chain-forked` |
| Chain unreadable while reading | `route-chain-incoherent` — new, matching the same family |

The brief suggested `route-predecessor-not-current-head`. I used
`supersedes-already-superseded` instead: it is the repository-conventional
equivalent the brief allows for, it is what `admit_instance` already returns for
the identical situation, and adding a second name for one invariant is how two
components start disagreeing about it. Nothing overloads `unresolved-reference`,
`route-chain-unreadable`, or `invalid-route-version` — all three still refuse for
what they always refused for, asserted in PART 3.

## 6. Implementation

In `create_route`'s `accept()`, using `_successors()` — the helper
`admit_instance` already calls, so routes stop being the outlier rather than
gaining a traversal of their own:

```python
route_links = _successors(store, "capability-route", "route_id",
                          REASON_ROUTE_FORKED, REASON_ROUTE_INCOHERENT)
current_heads = [record for record in store.list_records("capability-route")
                 if record.get("route_id") not in route_links
                 and ... class matched the way _resolve_route matches it ...]

if supersedes is not None:
    ...
    if supersedes in route_links:
        _refuse(REFUSED, REASON_SUPERSEDES_SUPERSEDED)
...
if supersedes is None and current_heads:
    _refuse(REFUSED, REASON_CLASS_ROUTED)
```

No second traversal, no refactor, no new import edge. `_chain_heads` lives in
`selection.py`, which already imports from `admission.py`, so reusing *that*
would have inverted the layering; `_successors` was already in the right module.

**Ordering matters and cost a correction.** The class check was first placed
beside the predecessor check, where it masked every other refusal — a route
naming an unresolvable candidate came back as `request-class-already-routed`
instead of `unresolved-reference`. It now runs after candidate validation, so
the cheaper structural answer still wins, which is what `admit_instance` does
with its own supersession check.

## 7. Linear history

Four routes, each superseding the head:

| Property | Result |
| --- | --- |
| CROUTE-0001 → 0002 → 0003 → 0004 | every successor accepted |
| Heads after four | `['CROUTE-0004']` — one, throughout |
| Back-links only | 0001 has none; 0002→0001; 0004→0003 |
| Versions | 1, 2, 3, 4 as declared |
| Identifiers | advance in order |
| Different request class | still declares its own first route |

## 8. Rehearsal parity

`create-route --preflight` shares the decision, so it inherits the rule:

- against a stale predecessor: refuses `supersedes-already-superseded`;
- against the head: `preflight`, would be accepted;
- after both: the sequence still reads `2` and the head is unchanged.

## 9. The renewal this unblocks

A fixture shaped like the state the renewal will actually be in — two routes,
the head naming the binding that expires, and a freshly admitted binding:

| Attempt | Result |
| --- | --- |
| `CROUTE-0003 supersedes CROUTE-0001`, candidates `[renewed]` | **refused**, `supersedes-already-superseded`, nothing written |
| `CROUTE-0003 supersedes CROUTE-0002`, candidates `[renewed]` | **accepted**, becomes the unique head, names the renewed binding |

So the write that the first-invoke renewal needs is now safe to make, and the
one that would have forked the chain is refused before it writes.

## 10. Fork recovery stays out of scope

Production is not forked. Nothing here repairs a store that is. The C6 ambiguity
fixture in `test-fabric-runtime.sh` used to build its fork through
`create_route`; it now forges the record directly into the store, which is
exactly the *damaged, tampered, or legacy* case `_successors` documents and the
case that assertion was always about. Selection still refuses it rather than
resolving it.

## 11. Suites that had pinned the old behaviour

Three, all updated to assert the fixed behaviour rather than being relaxed:

- **`test-fabric-route-preflight.sh`** — section 7 recorded "the predecessor need
  not be the chain head" as observed behaviour, with the G11-K report asking for
  a ruling. It now records that the gap closed: the first successor of a head is
  accepted, a second successor of the same predecessor is refused, and selection
  reads exactly one head.
- **`test-fabric-runtime.sh`** — asserted that identical route content under a
  new request identity produced a new route. For routes that is now a fork, so
  it asserts the refusal. This is a **genuine narrowing** and worth stating
  plainly: for routes, and only routes, a new request identity is no longer
  enough to justify a second current record. Superseding the head is how a class
  gets a new route.
- **`test-fabric-runtime.sh`** C6 ambiguity fixture — forges its fork directly,
  per §10.

## 12. Runtime generation impact

**None.** `tools/fabric/admission.py` is **not installed**. Generation 12's
Fabric surface is `eligibility`, `errors`, `evidence`, `identifiers`,
`inspection`, `models`, `request_identity`, `resources`, `store`,
`trust_adapter`, `validator` and `__init__` — `admission.py` and `selection.py`
are excluded, as they have been since Generation 11.

`GEN13_INCLUDE_REQUIRED = NO`. No G11-AC file enters Generation 13, and the
projected Generation-13 contents are unchanged from G11-AB: `rehearsal.py`
(CREATE) plus `store.py`, `evidence.py`, `package_resolution.py`,
`coordinator.py` and `cli.py` (REPLACE).

## 13. Regression and validation

| Suite | Result |
| --- | --- |
| Fabric route head (new) | 30 |
| Fabric route preflight | 71 |
| Fabric runtime | 8336 |
| Capability runtime | 1077 |
| Capability fabric | 538 |
| Invoke preflight | 36 |
| G11-X operation authority | 55 |
| G11-Y current eligibility | 49 |
| Fabric G11 integrity | 91 |
| Fabric preflight, instance-admission integrity, advertisement preflight | pass |

| Mode | Steps | Result |
| --- | --- | --- |
| Quick | **79/79** | passed, exit 0 |
| Full | **103/103** | passed, exit 0 |

Full rose by one and was re-measured against a real run; quick is unchanged
because the new suite runs in the full-mode block beside the route-preflight
suite it extends. `pre-commit run --all-files`: all five hooks. ShellCheck
0.9.0: pass.

**GitHub, commit `bffb3c1`:** CI `33318065232`, ShellCheck `33318065205`,
Semgrep `33318065196`, CodeQL, Gitleaks and Trivy — all success.

## 14. Production non-mutation

| Surface | Value, before and after |
| --- | --- |
| Fabric store | `bcb2559bdbc13ad760b5cb19e40d9327fc3c5e94b1988ae1e690159dcdcff15e` |
| Routes | `CROUTE-0001`, `CROUTE-0002` only |
| Route sequence | `2` |
| Installed runtime | 70 objects, `9cbfd043…33830` |

No CROUTE-0003, no CADV or CINST renewal, no CSEL, no CINV, no stage or invoke,
no runtime or sudoers install, no Trust, Evidence or image change.

## 15. What remains

**Carried forward untouched:** `WITHDRAWN_BINDING_ROUTE_HARDENING_PENDING=YES`
— G11-K's second finding, that a route may target a binding root whose later
lifecycle successor withdrew it, because `create_route` reads the named root's
frozen lifecycle state. It shares no boundary with the head invariant and was
not authorised here. The renewal path uses a freshly admitted binding, so it
does not depend on this being solved first.

Also unchanged: `ADMISSION_DEPENDENCY_BOUND_STRUCTURAL_HARDENING_PENDING=YES`,
`ELIG6_ADVERTISEMENT_HEAD_POLICY=UNRESOLVED`,
`SEMGREP_RULESET_POLICY=DYNAMIC`.

**The dependency this clears.** `NEXT_ROUTE_WRITE_BLOCKED_PENDING_HEAD_HARDENING`
is closed. CROUTE-0003 may be written when the renewal is authorised, provided
it supersedes CROUTE-0002.

**What still blocks first invoke**, unchanged from G11-AB and now the whole of
the remaining list:

1. **The OCI image authority** — the digest CIMP-000001 admitted appears in no
   committed authority, and the one image id the repository records is a
   different value. This is the next checkpoint.
2. G6 backend binding, once an image exists.
3. Coordinator deployment authority, with the privileged-helper ceremony.
4. Generation 13, publishing the invoke preflight.
5. The renewal itself: CADV-000004 → CINST-000003 → CROUTE-0003 → CSEL-000002.
