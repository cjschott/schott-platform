# ENG-0006-H7a — Initial-Envelope Ingestion

**Date:** 2026-11-16
**Host / account:** `schmain` / `kyri-dev` (uid 1001; groups `kyri-dev`, `users`)
**Branch:** `arch/eng-0006-health-runtime`
**Baseline HEAD:** `b5c964e8d526248ac0b5f55dca09003baccc74fa`
**Nature:** Implementation, **development only**. Fixture stores and fixture
approval directories. Nothing was pushed, merged, deployed or installed. No
connection to schai.
**Scope:** H7a, the first H7 increment (ruling O-9). **H7 is not complete.**

---

## 1. Rulings applied

| Ruling | As implemented |
|---|---|
| O-2 | `approval` is a required CHENV field, in the schema and the record model |
| O-3 | `tools/common/canonical_json.py` is a byte-identical copy of the Capability encoder. The Capability encoder and its installed closure are untouched (its sha256 is pinned in a test) |
| O-4 | T0. No Health module imports Trust, Fabric or Capability. Importing `tools.health.ingest` loads no other plane (asserted in a subprocess) |
| O-5 | Subjects with unverifiable, ambiguous or committed-unverified records are frozen. No recovery mechanism |
| O-6 | No succession claims |
| O-8 | K-1 recorded as a Trust-plane follow-up (§9). No Trust code changed |
| O-9 | H7a = C1 only; replacement refused by name until H7b |
| O-10 | `superseded_by` is a CHENV forbidden field. CHSTATE unchanged |
| O-12 | One canonical threshold spelling, with the schema grammar and the Python validator tested against each other |
| D-1 | The approval block below; `approval_digest` = sha256 of the canonical statement bytes; `approval_source` = `{authority, name}` only; no `approval_source.sha256`, no `trust_record_id` |
| D-2 | Narrow, file-scoped guard exceptions; `yaml` stays in `store.py` |
| Q-H7-5…8 | Library only; H7 allocates the identifier; V12 refuses a second envelope per subject; `publication` forbidden by name |

## 2. Commits

| Commit | Content |
|---|---|
| `9b6017e` | shared canonical JSON encoder and its suite; registration |
| `0264876` | CHENV schema and model: approval, supersession, canonical decimals; fixture updates; envelope doc |
| `d3cb070` | `HealthStore` store-wide lock; render, readback preview and scan helpers |
| `e242629` | `tools/health/ingest.py`; ingestion suite; import guard; static allowlists; registration |
| (this report) | this file |

## 3. What was built

### 3.1 The approval statement and the record

An operator publishes `<request_id>.json` into an approval directory. Its bytes
must be exactly `serialise()` of this object (keys shown unordered):

```
approval_statement_version: 1
approval_domain:            capability-health-envelope
operation:                  initial            # replacement: H7b
request_id:                 <Fabric rule without '/'; equals the file stem>
actor:                      <declared name>
approving_authority:        <declared name>
approved_at:                <offset-aware instant string>
canonicalisation:           kyri-strict-canonical-json/v1
digest_algorithm:           sha256
envelope:                   <CHENV content without envelope_id and approval>
```

The stored CHENV record carries every statement member plus
`approval_digest` (`sha256:` + sha256 of the file bytes, which coreutils
`sha256sum` reproduces) and `approval_source: {authority: health-approvals,
name: <request_id>.json}`. The statement is therefore recomputable, byte for
byte, from the stored record alone.

### 3.2 Interface

```python
ingest_envelope(store, *, request_id, approval_root, trusted_uid,
                allow_own_uid_fixture=False) -> IngestResult
```

`IngestResult(status, stage, reason, envelope_id, approval_digest,
record_code)`. `status` is `accepted`, `replayed`, `refused` or
`committed-unverified`. Refusals are returned, never raised, and carry
identifiers and codes only.

`trusted_uid` is supplied, never inferred. If it equals the process's own UID,
the call is refused unless `allow_own_uid_fixture` is set. That opt-in exists
because on schmain the fixture statements are necessarily owned by the test
user.

### 3.3 Validation stages

