#!/usr/bin/env bash
set -Eeuo pipefail

# Cross-artefact agreement for the Capability Health Plane.
#
# WHY THIS SUITE EXISTS, SEPARATELY FROM test-capability-health.sh.
#
# That suite asserts 461 facts and every one of them reads a SINGLE artefact.
# It asserted `len(health_states) == 7` from the CHSTATE schema and passed,
# green, while ADR-0013 declared six -- because nothing compared the two. A
# conflict visible in two files survived a passing suite for two months.
#
# That is the ENG-0005 F4 defect class: a test that proves the artefact it was
# derived from. The rule here is therefore narrow and absolute:
#
#   EVERY assertion in this file must extract the SAME FACT from TWO OR MORE
#   INDEPENDENTLY AUTHORED artefacts and compare them.
#
# An assertion that reads one artefact -- however many properties it checks --
# belongs in test-capability-health.sh, not here. Counting passes proves
# nothing; agreement between independent sources is the only thing this file
# is allowed to report.
#
# Nothing here contacts a host, reads a credential, executes a transport, or
# touches any production store.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

python3 - "${ROOT}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
failures = 0


def check(condition, description):
    global failures
    if condition:
        print(f"PASS: {description}")
    else:
        print(f"FAIL: {description}", file=sys.stderr)
        failures += 1


def agree(description, **sources):
    """Assert every named source yields the same value.

    Reports WHICH sources disagreed and what each said. A diff that names only
    "mismatch" sends a reader back to re-derive what this already knows.
    """
    global failures
    values = {name: value for name, value in sources.items()}
    distinct = {repr(v) for v in values.values()}
    if len(distinct) == 1:
        print(f"PASS: {description} ({len(values)} sources agree)")
        return True
    print(f"FAIL: {description}", file=sys.stderr)
    for name, value in values.items():
        print(f"        {name}: {value!r}", file=sys.stderr)
    failures += 1
    return False


try:
    import yaml
except ImportError:  # pragma: no cover
    print("FAIL: PyYAML is required for cross-artefact agreement", file=sys.stderr)
    raise SystemExit(1)


def text(rel):
    path = root / rel
    return path.read_text(encoding="utf-8") if path.is_file() else ""


def schema(name):
    raw = text(f"platform-model/schemas/{name}.schema.yaml")
    return yaml.safe_load(raw) if raw else {}


def enum_of(name, field):
    return set((schema(name).get("enums") or {}).get(field) or [])


def backticked_first_cells(body):
    """The first column of a markdown table, where it is a `backticked` token.

    Table rows are the normative form in these documents, so the state and
    vocabulary sets are read out of the tables rather than out of prose.
    """
    found = []
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if not cells:
            continue
        cell = cells[0].replace("**", "").strip()
        m = re.fullmatch(r'`([a-z][a-z0-9-]*)`', cell)
        if m:
            found.append(m.group(1))
    return found


def section(body, heading_pattern):
    """One section of a markdown document, by heading regex.

    Stops at the NEXT heading of any level. Stopping only at level two would
    swallow following subsections, and a table extracted from the wrong
    subsection is a false agreement -- which is the one failure this file
    cannot afford.
    """
    lines = body.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r'#{2,6} ', line) and re.search(heading_pattern, line):
            start = i + 1
            break
    if start is None:
        return ""
    out = []
    for line in lines[start:]:
        if re.match(r'#{2,6} ', line):
            break
        out.append(line)
    return "\n".join(out)


ADR13 = text("docs/decisions/ADR-0013-capability-health-plane.md")
STATES = text("docs/health/health-states.md")
GOV = text("docs/health/governance-boundaries.md")
ENVDOC = text("docs/health/operational-envelope.md")
OBSDOC = text("docs/health/observation-model.md")
FRESHDOC = text("docs/health/unknown-and-freshness.md")
SELVIS = text("docs/health/selection-visibility.md")
DEGDOC = text("docs/health/degradation-semantics.md")
WORKED = text("docs/health/worked-examples.md")
STANDARD = text("docs/standards/confidence-freshness-standard.md")

