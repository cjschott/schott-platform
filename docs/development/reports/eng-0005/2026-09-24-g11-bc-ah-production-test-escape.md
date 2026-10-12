# G11-BC-AH — a test reached production, and the class it belongs to

**Date:** 2026-09-24
**Branch:** `arch/eng-0005-execution-transition`
**Starting authority:** `62b7f83cee6b8f223104c963809831f91d43a768`
**Engineer:** Claude (implementation)
**Status:** REVIEW REQUIRED — the harness is disarmed, the class is guarded, and the provenance architecture is prepared. Production was not mutated by this checkpoint.

---

## 1. The incident, verified by content

| check | result |
|---|---|
| `CINV-000001` previous state | `launch_authorized` (transition `.000002`) |
| `CINV-000001` now | `abandoned` (transition `.000003`) |
| `CINV-000001` terminal result | **absent** — no `CRES` names it |
| transition `.000003` | `{"cinv":"CINV-000001","previous":"launch_authorized","schema_version":1,"sequence":3,"state":"abandoned"}` |
| `CMUT-000000000012` | names `CINV-000001.000003`, `expected_sha256 28ffa1c7…`, matching the file exactly |
| `cadm` / `cmut` / transitions | `000004` / `000000000012` / 9 |
| occupancy | **0 of 2** |
| `CRES-000002` | `2d908b86…aebf`, unchanged |
| Fabric | `a87c2010…12e5`, unchanged |
| Generation 21 | installed, all seven digests |

`CADM-000004` records `actor: "x"`, `request_id: "y"`,
`recorded_at: 2026-09-20T20:00:00-05:00`, `reason: historical-incomplete-execution`,
`result_record_id: null`, `slot_released: true`.

### Reconstruction, by content

The incident's objects were found empirically — every file written at 06:40 —
not assumed. Removing exactly those six files and rewinding exactly those two
counters reproduces

`4bb33d50c102c5af44d0b9e4faeaf198ed49c3a5391272516b516f0b8395651f`

the accepted pre-incident aggregate, **exactly**. Nothing unexplained.

## 2. The escape path, proven statically

No part of this was reproduced by running the dangerous path.

1. **The fixture was built from the installed Generation-21 library.**
   `build_fixture` copies the live path set, then rewinds bytes.
2. **`succession_rewind` only touches pathnames the generation under test
   names.** `conclusion.py` is a Generation-21 CREATE, absent from Generation
   20's matrix, so it was neither removed nor rewound and survived into a tree
   claiming to be Generation 19.
3. **The Generation-20 installer refused it**: `the installed library holds 83
   objects, expected the Generation-19 81 plus 1 published helper module(s)`.
4. **The suite continued.** `fail()` increments a counter and returns — correct
   for read-only assertions, catastrophic when the next step is executable.
5. **The fixture's `cli.py` therefore stayed at Generation 19.**
6. **The breaking-change test dispatched the historical verb** —
   `abandon --cinv CINV-000001 --actor x --request-id y
   --recorded-at 2026-09-20T20:00:00-05:00
   --reason historical-incomplete-execution`, with **no `--store-root`**,
   expecting a usage error.
7. **Generation-19's `command_abandon` has no such flag** and resolves
   `CapabilityStore(CAPABILITY_RUNTIME_ROOT)` — `/data/kyri/capability-runtime`.
8. **The subprocess left the fixture and mutated production.**

The same suite ran safely at G11-BC-AF, when the host was still Generation 20:
the fixture's `--install` succeeded, `cli.py` reached Generation 20, and
Generation 20 refuses. **Installing Generation 21 is what armed it.**

### The distinction that actually matters

Not "fixture or not". How the root is resolved:

| form | verdict |
|---|---|
| in-process, module constant rebound | **safe** — the rebinding holds for the call |
| subprocess, explicit `--store-root` | **safe** — the root is named |
| subprocess, no explicit root | **DANGEROUS** — re-imports and gets the compiled-in production path, whatever the surrounding fixture says |

`test-capability-execution-launch-cli.sh` dispatches `authorise-launch`, which
resolves the compiled-in root — and is safe, because it rebinds
`C.CAPABILITY_RUNTIME_ROOT` in-process first. The 2026-09-20 incident and this
one are both the third form.

## 3. The disarm — four defects, all repaired

Not the one that fired. All four had to line up.

| defect | repair |
|---|---|
| fixture not historically correct | the rewind prunes every `tools/` object absent from the Generation-19 commit — scoped to the generation-managed subtree, because the library-root `kyri_exec_*.py` are published by helper ceremonies and are legitimately absent. Pruning on absence alone removed four of them and produced a 79-object tree the installer refused just as firmly. |
| count derivation moved with the host | it read "the live library less this generation's creates", and its own comment claimed that was derived so a later generation could not make it a lie — which is exactly what happened, both sides growing together while the tree was wrong. It now reads the installer's declared baseline plus helper-published modules, counted as the installer counts them. |
| failed publication accumulated | `--verify` and `--install` are **fatal**, and a publication guard refuses any fixture surface reached without publication. |
| historical mutating CLI dispatched | the claim is about a **parser**, so the parser is asked: `parse_args` in-process against the fixture's own `cli.py`, `SystemExit(2)` as evidence, **no handler ever runs**. |

The live-host target assertion is widened by **declaration, not tolerance**: an
installed digest is acceptable only if a later generation installer in this
repository names it as that object's target. It now reports
`admin.py` and `cli.py` as republished by Generation 21.

**79/79, and the production aggregate is unmoved across the run.**

## 4. The class guard