| Stage | Check | Refusal | Writes |
|---|---|---|---|
| params | a real `HealthStore`; integer UID; own UID needs the fixture opt-in | `parameters-invalid`, `trusted-uid-is-own-uid` | nothing |
| V1 | `request_id` pattern | `request-id-malformed` | nothing |
| V2 | `trusted_source`: regular, `nlink == 1`, owner = trusted UID, not g/o-writable, root not g/o-writable, ≤ 64 KiB, no symlink | `approval-unavailable` | nothing |
| V3 | `canonical_json.parse` | `approval-unreadable` | nothing |
| V4 | closed statement schema; versions; domain; `request_id` = stem; envelope carries no `envelope_id`/`approval` | `approval-schema-invalid`, `approval-version-unsupported` | nothing |
| V5 | `records.parse` of the would-be record under probe id `CHENV-0000` | `envelope-invalid` + `record_code` | nothing |
| V6 | operation ⇔ version ⇔ predecessor; replacement deferred | `approval-operation-mismatch`, `envelope-replacement-unsupported` | nothing |
| V7 | `serialise(parse(b)) == b` | `approval-not-canonical-bytes` | nothing |
| V8 | the statement rebuilt from the record is exactly `b` | `approval-not-reconstructable` | nothing |
| V9 | subject ∉ {actor, approving_authority} | `self-approval` | nothing |
| V10 | — (T0) | — | — |
| *lock* | store-wide `flock` | — | — |
| V11 | replay by `request_id`: same digest → `replayed`; different → conflict; two claimants → ambiguous; unverifiable claimant → frozen | `request-identity-conflict`, `request-identity-ambiguous`, `envelope-subject-frozen` | nothing |
| V12 | the subject has no envelope; frozen if any of its records fails verification or it has more than one; any unattributable record refuses all | `envelope-subject-exists`, `envelope-subject-frozen`, `envelope-store-unreadable` | nothing |
| V13 | the record survives the store's YAML serialisation (preview, no write) | `approval-roundtrip-unstable` | nothing |
| V14 | `allocate_id` | `allocation-refused` | sequence may advance |
| V15 | `write_record` (O_EXCL temp, fsync, link) | `write-refused` | **permanent gap** |
| V16 | `read_record` → parse → identity, equality, digest | status `committed-unverified` | **the record exists; subject frozen** |

"Verified", for a stored record, means: it parses, its filename equals its
`envelope_id`, and its `approval_digest` equals the sha256 of the statement it
restates. It does **not** re-open the retained statement file. That is
`verify`, in H7b.

### 3.4 Store additions

| Addition | Notes |
|---|---|
| `request_critical_section` | Restates the Fabric pattern: store-global `flock` on `sequences/request_identity.lock`, non-blocking first so contention is observable. The lock is created with the store, opened `O_NOFOLLOW` and checked by descriptor (regular, owner = euid, not g/o-writable). Re-entry through the same store object is refused |
| `_test_sync_point` | Production no-op seam: `lock_contended`, and `subject_checked` from ingestion |
| `render_record` / `preview_readback` | The exact text `write_record` commits, and its readback, with no write. Proven byte-equal to the committed file |
| `scan_records` | Every record file as (stem, payload). Unreadable, non-mapping and symlinked files come back as `None`, never as absent |

### 3.5 Schema and model

CHENV: `approval` required, with `approval_fields`, constants, patterns and
rules declared. `superseded_by` and `publication` are forbidden.
`supersedes` must be a CHENV identifier, present exactly when
`envelope_version > 1`. `condition_value_grammar` is
`^(0|-?[1-9][0-9]*(\.[0-9]*[1-9])?|-?0\.[0-9]*[1-9])$`. Four new refusal codes:
`decimal-not-canonical`, `supersession-inconsistent`,
`approval-operation-mismatch`, `self-approval`.

## 4. Decisions taken within the rulings

These are recorded so a reviewer can reverse any of them.

1. **The statement is canonical JSON, not YAML.** This follows preflight §9.3,
   which withdrew the cross-plane review's YAML statement. As a result V7 and
   V8 change meaning. There is no declared digest inside the statement to
   compare against. V7 is the canonical-bytes rule, and V8 checks that the
   statement can be rebuilt from the record.