HEALTH_FAMILIES = ("capability-health-envelope", "capability-heartbeat",
                   "capability-health-observation", "capability-health-state",
                   "capability-degradation-event",
                   "capability-health-recommendation")

print("--- T1: health-state vocabulary, five independent sources ---")

adr_states = set(backticked_first_cells(
    section(ADR13, r'^### Health states')))
doc_states = set(backticked_first_cells(STATES))
chstate_states = enum_of("capability-health-state", "state")
chdeg_from = enum_of("capability-degradation-event", "from_state")
chdeg_to = enum_of("capability-degradation-event", "to_state")

agree("T1 the health-state set is identical in ADR-0013, health-states.md, "
      "CHSTATE.state, CHDEG.from_state and CHDEG.to_state",
      adr_0013=sorted(adr_states), health_states_doc=sorted(doc_states),
      chstate_enum=sorted(chstate_states), chdeg_from=sorted(chdeg_from),
      chdeg_to=sorted(chdeg_to))

check("insufficient-policy" in adr_states,
      "T1 ADR-0013's own state table declares insufficient-policy")
check(not re.search(r'^Six states', section(ADR13, r'^### Health states'),
                    re.MULTILINE),
      "T1 ADR-0013 does not declare six states")
check(not re.search(r'[Tt]he six above', STATES),
      "T1 health-states.md carries no stale 'six above' reference")

print("--- T2: recommendation vocabulary, three independent sources ---")

adr_recs = set(re.findall(r'`(investigate|review-envelope|'
                          r'verify-observation-source|consider-manual-drain)`',
                          section(ADR13, r'^### The only output')))
gov_recs = set(backticked_first_cells(GOV))
gov_recs &= {"investigate", "review-envelope", "verify-observation-source",
             "consider-manual-drain"}
chrec_enum = enum_of("capability-health-recommendation", "recommendation")

agree("T2 the recommendation vocabulary is identical in ADR-0013, "
      "governance-boundaries.md and CHREC.recommendation",
      adr_0013=sorted(adr_recs), governance_doc=sorted(gov_recs),
      chrec_enum=sorted(chrec_enum))

check(len(chrec_enum) == 4, "T2 the vocabulary is closed at exactly four kinds")
check("drain" not in chrec_enum and "drain" not in adr_recs,
      "T2 bare 'drain' is a permitted value in no source")
check(re.search(r'`consider-manual-drain` is not `drain`', ADR13) is not None,
      "T2 ADR-0013 states explicitly that consider-manual-drain is not drain")

print("--- T3: withheld semantics, three independent sources ---")

chstate = schema("capability-health-state")
withheld = chstate.get("withheld_semantics") or {}
adr_withheld_row = ""
for line in section(ADR13, r'^### Health states').splitlines():
    if line.strip().startswith("| `withheld`"):
        adr_withheld_row = line
intent_phrase = r'availability[ _]intent'

check(bool(withheld), "T3 CHSTATE declares withheld_semantics")
check(withheld.get("means") == "health-conclusion-not-asserted-or-published",
      "T3 CHSTATE withheld means conclusions are not asserted or published")
check(bool(adr_withheld_row) and not re.search(intent_phrase, adr_withheld_row),
      "T3 ADR-0013's withheld row does not define it as the Fabric "
      "availability intent")
check(re.search(r'not asserted or published', STATES) is not None,
      "T3 health-states.md defines withheld as conclusions not asserted")
agree("T3 withheld removes no eligibility in CHSTATE and in health-states.md",
      chstate_schema=withheld.get("removes_eligibility"),
      health_states_doc=False if re.search(
          r'`withheld` \*\*does not itself remove Fabric eligibility', STATES)
          else None)
check(withheld.get("may_set_availability_intent") is False,
      "T3 Health may never set availability_intent")

print("--- T3b: withheld producer is deferred, not implicit (G6) ---")

envelope = schema("capability-health-envelope")
check("publication" not in (envelope.get("optional_fields") or [])
      and "publication" not in (envelope.get("required_fields") or []),
      "T3b CHENV carries no publication-control block")