`tests/test-no-production-escape.sh` — static, reads the suites, runs no CLI.

- **no subprocess dispatch of a governed mutator without a named target**,
  across all **143** suites;
- **the closed verb set is complete** — every released CLI verb is classified,
  so a verb added later fails until someone classifies it;
- **the 2026-09-24 shape is absent** by name;
- **a fatal publication failure is required** of any installer suite that both
  publishes a fixture and dispatches a CLI inside it — narrow on purpose, since
  suites that merely *import* inside a fixture cannot resolve a runtime root.

**Sabotage-tested.** Reinstating the exact 2026-09-24 line makes it fail, naming
file and line; removing it makes it pass.

### The audit found one more live instance

`test-capability-mutation-target-explicit.sh` dispatched `abandon` with no
`--store-root` as a subprocess and relied on the current CLI refusing — true
today, one generation away from not being. It now asks the parser. Its fixtures
are also rewound past the incident, because a copy of production carries the
`CINV-000001` abandonment and the released code refuses a fresh one as a
conflicting repeat.

### Classification of every historical dispatch

| suite | form | verdict |
|---|---|---|
| `launch-cli` (`authorise-launch`) | in-process, constant rebound to a fixture | EXPLICIT_FIXTURE_TARGET |
| `stage-0 rehearsal` (`invoke`) | subprocess, `--store-root "${FIX}/runtime"` | EXPLICIT_FIXTURE_TARGET |
| `mutation-target` (`abandon`, `correct-provenance`) | subprocess, `--store-root` fixtures | EXPLICIT_FIXTURE_TARGET |
| `mutation-target` no-target case | **was** subprocess with no root | repaired → parser-only |
| `cinv-000002 reclamation` | `grep` over ceremony text | READ_ONLY_SAFE |
| generation 5/6/15–19 installers | in-fixture `import` only, no dispatch | READ_ONLY_SAFE |
| generation 20 installer | **was** subprocess, historical CLI, no root | repaired → parser-only |

No `HISTORICAL_IMPLICIT_TARGET` and no `UNKNOWN` remain.

## 5. The effect is truthful; the authority is not

Evidence for retaining the lifecycle effect:

- previous state `launch_authorized` — an eligible source state;
- **no terminal result**, verified by scanning every `CRES`;
- the released rule `_REASON_REQUIRES_RESULT[historical-incomplete-execution] = False`
  means the category *requires* no result, and the released code validated that
  against the store before writing. The reason is **true**, not merely plausible;
- `ABANDONED` is terminal and holds no slot;
- no result was fabricated — `result_record_id: null`;
- no historical evidence was rewritten.

This accepts the **lifecycle truth**. It accepts nothing about the authority.

### Provenance: the existing model cannot record it

Measured, not assumed:

```
CORRECTABLE_FIELDS : ['actor']
actor        = 'x'                          correctable: True
request_id   = 'y'                          correctable: False
recorded_at  = '2026-09-20T20:00:00-05:00'  correctable: False
```

Two of the three false assertions **cannot be recorded at all**. The structure
is otherwise right — corrections deduplicate on `(subject_cadm,
disputed_field)`, so one record per field is already the model's shape.

**ADR-0018** widens the closed set to `{actor, request_id, recorded_at}` and adds
one finding, `assertion-synthetic`, for a value never asserted by any authority.
`reason` is deliberately excluded: it is a claim about what happened rather than
who claimed it, and here it is true.

The `recorded_at` matters more than the others. It is backdated **four days**, to
a literal that lived in the test — placing the action before the Generation-20
publication that was meant to make it impossible.

**The generation is not built.** Widening the set changes `provenance.py`, a
Generation-22 object, and the shape of a closed-set widening is the reviewer's
to ratify first — the same judgement that preceded ADR-0017.

## 6. Verification

Production compared against `35e33adc…651f` **before and after every executable
group**. Unmoved throughout.

| Run | Result |
|---|---|
| No-production-escape guard (new) | **4/4**, and sabotage-tested |
| Generation-20 installer (repaired) | **79/79** |
| Mutation-target-explicit | **32/32** |
| Abandonment | **26** · Provenance correction | **22** |
| Lifecycle **45** · Mutation **38** · Capacity **31** · Conclusion **33** | all passing |
| Generation-21 `--verify-source` | passed, unaffected |
| `test-static` / `test-developer-experience` | clean |
| ShellCheck (CI-pinned 0.9.0) | clean, rc 0 |
| GitHub CI | **6/6 success** at `9020cfa` |

Fabric remains expired and was **not renewed**; no authority gate was weakened.
The spent ceremonies G11-BC-AG reported still refuse the evolved host, and were
not made executable again.

## 7. Outstanding

**The operator container observation for `CINV-000001` has not been provided,
and I have not substituted anything for it.** The governed Podman store needs
elevation this account does not have. Lifecycle records show no container could
be expected — `CINV-000001` never reached `created` — but §C is explicit that
absence from lifecycle records is not the observation, and I have not treated it
as one. `CINV000001_CONTAINER` is reported as **not observed**, not as absent.

To close it:

```
! sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
```

## 8. What I did wrong

I ran a sweep of every capability suite against a host whose generation had
moved, without asking what any of them would execute. One of them dispatched a
historical CLI whose target was a compiled-in production path. The checkpoint I
was working under said "no production mutation of any kind", and I caused one.

The repairs above are aimed at the class rather than the instance, because the
instance was never the interesting part: the same shape existed in a second
suite, and would have existed in the next generation's suite by inheritance.
What made it fire was a host at Generation 21 — a condition that recurs at every
future generation.