2. **The record model enforces the V6 and V9 rules too.** A self-approving or
   operation-inconsistent CHENV is refused by `parse()` however it arrives.
   Ingestion reports those refusals under V6 and V9.
3. **O-12 applies to CHENV thresholds only.** CHDEG quoted conditions and
   observations keep the H1C grammar. The H1C assertion that `-0`, `+0`, `+1`,
   `1e3`, `.5`, `5.` and the exponent forms are acceptable *envelope*
   thresholds was reversed in `tests/test-health-records.sh` by this ruling,
   and the comment there says so.
4. **`request_id` is the Fabric rule without `/`.** It is also a file stem. The
   suite proves the Health rule is a strict subset of
   `tools.fabric.request_identity.validate_request_id`; the test imports the
   Fabric, Health does not.
5. **An unattributable record freezes all ingestion** (O-5, fail-closed). A
   record that cannot be parsed far enough to name a subject cannot be ruled
   out for any subject.
6. **Re-entry is refused per store object.** The Health guard forbids
   `threading`, so the guard cannot tell threads apart. One store object
   serves one governed operation at a time.

## 5. Tests

### 5.1 Results on schmain

| Suite | Baseline (`b5c964e`) | Final | Failures |
|---|---|---|---|
| `test-health-records` | 819 | 1006 | 0 |
| `test-health-binding` | 87 | 87 | 0 |
| `test-health-conditions` | 297 | 297 | 0 |
| `test-health-freshness` | 217 | 217 | 0 |
| `test-health-hysteresis` | 206 | 206 | 0 |
| `test-health-store` | 210 | 240 | 0 |
| `test-health-ingest` | — | 291 | 0 |
| `test-common-canonical-json` | — | 98 | 0 |
| `test-capability-health` (guard) | 647 | 746 | 0 |
| `test-capability-health-agreement` | 88 | 88 | 0 |
| `test-static` | 877 | 879 | 0 |
| `test-docs-static` | 994 | 994 | 0 |
| `test-platform-model` | 1003 | 1003 | 0 |
| `test-fabric-runtime` (incl. AC 25) | 8355 | 8355 | 0 |
| `test-capability-runtime` | not run | 1089 | 0 |
| `test-capability-execution-canonical-json` | not run | 33 | 0 |
| `test-occurrence-timeline` | 163 | 163 | 0 |
| `test-capability-execution-provisioning` | 32 | 32 | 0 |
| `test-developer-experience` | 140 + 1 fail | 140 + 1 fail | **1, environmental (§8)** |

The full regression and `tools/dev/run-validation.sh` were **not** completed on
schmain. The runner stops at step 1 because the pinned ShellCheck image is
absent (§8). Its step totals (151 quick / 176 full) were measured with a
scratch copy whose `run` only counts. That copy reported a baseline of 149/174
and the new totals 151/176, each matching its declared value.

### 5.2 Coverage against the authorization's required tests

| Required | Where |
|---|---|
| canonical JSON golden vectors, Capability equivalence | `test-common-canonical-json`: literal expected bytes, a pinned digest, the refusal corpus, a differential run over both modules, byte identity, the Capability file's sha256 pinned |
| CHENV schema/model agreement | `test-health-records` H7a sections: every approval constant and pattern compared with the schema; 34 decimal samples checked against **both** the schema regex and the model (negative zero, trailing zeros, leading zeros, exponents, sign, bare point) |
| approval source: ownership, permissions, links, filename, size, canonical bytes | `test-health-ingest` V2 (absent, symlink, hard link, group- and world-writable, directory, FIFO, > 64 KiB, writable root, symlinked root, foreign trusted UID, root as trusted UID), V4 (stem ≠ `request_id`), V7 (four non-canonical spellings) |
| self-approval and replay | V9 (actor, approver, no echo); V11 (replay, conflict, ambiguity, frozen replay) |
| allocation and permanent gap | V14 (exhausted sequence); V15 (debris → refused write; sequence stays at 1; next record is `CHENV-0002`) |
| locking and cross-process contention | store suite: L-6, L-7, L-8, L-9 (symlink, directory, FIFO, group-writable, foreign owner), L-12, cross-process exclusion. Ingest suite: L-3, L-4, L-5, L-7, L-10, L-11. All synchronised by events and named seams; timeouts bound failures only |
| crash and committed-unverified | V16 via a store that alters the temp file between fsync and link; the record exists, a retry and a new request for that subject are both frozen, other subjects proceed. Crash after link (`os._exit` in a child) resolves as a replay |
| import boundaries and Fabric independence | guard batteries; subprocess import check; AC 25 in `test-fabric-runtime` (20 assertions) |
| no `/var/lib/kyri/health` | asserted absent before and after by `test-health-ingest`; `/var/lib/kyri` does not exist on schmain |