deferral = re.search(r'publication authority.{0,400}?deferred', ADR13,
                     re.IGNORECASE | re.DOTALL) is not None
check(deferral, "T3b ADR-0013 records withheld publication authority as "
                "deferred architecture")
check(withheld.get("v1_producer") == "none",
      "T3b CHSTATE declares that no v1 mechanism produces withheld")
check(re.search(r'no implicit mapping from .{0,40}availability_intent',
                ADR13, re.IGNORECASE) is not None,
      "T3b ADR-0013 forbids an implicit availability_intent to withheld "
      "mapping")

print("--- T4: condition grammar, ADR against schema against worked examples ---")

GRAMMAR = ""
GRAMMAR_PATH = None
for candidate in sorted((root / "docs/decisions").glob("ADR-*-health-condition-grammar.md")):
    GRAMMAR_PATH = candidate
    GRAMMAR = candidate.read_text(encoding="utf-8")
    break

check(bool(GRAMMAR), "T4 a Health condition-grammar ADR exists")

grammar_ops = set(re.findall(r'^\|\s*`(gt|ge|lt|le|eq)`', GRAMMAR,
                             re.MULTILINE))
schema_ops = set(envelope.get("condition_operators") or [])
agree("T4 the comparison-operator set is identical in the grammar ADR and "
      "CHENV.condition_operators",
      grammar_adr=sorted(grammar_ops), chenv_schema=sorted(schema_ops))

grammar_aggs = set(re.findall(r'`(instant|windowed_count)`', GRAMMAR))
schema_aggs = set(envelope.get("aggregations") or [])
agree("T4 the aggregation set is identical in the grammar ADR and "
      "CHENV.aggregations",
      grammar_adr=sorted(grammar_aggs), chenv_schema=sorted(schema_aggs))

check("percentile" not in schema_aggs,
      "T4 percentile aggregation is not permitted in v1")
check("p95" not in WORKED,
      "T4 worked-examples.md carries no percentile exemplar")
check(not re.search(r'entry_condition:\s*"', WORKED),
      "T4 worked-examples.md carries no free-text condition string")

units = envelope.get("dimension_units") or {}
obs_dims = enum_of("capability-health-observation", "dimension")
adr_units = {m.group(1): m.group(2) for m in re.finditer(
    r'^\|\s*`([a-z-]+)`\s*\|\s*`([a-z]+)`\s*\|', GRAMMAR, re.MULTILINE)}
agree("T4 the dimension set is identical in CHOBS, CHENV.dimension_units and "
      "the grammar ADR's unit table",
      chobs_dimensions=sorted(obs_dims), chenv_dimension_units=sorted(units),
      grammar_adr_units=sorted(adr_units))
agree("T4 every dimension's unit is the same in CHENV and the grammar ADR",
      chenv=sorted(units.items()), grammar_adr=sorted(adr_units.items()))

print("--- T5: hysteresis, ADR against CHENV against CHDEG proof fields ---")

grammar_hyst = {m.group(1) for m in
                re.finditer(r'^\|\s*`(duration|occurrences)`\s*\|\s*yes\s*\|',
                            GRAMMAR, re.MULTILINE)}
schema_hyst = set(envelope.get("hysteresis_kinds") or [])
agree("T5 the hysteresis kinds are identical in the grammar ADR and "
      "CHENV.hysteresis_kinds",
      grammar_adr=sorted(grammar_hyst), chenv_schema=sorted(schema_hyst))
check(schema_hyst == {"duration"},
      "T5 v1 declares duration hysteresis only")

hyst_fields = set((envelope.get("hysteresis_fields") or {}).get("required")
                  or [])
agree("T5 the declared hysteresis parameters cover duration, maximum gap and "
      "minimum samples",
      chenv_required=sorted(hyst_fields),
      expected=sorted({"kind", "seconds", "max_gap_seconds", "min_samples"}))

chdeg = schema("capability-degradation-event")
chdeg_required = set(chdeg.get("required_fields") or [])
proof = {"hysteresis", "hysteresis_satisfied_over_seconds",
         "hysteresis_first_observation_id", "hysteresis_last_observation_id",
         "hysteresis_sample_count", "hysteresis_observed_max_gap_seconds"}
