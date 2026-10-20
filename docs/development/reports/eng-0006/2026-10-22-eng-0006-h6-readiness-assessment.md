# ENG-0006-H6 — Implementation Readiness Assessment

**Date:** 2026-10-22
**Branch:** `arch/eng-0006-health-runtime`
**Base:** `900dcea` (H5C closeout), on published H5 `97feaa4`
**Nature:** Planning only. **No H6 code, no store, no change to `/var/lib/kyri`.**
**Status:** READY FOR REVIEW — with **three questions that should be ruled on before implementation**

---

## 1. Committed authority

| Source | What it fixes |
|---|---|
| `ADR-0013:531-532` | the root: "Health records live in their own immutable store at **`/var/lib/kyri/health`**, beside the Fabric and Trust stores and separate from both" |
| `ADR-0013:534-537` | why: "The separation is the mechanism, not a convention… 'Health cannot mutate Trust or Fabric state' would rest on application discipline rather than on filesystem authority. Discipline does not survive a bug" |
| `ADR-0013:540-546` = `governance-boundaries.md:125-131` | the direction matrix: Health writes its own store **Yes**; Health reads Fabric and Trust **only** through read-only adapters; the Fabric writes Health **Never**; Trust reads or writes Health **Never, in either direction** |
| `ADR-0013:93` | "Health history is append-only" |
| `ADR-0013:548-550` | envelope inputs are reviewed before they reach the store, "so that authoring a threshold and running the evaluator are not the same authority" |
| ENG-0006-D `:186-193` | component B1: purpose, in/out, permissions, trust boundary, failure modes, required tests, "**Production-safe:** yes **with fixture roots only**; the production root is created by H18" |
| ENG-0006-D `:195-200` | component B2: sequence allocation and identifier widths |
| ENG-0006-D `:388` | the H6 increment row — components **B1, B2** |
| ENG-0006-D `:562` | H6's required negative tests |
| ENG-0006-D `:19-36`, `:98-106` | the verified `ImmutableStore` facts |
| ENG-0006-D `:504`, `:746` | store-root creation is a root ceremony; `/var/lib/kyri/health` is created by **H18** |

---

## 2. The existing store base, verified by reading it

`tools/common/immutable_store.py` — everything below was read, not assumed.

| Facility | Verified |
|---|---|
| Subclass contract | declare `record_dirs`, `id_patterns`, `id_prefixes`, `id_widths`; `extra_dirs` defaults to `("sequences",)` |
| Modes | `DIR_MODE = 0o700`, `FILE_MODE = 0o600` at `:42-43` — exactly what ADR-0013 declares |
| Git-root refusal | `__init__(root, *, allow_repository_root=False, …)` at `:82` |
| Read without provisioning | `open_for_read(root, …)` at `:111`, constructing with `initialize=False` |
| Sequence allocation | `allocate_id` at `:141` — `flock(LOCK_EX)`, read-modify-write, `fsync`, and **refuses rollover** |
| Per-family width cap | `:148` `kind_maximum = min(10 ** width - 1, MAX_SEQUENCE)` — **so a 4-digit family caps at 9999 and a 6-digit one at 999999, correctly, with no subclass work** |
| Name collision | `:166` skips an identifier whose file already exists rather than reusing or overwriting |
| Atomic write | `write_atomic` at `:183` — temporary sibling, `fsync`, then link; `exclusive_temporary_create` at `:80` decides `O_EXCL` vs `O_TRUNC` |
| Base `validate()` | `:281-300` reads `record.get("id")` and reports `*.tmp` residue |

**A `HealthStore` is a small subclass, not a new subsystem.** The two properties
that make a fixture-only first increment safe are already there: the git-root
refusal, and `open_for_read` so that "reading must not change what it reports".

---

## 3. Store root and fixture-root behaviour

**Production root:** `/var/lib/kyri/health`, **created by H18 and not by H6.**

**Measured state of the production parent, and a correction to earlier
reporting.** `/var/lib/kyri` is `drwx--x--x root root` — **0711**, exactly as
ENG-0006-D `:504` declares. 0711 grants *traverse* but **not list**, so as the
`cschott` user:

- `ls -A /var/lib/kyri` fails with **Permission denied** (exit 2).
- `stat` still traverses, and `/var/lib/kyri/health` is **verifiably absent**,
  while `/var/lib/kyri/fabric` and `/var/lib/kyri/trust` both **exist** — which
  is the three-sibling layout ADR-0013 `:531-532` describes.
- The link count is 8, implying **six subdirectories**.

> **CORRECTION.** Several earlier increment reports and handoffs in this series
> rendered that `ls` as `/var/lib/kyri: ''` and described the directory as
> **empty**. That was wrong: it was **not listable**. The directory is not
> empty. The *claim that mattered* — that `/var/lib/kyri/health` does not exist,
> so no Health record can have been written — is unaffected, because `stat`
> needs only the execute bit and that check was always sound. For the same
> reason, `find /var/lib -name 'CH*'` returning zero was never evidence about
> the production store: `find` cannot descend into a 0711 directory either. The
> load-bearing evidence is the absence of the `health` directory itself.

