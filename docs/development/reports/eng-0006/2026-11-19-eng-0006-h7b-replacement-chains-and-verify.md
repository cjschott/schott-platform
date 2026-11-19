# ENG-0006-H7b — Replacement Chains and `verify`

**Status:** implemented on schmain for development. Not deployed, not merged.
**Baseline:** `051ae54` (H7a). **Branch:** `arch/eng-0006-health-runtime`.
**H7 is not complete:** H18 (the `kyri-health` identity, the root-owned
approval directory and the operator helpers) remains, as does any
evaluation that consumes a head.

## 1. Rulings applied

| Ruling | Applied as |
|---|---|
| O-5 | An unattributable record blocks all ingestion (`envelope-store-unreadable`); a subject with an unverifiable record or a malformed chain is frozen (`envelope-subject-frozen`). No recovery path exists |
| G5 | The 40-commit window is replaced by an unbounded, cached search with the same answer and the same invariant (§5) |
| ShellCheck | Run locally with the pinned 0.9.0 from a scratch venv (§8). CI's ShellCheck workflow is unchanged |
| Autonomy | Commits made without per-commit approval |

## 2. Commits

| Commit | Scope |
|---|---|
| `2bcd3d0` | fix: H7a missed the Fabric suite's Health allowlist; CI run 44509124916 failed on it |
| `fb53c68` | H7b: replacement head rules, `verify`, tests, envelope doc |
| `089e821` | G5: deterministic reviewed-commit search (separate commit, tests only) |
| `f681c67` | this report |
| `1782855` | fix: scoped SC2034 in `tests/lib/reviewed-commit.sh` (CI ShellCheck run 44511873574) |
| `14f6147` | fix: launch-CLI isolation case tolerated no absent production handoff; GitHub runners now run that host-only suite (CI run 44511873587). Pre-existing, fails identically at `b5c964e` on schmain |

## 3. What was built

### 3.1 Replacement (C2)

The H7a guard (`envelope-replacement-unsupported`) is gone. It was removed in
the same commit that added the head rule. The H7a test that exercised the
guard now expects `envelope-subject-absent`.

At V12, inside the store-wide lock, ingestion lists every envelope once and:

| Order | Condition | Refusal |
|---|---|---|
| 1 | any record names no readable subject | `envelope-store-unreadable` (all subjects) |
| 2 | a record of this subject fails verification (W5) | `envelope-subject-frozen` |
| 3 | this subject's records break W1–W4 | `envelope-subject-frozen` |
| 4 | `initial`, and the subject has a record | `envelope-subject-exists` |
| 4 | `replacement`, and the subject has none | `envelope-subject-absent` |
| 5 | `supersedes` is not the head | `envelope-not-head` |
| 6 | version is not the head's plus one | `envelope-version-not-successor` |

V11 (replay) runs before V12, so a replayed replacement returns its own
record even after the head has moved. The `subject_checked` seam fires after
head selection for both operations, and is what L-1 and L-2 hold.

### 3.2 Chain rules

| Rule | Meaning | `verify` finding |
|---|---|---|
| W1 | exactly one member has no predecessor | `chain-root-not-unique` |
| W2 | every predecessor is a member of the same subject | `chain-predecessor-missing` |
| W3 | version = predecessor's + 1 | `chain-version-not-successor` |
| W4 | no predecessor named twice | `chain-fork` |
| W5 | every member verifies | `record-unverified`, `approval-statement-unavailable`, `approval-statement-mismatch` |

W1–W4 make the members a single path, so the head (the member that nothing
supersedes) is unique. A malformed chain has no head.

### 3.3 `verify`

```python
verify(store, *, approval_root, trusted_uid, allow_own_uid_fixture=False) -> VerifyReport
```

- **Read-only.** It takes no lock and writes, creates or repairs nothing. The
  suite checks that bytes, modes and mtimes of both the store and the
  approvals are unchanged, and that it runs while another holder has the lock.
- **Approval check.** For every self-consistent record, it re-opens the retained
  `<request_id>.json` through `trusted_source`, with the same checks as V2. The
  file's bytes must equal exactly the statement the record restates. This
  closes H7a risk K-d for anyone who runs `verify`.
- **Other findings.** It reports two records claiming one request, every
  broken rule, unattributable records (`blocked`), and the store's own
  `validate()` problems (`store-structural`, for example `.tmp` debris).
- **Unapproved records still count.** A record whose statement is missing
  still takes part in chain analysis, so a bypassing fork is reported as a
  fork.