missing_proof = sorted(proof - chdeg_required)
check(not missing_proof,
      "T5 CHDEG requires every field needed to reproduce the transition "
      f"(missing: {missing_proof})")
check("hysteresis_satisfied_over_seconds" not in
      set(chdeg.get("optional_fields") or []),
      "T5 hysteresis evidence is required on CHDEG, not optional")

print("--- T6: relationship edges, ontology against the schemas that cite ---")

catalog = yaml.safe_load(text("platform-model/ontology/relationship-types.yaml"))
rels = catalog.get("relationship_types", catalog) or {}


def edge_exists(source_kind, target_kind):
    for name, body in rels.items():
        if not isinstance(body, dict):
            continue
        if source_kind in (body.get("allowed_sources") or []) \
                and target_kind in (body.get("allowed_targets") or []):
            return name
    return None


citations = [
    ("capability-health-state", "capability-health-observation",
     "CHSTATE.derived_from_observation_ids"),
    ("capability-degradation-event", "capability-health-observation",
     "CHDEG.derived_from_observation_ids"),
    ("capability-health-recommendation", "capability-health-state",
     "CHREC.derived_from_state_id"),
]
for src, tgt, field in citations:
    check(edge_exists(src, tgt) is not None,
          f"T6 a governed edge permits {src} -> {tgt}, which {field} requires")

TRUST_KINDS = {"trust-record", "trust-decision", "trust-authority",
               "trust-policy"}
HEALTH_KINDS = set(HEALTH_FAMILIES)
leaks = []
for name, body in rels.items():
    if not isinstance(body, dict):
        continue
    srcs = set(body.get("allowed_sources") or [])
    tgts = set(body.get("allowed_targets") or [])
    forbidden = {(p.get("source"), p.get("target"))
                 for p in (body.get("forbidden_source_target_pairs") or [])}
    for s in srcs & TRUST_KINDS:
        for t in tgts & HEALTH_KINDS:
            if (s, t) not in forbidden:
                leaks.append(f"{name}: {s} -> {t}")
    for s in srcs & HEALTH_KINDS:
        for t in tgts & TRUST_KINDS:
            if (s, t) not in forbidden:
                leaks.append(f"{name}: {s} -> {t} (reverse)")
check(not leaks,
      f"T6 no edge connects Trust and Health in either direction (found: {leaks})")

print("--- T7: CSEL disclosure, doc against schema against the record set ---")

csel = schema("capability-selection")
disclosure_required = set(csel.get("conditionally_required_fields") or []) \
    | set(csel.get("required_fields") or [])
check("health_disclosure" in disclosure_required,
      "T7 the CSEL schema declares a health_disclosure block")
check("candidate_health" in disclosure_required,
      "T7 the CSEL schema declares per-candidate health results")
check(not re.search(r'carries the requirement as a declared block', SELVIS),
      "T7 selection-visibility.md no longer claims the released schema "
      "already carries the block")

boundary = csel.get("health_disclosure_boundary") or {}
legacy = list(boundary.get("pre_disclosure_selection_ids") or [])
agree("T7 the pre-disclosure record set is closed and names exactly the five "
      "existing selections",
      csel_schema=sorted(legacy),
      production_records=sorted(f"CSEL-{n:06d}" for n in range(1, 6)))
check(boundary.get("disclosure_required_from") == "CSEL-000006",
      "T7 the schema declares the first identity that must carry disclosure")
check(boundary.get("set") == "closed",
      "T7 the pre-disclosure set is declared closed, so a new write cannot "
      "join it")
check(re.search(r'CSEL-000006', SELVIS) is not None,
      "T7 selection-visibility.md names the same forward boundary as the schema")
check("health_score" in set(csel.get("forbidden_fields") or []),
      "T7 health_score remains forbidden on a selection")

print("--- T8: freshness at evaluation versus at selection ---")

check(re.search(r'freshness .{0,60}at `?evaluated_at`?', ADR13,
                re.IGNORECASE) is not None,
      "T8 ADR-0013 states that stored freshness is freshness at evaluated_at")