### 5.3 Mutation checks

These were run by hand and are not part of any suite. Each mutant is killed,
judged by the suite's exit code. ingest.py: lock removed, V7, V8, V13, V16, conflict
check, subject-exists check, replacement guard, own-UID check, stem check.
records.py: approval validation, self-approval, the supersession rule, the
exit-threshold canonical check. store.py: the `flock` removed. One mutant (the
stem check) initially survived. A test was added (a renamed record freezes its
subject), and the mutant is now killed.

## 6. Trust and Fabric boundaries

- No Trust, Fabric or Capability source file was modified.
  `tools/capability/execution/canonical_json.py` still has sha256
  `11c76d97…f2e4`.
- Health runtime imports from outside the package are exactly three
  file-scoped pairs: `store.py:tools.common.immutable_store`,
  `ingest.py:tools.common.canonical_json` and
  `ingest.py:tools.common.trusted_source`.
- The Fabric lock and request-id rule are restated in Health, not imported.
  The suite checks the restated request-id rule against the Fabric original.
- The Fabric still works with Health unimportable (AC 25).

## 7. Known risks and limits

| # | Risk |
|---|---|
| K-a | **Fixture-only.** The production principals (root-owned statements, a `kyri-health` store owner) are H18. On schmain the trusted UID is the test user, which is why the opt-in exists. Nothing here proves the production configuration beyond the refusal of non-matching owners |
| K-b | **`flock` is advisory.** A direct writer is detected (its subject freezes), not prevented. L-11 asserts exactly that |
| K-c | **Frozen subjects have no recovery** (O-5). An operator ruling is needed if one ever occurs |
| K-d | **"Verified" does not re-open the retained statement.** A same-UID writer able to fabricate a self-consistent record (statement + matching digest) is not detected until H7b's `verify` checks the root-owned file |
| K-e | **G5 window margin.** `test-capability-execution-g5-{authority,build-context}` walk the last 40 commits touching `tools/{__init__.py,capability,common,provisioning}`. Their pinned commit moved from position 37 to 38; two more such commits will push it out of range. These suites skip on schmain and run only on schai. This fragility predates H7a, which used one of the margin's three commits |
| K-f | **ShellCheck has not run** on the new or edited shell files (§8). All pass `bash -n` |
| K-g | **`trusted_source` checks the approval root, not its ancestors.** Production must verify ancestors with `namei -l` as finalization §4.3 proposes |
| K-h | **`scan_records` uses `yaml.safe_load`.** A tampered record with duplicate keys is read last-wins. The digest check makes such a record unverifiable, which freezes its subject |

## 8. Environment gap (separate from H7a)

On schmain the pinned ShellCheck 0.9.0 image (`koalaman/shellcheck:v0.9.0`) is
not available to `kyri-dev`, and no `shellcheck` binary is installed. As a
result:

- `tools/dev/check-toolchain.sh` reports an error;
- `tests/test-developer-experience.sh` fails exactly one assertion (the
  toolchain check), at baseline and now;
- `tools/dev/run-validation.sh` stops at step 1.

PyYAML 6.0.1 also differs from the CI pin 6.0.3 (a warning only). No CI check
was weakened. Fixing this is a workstation change, `tools/dev/bootstrap.sh`
prints the commands, and it is not part of H7a.