- **Output.** `heads` names each subject that has a fully verified chain, and
  `frozen` lists every other subject.

Parameters and parameter refusals are the same as ingestion's.

## 4. Decisions taken within the contract

These are recorded so that a reviewer can reverse any of them.

1. **Ingestion's W5 is the record's own consistency, not a re-read of its
   predecessors' statements.** This is the V16 check, as the cross-plane
   contract states W5 ("V16 / `verify`"). A chain member whose retained
   statement was deleted does not block ingestion; `verify` reports it. The
   suite pins this limit so that it cannot change silently. Making ingestion
   re-open every member's statement is a small change, if wanted.
2. **One frozen reason for every malformed chain.** O-5 calls ambiguous and
   committed-unverified subjects frozen. Ingestion therefore reports
   `envelope-subject-frozen` for all of them and does not introduce
   `envelope-chain-ambiguous`; `verify` names the specific rule. This also
   keeps H7a's refusals unchanged.
3. **`envelope-subject-absent` is a new reason.** It covers a replacement for a
   subject with no envelope. The cross-plane list did not name this case.
   Without the reason, the case would be reported as `envelope-not-head`
   against a head that does not exist.
4. **A record superseding another subject's envelope freezes only its own
   subject.** It is not a member of the other subject's chain, which keeps
   its head.
5. **`verify` lives in `ingest.py`.** This follows the cross-plane change table
   ("`tools/health/ingest.py` (V1–V16) and `verify`"). It needs no new guard
   exception and shares one definition of "verified" with ingestion.

## 5. G5 correction

**What the window was for.** `test-capability-execution-g5-{authority,build-context,ceremony}`
build their fixtures from the *reviewed commit*: the newest ancestor of HEAD
whose packaged manifest (sha256 over `<sha256>  <path>` for every packaged
`.py`) equals the ceremony's pinned `MANIFEST_DIGEST`. It is not HEAD, because
source may lead the installed runtime. The ceremony suite also needs an
ancestor whose manifest *differs*, to prove the digest gate refuses it. The
40-commit bound was only a cost limit. It made the answer depend on how many
commits had landed since the review.

**Replacement.** `tests/lib/reviewed-commit.sh` (`ancestor_with_package
equal|differ <digest>`):

- It walks every ancestor that touched the packaged paths, with no bound.
- It computes the same manifest, but hashes each blob once, keyed by object
  id.
- Each suite still confirms the commit found with its own `manifest_at`.

The only remaining way to fail is for no ancestor to carry the package, which
is the invariant itself failing. The original comment preferred searching to
pinning a second copy of the commit, and that design choice is kept.

**Evidence (schmain):**

- The search finds `a574c50` (equal) and `9b6017e` (differ), the same commits
  the bounded walk found.
- Its manifest is byte-identical to `manifest_at` on 21 sampled commits,
  including the root commit.
- A full walk of all 85 packaged-path commits takes 0.45 s, against 3.6 s for
  the old bounded walk.
- In a scratch clone with five extra `tools/common` commits, the reviewed
  commit moves to position 43. The old window finds nothing; the new search
  still finds it.
- An unknown digest finds nothing.

The three suites are host-only and skip on schmain, so the end-to-end run
happens on schai.

## 6. Tests

`tests/test-health-ingest.sh`: 291 → **468** assertions.

| Required | Covered by |
|---|---|
| valid replacement chains | 3-record chain; record = statement; predecessors unchanged; two subjects share the series, not the head |
| invalid supersession | non-head, missing, foreign-subject, same and skipped versions, malformed reference, missing predecessor, wrong operation |
| missing or ambiguous heads | one case per W1–W4 and W5 (content and filename); rootless chain; cross-subject record |
| concurrent competing replacements | L-1 (threads, separate store objects), L-2 (processes) |
| duplicate request replay | sequential replay after head moved; L-4 for replacements |
| conflicting approval evidence | changed content, changed approver; L-5 for replacements |
| interrupted writes | crash before link (debris, competitor wins, retry not-head) and after (competitor not-head, retry replays) |
| unreadable and corrupt records | non-YAML, non-mapping, no subject, symlink; edited and renamed records |
| verification without modification | bytes, modes and mtimes of store and approvals unchanged; runs under a held lock |
| permanent gaps | write failure after allocation, `.tmp` debris; gaps are not findings |
| cross-process locking | L-2, L-4, L-5 (processes) |
| H7a behaviour preserved | every H7a assertion still runs; only the guard case changed its expectation |