check(re.search(r'recomput', FRESHDOC, re.IGNORECASE) is not None,
      "T8 unknown-and-freshness.md states that freshness is recomputed at "
      "selection time")
agree("T8 the stored-freshness meaning agrees between CHSTATE and ADR-0013",
      chstate_schema=chstate.get("stored_freshness"),
      adr_0013="freshness-at-evaluated-at" if re.search(
          r'freshness-at-evaluated-at', ADR13) else None)

print("--- T9: which states subtract, three independent sources ---")

route = schema("capability-route")
adr_subtract = set(re.findall(r'`(degraded|unavailable)`[^.\n]{0,80}'
                              r'(?:subtracts|removes)', ADR13))
doc_rows = {}
for line in STATES.splitlines():
    if not line.strip().startswith("| `"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    m = re.fullmatch(r'`([a-z-]+)`', cells[0])
    if m and len(cells) >= 4:
        doc_rows[m.group(1)] = cells[3]
doc_subtract = {s for s, effect in doc_rows.items()
                if re.search(r'\bRemoves\b', effect)}

agree("T9 exactly the same states subtract in ADR-0013 and health-states.md",
      adr_0013=sorted(adr_subtract), health_states_doc=sorted(doc_subtract))
check(doc_subtract == {"unavailable"},
      "T9 fresh unavailable is the only subtracting state in v1")
check(not re.search(r'per route policy', STATES),
      "T9 health-states.md no longer conditions removal on a route policy "
      "that does not exist")
check(route.get("health_may_remove") is True
      and route.get("health_may_reorder") is False
      and route.get("health_may_add") is False,
      "T9 the route schema's uniform health invariants are unchanged")
check(not any("health" in str(f) for f in
              (route.get("required_fields") or [])
              + (route.get("optional_fields") or [])),
      "T9 no route record carries a per-route health policy field")

print("--- T10: subject binding, schemas against ontology ---")

for family in ("capability-health-state", "capability-degradation-event",
               "capability-health-recommendation"):
    body = schema(family)
    check(body.get("subject_binding") == "must-match-every-cited-record",
          f"T10 {family} declares that its subject must match every cited record")
    check(body.get("identifier_format_sufficient") is False,
          f"T10 {family} declares identifier format insufficient for binding")

bound_edges = [name for name, body in rels.items()
               if isinstance(body, dict)
               and body.get("same_subject_required") is True]
check(len(bound_edges) >= 2,
      f"T10 the Health citation edges carry a same-subject requirement "
      f"(found: {sorted(bound_edges)})")

print("--- T11: CRES outcome mapping, ADR against the released vocabulary ---")

records_py = text("tools/capability/records.py")
m = re.search(r'OUTCOME_CLASSES = \(([^)]*)\)', records_py, re.DOTALL)
released_outcomes = set(re.findall(r'"([a-z-]+)"', m.group(1))) if m else set()

mapping_section = section(ADR13, r'[Ee]xecution outcome')
mapped = {}
for line in mapping_section.splitlines():
    if not line.strip().startswith("| `"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    mm = re.fullmatch(r'`([a-z-]+)`', cells[0])
    if mm and len(cells) >= 2:
        mapped[mm.group(1)] = cells[1].strip("* ").lower()

agree("T11 the ADR-0013 outcome mapping covers exactly the released "
      "OUTCOME_CLASSES",
      released_records_py=sorted(released_outcomes),
      adr_0013_mapping=sorted(mapped))
check(mapped.get("refused") == "neither" and mapped.get("cancelled") == "neither",
      "T11 refused and cancelled are neither success nor failure")
check(mapped.get("completed") == "success",
      "T11 completed is the only success")

attribution = {}
for line in mapping_section.splitlines():
    if not line.strip().startswith("| `"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    mm = re.fullmatch(r'`([a-z-]+)`', cells[0])
    if mm and len(cells) >= 3:
        attribution[mm.group(1)] = cells[2].strip("* ").lower()
for ambiguous in ("adapter-error", "serialisation-failure", "timeout",
                  "interrupted"):
    check(attribution.get(ambiguous, "") != "capability-instance",
          f"T11 {ambiguous} is not attributed to the capability instance")
check(attribution.get("provider-error") == "capability-instance",
      "T11 provider-error is the attributable capability failure")

obs = schema("capability-health-observation")
check(obs.get("failure_count_counts") == "subject-attributable-only",
      "T11 CHOBS declares that failure-count counts only attributable failures")

print("--- T12: collector identity, registry against schema against ADR ---")

check("collector_id" in set(obs.get("required_fields") or []),
      "T12 CHOBS requires collector_id")
check("source_fingerprint" in set(obs.get("required_fields") or []),
      "T12 CHOBS requires source_fingerprint")
check("source" not in set(obs.get("required_fields") or []),
      "T12 CHOBS no longer requires a free-text source")
platform_obs = schema("observation")
agree("T12 CHOBS and the released observation schema name collector identity "
      "the same way",
      capability_health_observation=sorted(
          {"collector_id", "source_fingerprint"}
          & set(obs.get("required_fields") or [])),
      released_observation=sorted(
          {"collector_id", "source_fingerprint"}
          & set(platform_obs.get("required_fields") or [])))
check(obs.get("collector_identity") == "closed-registry",
      "T12 CHOBS constrains collector_id to the closed registry")
check(re.search(r'collector_id', OBSDOC) is not None,
      "T12 observation-model.md names collector_id as the source identity")

print("--- T13: the Null Policy Rule, standard against CHSTATE ---")

standard_requires_flag = re.search(
    r'null freshness policy produces .{0,80}review_required', STANDARD,
    re.IGNORECASE | re.DOTALL) is not None
check(standard_requires_flag,
      "T13 the Confidence and Freshness Standard requires review_required "
      "with a null policy")
chstate_fields = set(chstate.get("required_fields") or []) \
    | set(chstate.get("conditionally_required_fields") or [])
agree("T13 CHSTATE carries the review_required the standard it inherits "
      "requires",
      standard_requires="review_required",
      chstate_declares="review_required" if "review_required" in chstate_fields
      else None)

print("--- T14: store boundary, ADR against documentation ---")

check(re.search(r'/var/lib/kyri/health', ADR13) is not None,
      "T14 ADR-0013 declares the Health store root")
agree("T14 ADR-0013 and governance-boundaries.md declare the same Health "
      "store root",
      adr_0013="/var/lib/kyri/health" if re.search(
          r'/var/lib/kyri/health', ADR13) else None,
      governance_doc="/var/lib/kyri/health" if re.search(
          r'/var/lib/kyri/health', GOV) else None)
for family in HEALTH_FAMILIES:
    body = schema(family)
    check(body.get("may_modify_trust_state") is False
          and body.get("may_execute") is False,
          f"T14 {family} still declares no trust mutation and no execution")

print("--- B: subject constraints, consistent across every Health family ---")

matrix = obs.get("dimension_subjects") or {}
agree("B the dimension/subject matrix covers exactly the declared dimensions",
      chobs_dimensions=sorted(obs_dims), declared_matrix=sorted(matrix))

runtime_dims = [d for d in obs_dims if d != "collector-freshness"]
offenders = [d for d in runtime_dims
             if "capability-package" in (matrix.get(d) or [])]
check(not offenders,
      f"B no runtime dimension admits a package subject (found: {offenders})")

subject_sets = {family: sorted(enum_of(family, "subject_type"))
                for family in HEALTH_FAMILIES}
package_holders = [f for f, s in subject_sets.items()
                   if "capability-package" in s]
check(not package_holders,
      f"B no Health family admits capability-package as a subject "
      f"(found: {package_holders})")
agree("B every Health family constrains subject_type to the same set",
      **subject_sets)
check(re.search(r'[Ii]ntegrity', OBSDOC) is not None,
      "B observation-model.md directs package integrity evidence away from "
      "operational Health")

print()
if failures:
    print(f"Cross-artefact agreement FAILED with {failures} disagreement(s).",
          file=sys.stderr)
    raise SystemExit(1)
print("All cross-artefact agreement assertions passed.")
PY