## 9. Follow-ups

- **K-1 (O-8), Trust plane:** a store-backed `gateway.query()` cannot return
  `allowed=True`. `_from_runtime` passes no `capability`, `data_classification`
  or `target`, and `evaluate_scope` denies every unnamed dimension
  (cross-plane review K-1, `gateway.py:152-155`, `query.py:171-183`,
  `scope.py:138-150`). This should be raised with the Trust owner as a latent
  defect or an undocumented design property. No Trust code was changed.
- **H7b:** replacement (`operation: replacement`, W1–W5 head rules, L-1/L-2),
  `verify` (re-open each retained statement through `trusted_source`, compare
  sha256, one CHENV per statement), and removal of the
  `envelope-replacement-unsupported` guard. The mutation run already showed
  that without that guard a replacement for an empty subject would be accepted,
  so H7b must add the head rule in the same change that removes the guard.
- **CHSTATE `superseded_by`** (O-10, deferred).
- **Capability re-export** of the shared encoder, if ever wanted, belongs in a
  Capability-plane generation with its own installer review.
- **H18:** the `kyri-health` identity (O-13), the approval directory, and the
  approve and ingest helpers installed through finalization §4.3.

## 10. Reproducing the validation

```bash
cd ~/Projects/schott-platform
git log --oneline b5c964e..HEAD
for t in test-common-canonical-json test-health-records test-health-binding \
         test-health-conditions test-health-freshness test-health-hysteresis \
         test-health-store test-health-ingest test-capability-health \
         test-capability-health-agreement test-static test-docs-static \
         test-platform-model test-fabric-runtime test-capability-runtime \
         test-capability-execution-canonical-json test-occurrence-timeline \
         test-capability-execution-provisioning test-developer-experience; do
  bash "tests/${t}.sh" > "/tmp/${t}.log" 2>&1
  printf '%-45s rc=%s pass=%s fail=%s\n' "$t" "$?" \
    "$(grep -o 'PASS:' "/tmp/${t}.log" | wc -l)" \
    "$(grep -o 'FAIL:' "/tmp/${t}.log" | wc -l)"
done
cmp tools/common/canonical_json.py tools/capability/execution/canonical_json.py
sha256sum tools/capability/execution/canonical_json.py   # 11c76d97…f2e4
test ! -e /var/lib/kyri/health && echo absent
```

On a host with the pinned ShellCheck image, `tools/dev/run-validation.sh`
should run to completion and report 176/176 steps; this was not observed on
schmain.

---

=== REVIEW PACKAGE ===

**Task:** ENG-0006-H7a, initial-envelope ingestion (C1, T0), development only.

**Files Changed:** `tools/common/canonical_json.py` (new),
`tools/health/ingest.py` (new), `tools/health/records.py`,
`tools/health/errors.py`, `tools/health/store.py`, `tools/health/__init__.py`,
`platform-model/schemas/capability-health-envelope.schema.yaml`,
`docs/health/operational-envelope.md`, `tests/test-common-canonical-json.sh`
(new), `tests/test-health-ingest.sh` (new), `tests/test-health-records.sh`,
`tests/test-health-store.sh`, `tests/test-health-binding.sh`,
`tests/test-capability-health.sh`, `tests/test-static.sh`,
`tests/test-docs-static.sh`, `tools/dev/run-validation.sh`,
`.github/workflows/ci.yml`, and this report.

**Tests Executed:** §5.1, on schmain. All pass except the one known
environmental assertion in `test-developer-experience`.

**Commands Run:** the suites in §5.1; `bash -n` on every edited shell file;
the scratch counting copy of `run-validation.sh`; hand mutation runs;
`git add/commit`. No push, merge, deploy, sudo, Docker API call or schai
connection.

**Known Risks:** §7.

**Architecture Decisions:** none beyond the rulings; the decisions taken
within them are in §4.

**Questions for Reviewer:** whether §4.5 (one unattributable record freezes all
ingestion) is the intended reading of O-5; whether K-e's G5 window should be
widened before more `tools/common` or `tools/capability` commits land.