**H6 uses fixture roots only.** Every test constructs its store under a
scratch directory, and `allow_repository_root=True` is the *only* way to place
one inside the repository — which H6 must never pass outside a deliberate
fixture asserting that refusal.

---

## 4. Record families and directory layout

Six families, from `tools/health/records.py`:

| kind | identifier | width | identity field |
|---|---|---|---|
| `capability-health-envelope` | `CHENV-NNNN` | **4** | `envelope_id` |
| `capability-heartbeat` | `CHBEAT-NNNNNN` | 6 | `heartbeat_id` |
| `capability-health-observation` | `CHOBS-NNNNNN` | 6 | `observation_id` |
| `capability-health-state` | `CHSTATE-NNNNNN` | 6 | `state_id` |
| `capability-degradation-event` | `CHDEG-NNNNNN` | 6 | `event_id` |
| `capability-health-recommendation` | `CHREC-NNNNNN` | 6 | `recommendation_id` |

Plus `extra_dirs = ("sequences",)`, giving the "six record dirs and six
sequences" ENG-0006-D `:193` requires.

**The directory NAMES are not declared anywhere — see Q-H6-1.** ADR-0013
declares the root; the D plan declares the *count*; no schema, ADR or Health
document names the subdirectories. `FabricStore`'s convention
(`tools/fabric/store.py`) is the pluralised kind name —
`capability-instance` → `capability-instances` — and following it would give
`capability-health-envelopes`, `capability-heartbeats`,
`capability-health-observations`, `capability-health-states`,
`capability-degradation-events`, `capability-health-recommendations`. That is a
**precedent, not an authority**, and it becomes a permanent on-disk layout.

---

## 5. Filesystem permissions and separation

Inherited unchanged: **`0700` directories, `0600` files**, matching ADR-0013.
No mode is overridden.

**Separation is by filesystem authority, not discipline.** The Health store is
a different root from `/var/lib/kyri/fabric` and `/var/lib/kyri/trust`, so a
Health writer holds no write path to either. Three independent checks should be
asserted, as ENG-0006-D `:193` requires "by module and by path":

1. **By path** — no Fabric or Trust root appears in any constructed path.
2. **By module** — H4B's guard already forbids `tools.fabric` and
   `tools.trust`, absolutely and in every import form.
3. **By direction** — the Fabric writing Health and Trust touching Health in
   either direction remain impossible; AC 25 continues to assert no Fabric
   module imports the Health package.

---

## 6. Append-only, atomicity and failure

**Append-only.** `ImmutableStore` exposes no update and no delete; the write
surface is `write_record` over `write_atomic`. H1's records are already frozen
objects, and CHSTATE declares `update_methods: none`, `delete_methods: none`,
`supersession: new-record-only`, `append_only_history: true`. H6 adds no
mutation path and should assert the absence of one by name.

**Atomic write.** Temporary sibling, `fsync`, then link. H6 should set
**`exclusive_temporary_create = True`**, as `FabricStore` does for the stated
reason that "a pre-existing temporary artefact is refused rather than
truncated" — the stricter of the two available behaviours.

**Partial write.** A crash leaves a `.tmp` sibling, and `validate()` must
report it rather than repair it. ENG-0006-D `:192` requires exactly that.

---

## 7. The `validate()` override — required, not optional

The base `validate()` reads `record.get("id")`. **No Health family uses an `id`
key**; each uses its own identity field (§4). Without an override, every Health
record would be reported as having an empty, non-matching identifier — the same
defect `FabricStore` already overrides at `tools/fabric/store.py:480`, for the
same reason.

`HealthStore.validate()` must, per family: read the family's identity field
rather than `id`; check it against that family's `id_pattern`; check the
filename matches the identifier; report `.tmp` residue; repair nothing; and
return problems in a deterministic order.

---

## 8. Identifier handling

`id_widths` must declare `capability-health-envelope: 4` and the other five at
6. Everything else is inherited: `allocate_id` is `flock`-serialised with
`fsync`, caps each family at `min(10**width - 1, MAX_SEQUENCE)`, **refuses
rollover** with "widening the identifier is a deliberate decision, not an
automatic rollover", and skips an identifier whose file already exists rather
than reusing a name.

**CHENV's 4-digit width needs no subclass work** — verified at
`immutable_store.py:148`. This was the one place a width mismatch could have
produced an identifier that failed its own pattern, and the base handles it.

---

## 9. H4B import-policy change required

H6 is the first increment needing a cross-plane import: **`tools.common`**, for
`ImmutableStore`. H4B deliberately did **not** pre-authorise it, so H6 must make
**two coordinated, reviewable edits** in `tests/test-capability-health.sh`:

1. `HEALTH_PERMITTED_PLANE_IMPORTS=()` → `("tools.common")`.
2. The policy pin currently asserts that set is **empty**; it must become an
   assertion of the **exact expected content**.

*RECOMMENDATION:* make the pin assert the exact permitted set rather than a
count, so a second permission cannot arrive later without changing a line that
names it. Editing only one of the two still fails the suite — that gate is
already proven by H4B's mutation P6 — and it should stay that way.