Every refusal reason and every `verify` finding is exercised. Both are
asserted. Concurrency is synchronised by events and the store's seams. Bounds
are timeouts only.

**Mutation checks.** Fifteen hand-made mutants were run, each judged by the
suite's exit code:

- **Ingestion head rules (3):** no not-head; no successor-version; no
  subject-absent.
- **Chain rules (5):** W1, W2, W3 and W4 each dropped; a broken chain
  ignored.
- **verify (6):** no statement re-open; no byte comparison; no ambiguity
  check; no structural findings; unapproved subjects keep a head; not
  blocked.
- **Head selection (1):** head chosen by maximum version.

Fourteen were killed. The survivor, head-by-max-version, is **equivalent**: on
a path that satisfies W1–W4, the highest version *is* the head.

## 7. Known risks and limits

| # | Risk |
|---|---|
| K-a | **Fixture-only.** As in H7a, the production principals are H18 |
| K-b | **`flock` is advisory.** L-11 shows a bypassing fork is detected by V12 and `verify`, not prevented |
| K-c | **Frozen subjects have no recovery** (O-5) |
| K-d′ | **Ingestion does not re-open predecessors' statements** (§4.1). `verify` does. Nothing runs `verify` automatically; that is H18's ceremony and schedule (finalization M-10) |
| K-e | **G5 end-to-end runs only on schai**; schmain proved the search in isolation (§5) |
| K-f | **ShellCheck locally comes from a scratch venv** (`shellcheck-py` 0.9.0), not the pinned container image; CI's ShellCheck workflow is the authority and passed |
| K-g | **`verify` reads every retained statement**, up to 64 KiB each. The cost is linear in the number of envelopes |

## 8. Environment

The pinned ShellCheck image is still unavailable to `kyri-dev`. With
ShellCheck 0.9.0 placed on `PATH` from a scratch venv (nothing installed
system-wide), `tools/dev/run-validation.sh` ran to completion on schmain:
**176/176 steps, full mode, passed**. This clears the H7a condition. No suite
was added, so the step totals are unchanged (151 quick, 176 full).

GitHub Actions at `14f6147`: CI, ShellCheck, CodeQL, Gitleaks, Semgrep and
Trivy all succeeded.

## 9. Reproducing the validation

```bash
cd ~/Projects/schott-platform
git log --oneline 051ae54..HEAD
for t in test-health-ingest test-health-store test-health-records \
         test-capability-health test-capability-fabric test-static \
         test-docs-static test-fabric-runtime test-capability-runtime; do
  bash "tests/${t}.sh" > "/tmp/${t}.log" 2>&1
  printf '%-30s rc=%s pass=%s fail=%s\n' "$t" "$?" \
    "$(grep -c '^PASS' "/tmp/${t}.log")" "$(grep -o 'FAIL:' "/tmp/${t}.log" | wc -l)"
done
# every suite CI runs:
grep -oE 'bash tests/[a-z0-9_.-]+\.sh' .github/workflows/ci.yml | awk '{print $2}' \
  | sort -u | while read -r t; do bash "$t" >/dev/null 2>&1; echo "$? $t"; done
git diff --stat 051ae54 HEAD -- tools/trust tools/fabric tools/capability   # expect empty
test ! -e /var/lib/kyri/health && echo absent
```

## REVIEW PACKAGE

```
Task:                   ENG-0006-H7b (C2, W1-W5, L-1/L-2, verify) + G5 correction
Files Changed:          tools/health/{ingest,__init__}.py; tests/test-health-ingest.sh;
                        tests/test-capability-execution-launch-cli.sh (CI fix);
                        tests/lib/reviewed-commit.sh (new);
                        tests/test-capability-execution-g5-{authority,build-context,ceremony}.sh;
                        tests/test-capability-fabric.sh (H7a fix);
                        docs/health/operational-envelope.md; this report
Tests Executed:         all 160 CI-registered suites on schmain: 158 pass (21814
                        assertions; 46 host-only skips); 2 fail environmentally,
                        identically at baseline: developer-experience (ShellCheck
                        image) and launch-cli (/data/kyri/capability-handoff absent)
Commands Run:           §9; the G5 probes of §5
Known Risks:            §7
Architecture Decisions: §4
Questions for Reviewer: (1) should ingestion re-open predecessors' statements
                        (§4.1)? (2) is one frozen reason for every malformed
                        chain acceptable (§4.2)?
```