**Nothing else in the guard may move.** The forbidden-identifier sets, the
relative- and dynamic-import clauses, the six-module scan coverage and the four
closed module allowlists all stay as they are, and `tools.fabric` and
`tools.trust` stay absolutely forbidden. Adding `tools/health/store.py` also
needs a **seventh** entry in the four closed module allowlists, with the
intruder battery extended as H5 did.

---

## 10. Required tests

**RED before GREEN**, with the suite written first and shown failing against
the absent module, then a mutation battery. ENG-0006-D `:562` names the
negative tests; each is listed with the mutation that must be caught.

| Required test | Mutation that must be detected |
|---|---|
| a store root inside the repository is refused | the git-root refusal bypassed, or `allow_repository_root` defaulted to true |
| modes are `0700` / `0600` | either mode widened |
| `.tmp` residue is reported by `validate()` | the residue check removed |
| width exhaustion refuses rather than rolling over | the cap raised, or rollover permitted — **but see Q-H6-2** |
| no write path to Fabric or Trust, by module and by path | a Fabric or Trust path admitted into a constructed path |
| six record dirs and six sequence files created | a family dropped from `record_dirs` |
| `validate()` reads each family's identity field | the override removed, falling back to `record.get("id")` |
| a filename that disagrees with its identifier is reported | the filename check removed |
| `open_for_read` provisions nothing | `initialize=True` on the read path |
| no update or delete surface exists | a mutation method added |
| CHENV allocates 4 digits, the others 6 | `id_widths` dropped, defaulting CHENV to 6 |

Plus: deterministic `validate()` ordering, `counts()` per family, and no
production path anywhere in the module or its tests.

---

## 11. H6 versus H7, and the B2 boundary — needs a ruling

**This is a direct conflict between two authorising documents.**

- ENG-0006-D `:388` assigns H6 the components **"B1, B2"**, and `:562` lists
  **"width exhaustion"** among H6's required negative tests — which is B2
  behaviour.
- The H5C/H6-readiness brief states **"Do not implement B2 sequence
  allocation."**

Both cannot hold for the same increment. The consequences of each reading are
concrete, so this is not a drafting nicety:

| If B2 is **in** H6 (the committed plan) | If B2 is **out** of H6 (the brief) |
|---|---|
| `id_widths` and `id_prefixes` are declared and exercised | they may still be declared, but `allocate_id` is never called |
| "width exhaustion refuses" is testable, as `:562` requires | that required negative test cannot be written, and `:562` is unsatisfiable |
| H6 can create records end to end | H6 can only store records whose identifiers the caller supplies |
| H7's envelope ingestion has allocation available | H7 must either allocate or carry B2 itself |

*RECOMMENDATION:* resolve explicitly before authorising H6. Note that
`allocate_id` is **inherited, not written** — including it costs declaring
`id_widths` and testing exhaustion, which is small; excluding it leaves one of
the D plan's own H6 negative tests unsatisfiable. H7 is "Envelope ingestion,
versioning, supersession" (C1, C2) and has no natural claim on sequence
allocation.

---

## 12. Questions that should be ruled on before implementation

**Q-H6-1 — the store's directory names are undeclared.** ADR-0013 declares the
root and the D plan declares the count of six; no artefact names the
subdirectories. `FabricStore`'s pluralised-kind convention is the obvious
precedent but is not authority, and the choice becomes a permanent on-disk
layout that H18's production ceremony will create. *Not resolved here.*

**Q-H6-2 — the B2 scope conflict (§11).** The committed plan and the brief
disagree, and one of the D plan's required H6 negative tests depends on the
answer. *Not resolved here.*

**Q-H6-3 — `validate()`'s Health contract is undeclared in detail.** That an
override is *needed* is established (ENG-0006-D `:106`). What it must *report*
is not: the base reports identifier-pattern mismatches, filename disagreement
and `.tmp` residue, but nothing declares whether a Health `validate()` should
also check cross-family referential integrity — which ADR-0013's "Referential
integrity" section discusses for records, and which H2's `validate_citations`
already implements at the record layer. *Recommend scoping `validate()` to
structural problems only, matching the base and `FabricStore`, and leaving
referential integrity to H2 — but this should be stated, not assumed.*

### Carried forward, not resolved here

**Q-H5-1** (must be resolved **before H10**), **Q-H5-2**, **Q-H5-3**;
**Q-H4-1** through **Q-H4-3**; **Q-H3-1** through **Q-H3-4**, with **Q-H3-3**
(`measured_value` has no declared representation) **required before H9**;
**Q-H2A-2**, **Q-H2A-3**, **Q-H2-1**, **Q-H2-2**; the absence of any general
unknown-key rejection in the schemas; and **D1–D7**, with **D5 still blocking
heartbeat receiving** and **D6 deferred and actively refused**.

### Not blockers

Nothing in H6 depends on Q-H3-3, Q-H4-1 or any Q-H5 question: a store neither
interprets a measured value, nor classifies freshness, nor judges continuity.
H6 is blocked only by Q-H6-2 (scope) and would benefit from rulings on Q-H6-1
and Q-H6-3 before code is written rather than after.
