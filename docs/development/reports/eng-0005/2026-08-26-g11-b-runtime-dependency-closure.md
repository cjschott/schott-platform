# ENG-0005 G11-B — Installed Capability Runtime Fabric Dependency Closure

**Date:** 2026-08-26
**Checkpoint:** G11-B
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Close G11-B: the installed Capability Runtime cannot satisfy its
`tools.fabric` dependency from the installed runtime surface. Determine the
exact dependency graph first, then make the smallest governed
installation-surface correction that lets the installed execution path use the
existing Fabric implementation without depending on the repository checkout.

**Outcome: ACCEPTED. Dependency class: LEGITIMATE_RUNTIME_DEPENDENCY.**

The defect is real and was reproduced deterministically: three installed modules
— `fabric_evidence`, `coordinator` and `cli` — cannot import when
`/opt/schott-platform` is off `sys.path`. The installed runtime was not
self-contained; it borrowed a checkout.

The closure was **computed from the source, not assumed**, and is narrower than
the reviewer prior anticipated: **eight modules plus the package initialiser**.
It does **not** include `admission.py`, `cli.py`, `selection.py`,
`eligibility.py` or `trust_adapter.py`, and reaches **nothing** in `tools.trust`.
Capability consumes read-only inspection (C8) and the record models it reports
with — not the governed write path — so the write path is not installed.

A disposable Generation-11 root proves the closure is complete: imports resolve,
the Capability→Fabric path runs end to end, every resolved module comes from that
root, and a negative control fails for exactly the right reason.

**Generation 11 was not installed. Generation 10 was not modified. No production
state changed.** Full validator **93/93** from the clean implementation commit.

**Two adjacent defects were found and fixed** (§12): the developer-experience
CI-parity check could not see suite names containing digits — which is why
`test-fabric-g11-integrity.sh` was never registered in CI in G11-A — and both
suites are now registered.

---

## 2. Starting authority

| Gate | Observed | |
|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | PASS |
| HEAD | `18abf0f127ce89373bae00a8574bf30ce3c1cde2` | PASS |
| G11-A commits present | `2d6d2a0e`, `c35ccd8c`, `305f84aa`, `18abf0f1` | PASS |
| Worktree | clean | PASS |
| Installed generation | `CGEN-000000000001`, digest `fc9a3ec3…0163` | PASS |
| Generation 11 | not opened, not installed; `tools/fabric` absent from the library root | PASS |
| `CADV-000001` | `cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195` | PASS |
| CADV count | 1; no `CADV-000002` | PASS |
| CINST | 0; `capability-instance.seq` absent | PASS |
| CROUTE / CSEL | 0 / 0 | PASS |
| Root Authority | unmounted | PASS |

```
Fabric   7780dacf274f57e000a0ab93208e7b89a6b1933ed2c181cec5f79a49119ab072
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
Artifact 63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b
```

**`CADV-000001` freshness at checkpoint start: FRESH**, 20.81 h remaining
(`valid_until 2026-08-27T14:13:53-05:00`). **Informational only** — nothing in
this checkpoint reads, evaluates or depends on it.

The full validator was run at the start of this checkpoint's work and passed,
consistent with the ruling recorded in §13.

---

## 3. The exact installed Generation-10 surface

`LIBRARY_ROOT=/usr/lib/kyri/python`. **48 Python objects**, reconstructed from
the installed tree rather than inferred:

```
kyri_exec_quota.py                    tools/capability/execution/handoff.py
kyri_exec_transition.py               tools/capability/execution/image_store.py
kyri_exec_transition_action.py        tools/capability/execution/implementation_authority.py
kyri_exec_verify.py                   tools/capability/execution/launch.py
tools/__init__.py                     tools/capability/execution/lifecycle.py
tools/capability/__init__.py          tools/capability/execution/mutation.py
tools/capability/cli.py               tools/capability/execution/package_contract.py
tools/capability/coordinator.py       tools/capability/execution/payload.py
tools/capability/errors.py            tools/capability/execution/profile.py
tools/capability/evidence.py          tools/capability/execution/protocol.py
tools/capability/execution/__init__.py        tools/capability/execution/quarantine.py
tools/capability/execution/adapter.py         tools/capability/execution/quota.py
tools/capability/execution/admin.py           tools/capability/execution/snapshot.py
tools/capability/execution/authorisation.py   tools/capability/execution/state.py
tools/capability/execution/backing_store.py   tools/capability/execution/types.py
tools/capability/execution/canonical_json.py  tools/capability/execution/verification.py
tools/capability/execution/capacity.py        tools/capability/execution/worker.py
tools/capability/execution/cleanup.py         tools/capability/fabric_evidence.py
tools/capability/execution/collector.py       tools/capability/identifiers.py
                                              tools/capability/inspection.py
tools/common/__init__.py                      tools/capability/invocation_identity.py
tools/common/containment.py                   tools/capability/package_resolution.py
tools/common/immutable_store.py               tools/capability/records.py
tools/common/trusted_source.py                tools/capability/store.py
tools/common/yaml_strict.py
```

Plus `/usr/libexec/kyri-exec-{quota,transition,verify}`,
`kyri-exec-worker.py`, `kyri-exec-verify-worker.py`.

**`tools/fabric` is not present. It never was.**

---

## 4. RED reproduction

The **entire** Capability→Fabric surface is one import:

```
tools/capability/fabric_evidence.py:42
    from ..fabric.inspection import (STATUS_REPORTED, inspect_records)

tools/capability/coordinator.py:26
    from .fabric_evidence import verify_selected_evidence
```

Reproduced with the repository off `sys.path`, against the **installed** tree
(read-only; production was not modified to obtain RED):

```
tools.capability.fabric_evidence   ModuleNotFoundError: No module named 'tools.fabric'
tools.capability.coordinator       ModuleNotFoundError: No module named 'tools.fabric'
tools.capability.cli               ModuleNotFoundError: No module named 'tools.fabric'
tools.capability.inspection        IMPORT OK
tools.capability.evidence          IMPORT OK
```

And the dependency resolves today **only** via the checkout:

```
with /opt/schott-platform on path: IMPORT OK
tools.fabric.inspection resolved from: /opt/schott-platform/tools/fabric/inspection.py
```

The permanent RED lives in the new suite and runs against a **copy** of the
installed tree, so the reproduction never depends on the installed tree staying
broken:

```
PASS: as installed, tools.capability.fabric_evidence cannot resolve tools.fabric without the checkout
PASS: as installed, tools.capability.coordinator cannot resolve tools.fabric without the checkout
PASS: as installed, tools.capability.cli cannot resolve tools.fabric without the checkout
```

---

## 5. Dependency graph

Transitive closure of `tools.fabric.inspection`, computed by walking the AST of
each module's imports rather than by reading the package listing:

```
installed  tools.common.immutable_store      ← Generation 10 already installs this
MISSING    tools.fabric.errors
MISSING    tools.fabric.evidence
MISSING    tools.fabric.identifiers
MISSING    tools.fabric.inspection
MISSING    tools.fabric.models
MISSING    tools.fabric.request_identity
MISSING    tools.fabric.store
MISSING    tools.fabric.validator

total 9, missing 8

tools.fabric.admission  in closure: False
tools.fabric.cli        in closure: False
tools.fabric.selection  in closure: False
tools.trust.*           in closure: NONE
```

Plus `tools/fabric/__init__.py`, which Python executes on any submodule import
and which must therefore be installed: **9 files**.

**Both package initialisers are docstring-only** — no imports, no statements —
so importing a submodule pulls in nothing beyond the closure.

**Non-`tools` dependencies:** the standard library (`fcntl`, `hashlib`, `hmac`,
`json`, `os`, `pathlib`, `re`, `stat`, `dataclasses`, `datetime`, `typing`,
`contextlib`, `collections.abc`, `types`) and **`yaml`**, which is already
present at `/usr/lib/python3/dist-packages/yaml`. Nothing new is required.

---

## 6. Architecture ruling — A, not B

**Classification A: a legitimate runtime dependency that belongs in the
installed Capability Runtime closure.**

The reviewer prior favoured packaging, and it is followed — but on evidence, not
deference. The evidence for A:

1. **What Capability imports is C8: read-only inspection.**
   `tools/fabric/inspection.py` states it in its own docstring — *"It looks, and
   it reports… **Not one byte, under any input.** An absent store is reported as
   absent rather than built and then described. A malformed record is described
   rather than mended."* Capability legitimately needs to read Fabric records to
   verify the evidence behind a selection; that is what `verify_selected_evidence`
   is for.
2. **The closure excludes the governed write path.** `admission.py` — the module
   that declares, admits, registers and routes — is **not** reachable from
   `inspection`. Neither is `cli.py`, `selection.py`, `eligibility.py` or
   `trust_adapter.py`. Installing the closure does not install the ability to
   mutate the Fabric.
3. **It reaches nothing in `tools.trust`.** The plane boundary holds: Capability
   does not acquire a Trust surface by acquiring a Fabric read surface.
4. **A narrower interface would be a second implementation.** The alternative
   under B would be a Capability-local reader of Fabric records — which is
   exactly the duplication ADR-0012 and `inspection.py` warn against
   (*"A second copy of the validation rules here would drift from the first, and
   two answers to 'is this store sound' is one too many"*). B would trade a
   clean, already-reviewed read-only interface for a divergent copy.

**No evidence was found for B.** Nothing in the closure grants mutation or
control capability, and no established plane boundary is crossed.

### Importable is not authorised — stated explicitly

The brief asked for this distinction to be documented, and it is the crux of the
ruling.

**Installing Python modules makes code *resolvable*. It does not grant:**

- **filesystem authority** — every store constructor requires an explicit root
  and explicit `expected_uid`/`expected_gid`; `FabricStore` raises
  *"a store root must be supplied explicitly"* rather than defaulting to
  anything, and verifies ownership of what it opens;
- **Trust standing** — nothing in the closure reads or writes the Trust plane;
- **operator input** — the approved-directory reader lives in `cli.py`, which is
  not installed;
- **permission to mutate** — see §10, where the filesystem permissions are shown
  to deny the runtime identity outright.

A module that *could* write, held by a process that cannot reach the bytes and
was never handed a root, writes nothing. Authority in this platform is
filesystem ownership plus explicitly supplied roots plus governed operator
input — not Python import reachability.

---

## 7. Minimal transitive install set

Nine files. Not the repository, not the package — the closure.

| # | Source | Operation | SHA-256 |
|---|---|---|---|
| 1 | `tools/fabric/__init__.py` | CREATE | `e761edea8dfe6df49080d58441f41b48558c335d82a309ca12e7cd271bdf6230` |
| 2 | `tools/fabric/errors.py` | CREATE | `ddc6a7654ca5e38aa828070bd5400a7bc93bee48db231494e235ff8d9c1e954a` |
| 3 | `tools/fabric/identifiers.py` | CREATE | `e523096cb23864d0970ccd038c8ad1532ca0a245b268a51838195c6328b63226` |
| 4 | `tools/fabric/models.py` | CREATE | `c6e0ce6d4b70a077072794ffd2cde548ea3b031c061e108eb37769dccd5d657b` |
| 5 | `tools/fabric/request_identity.py` | CREATE | `b0ff8b1dde147d186b0675b55ecdc9999d603dede9e4f459b1cd3d8bccfc1267` |
| 6 | `tools/fabric/evidence.py` | CREATE | `48abf37c7a8c4bb4a16398aa2f4c32c98ecf8af72dfbb85df96f2f9dcf5e1be1` |
| 7 | `tools/fabric/store.py` | CREATE | `beda03b71cbdc5568afe0c54d682afbdce94b508b4d18beefa0c78704aa3a13a` |
| 8 | `tools/fabric/validator.py` | CREATE | `dfdc02ffe0f6040751250216de7fad135e59b174c9084287e039eb0d02c1acda` |
| 9 | `tools/fabric/inspection.py` | CREATE | `a59d36b1900fcd3b25bdd649c3e4cb37c1de8fd2e9700234d4355833c250ca4a` |

All mode `0444`. Installed object count rises **48 → 57**.

### On the G11-A runtime changes

The brief asked whether Generation 11 must include `tools/fabric/models.py` and
`tools/fabric/admission.py`. The closure answers precisely:

- **`models.py` — YES.** It is in the closure, and it carries the **G11-A1**
  correction (`advertisement_id` required). Digest `c6e0ce6d…` is the
  post-G11-A file.
- **`admission.py` — NO.** It is not reachable from the installed execution
  path. **G11-A2** (target binding) and **G11-A3** (supersession) are corrections
  to the *governed write path*, which the installed runtime does not perform. The
  operator performs those from the checkout. Installing `admission.py` would add
  the mutation surface to a runtime that has no business holding it.

That is a meaningful narrowing of the brief's expectation, made on evidence.

---

## 8. Generation-11 proposed install surface

`provisioning/execution/generation-11-surface.sh` — **a declaration, not a
ceremony.** Sourcing it defines `GENERATION_11_MATRIX`; running it prints the
matrix and exits. It installs nothing, opens no transaction, touches no
authority namespace, and reads no production path.

It follows the row format Generation 10 established
(`source|target|mode|operation|sha256`) and preserves:

- **immutable generation boundaries** — every row is a `CREATE`; no
  Generation-10 object is named, so none can be altered;
- **exact source digests** — pinned per row, and a test asserts each matches the
  reviewed source;
- **fail-closed verification** — a digest mismatch is a test failure, and the
  installer that consumes this must verify before publishing;
- **no hidden defaults** — `LIBRARY_ROOT` is explicit;
- **no checkout dependency after installation** — proven in §9.

It also names `GENERATION_11_EXCLUDED` — `admission.py`, `cli.py`,
`eligibility.py`, `selection.py`, `trust_adapter.py` — so the omission reads as
decided rather than overlooked, and a test asserts none is ever added silently.

**Publication order is dependency order**, and unlike Generation 10 there is no
coupled-pair hazard: every row is a CREATE, so no installed caller can observe a
mixture. `fabric_evidence` cannot reach a half-installed package because it
cannot reach the package at all until the initialiser lands.

**The transactional installer is deliberately not written here.** Generation 10's
is 1072 lines of journal, prepared copies, backup suffixes and recovery. That
machinery belongs with the ceremony that runs it, written against the reviewed
commit and independently authorised. Writing it speculatively, untested against
production, in a checkpoint whose job is to establish the closure, would be a
larger and riskier artifact than the closure it serves. **§16 asks the reviewer
to confirm this split.**

---

## 9. Installed-only GREEN

`tests/test-fabric-runtime-install-closure.sh` builds two disposable roots — one
reproducing Generation 10 exactly, one adding the Generation-11 surface — and
runs the child interpreter with the repository unreachable.

### Isolation, and why it is drawn where it is

```bash
( unset PYTHONPATH
  cd /
  python3 -E -c "
import sys
sys.path = ['${root}'] + [
    p for p in sys.path
    if p and 'schott-platform' not in p and not p.startswith('/opt')]
..." )
```

`-E` drops every `PYTHON*` variable; running from `/` means the implicit script
directory can never be the checkout; `sys.path` is then filtered so the
disposable root is the only non-system entry.

**The standard library and dist-packages stay, deliberately.** A first attempt
used `-S` with a single-entry `sys.path`, which removed the stdlib and failed on
`import importlib` — proving nothing about a Fabric dependency. Isolating the
system Python is not a stricter test, it is a different one: the installed
runtime is entitled to the system Python and to PyYAML. **PYTHONPATH isolation
was not weakened to make GREEN pass; it was corrected to isolate the right
thing.**

### Results

```
PASS: every Generation-11 row pins the digest of the reviewed source
PASS: the governed write path is not part of the installation surface
PASS: under the Generation-11 surface, tools.capability.fabric_evidence imports
PASS: under the Generation-11 surface, tools.capability.coordinator imports
PASS: under the Generation-11 surface, tools.capability.cli imports
PASS: under the Generation-11 surface, tools.fabric.inspection imports
PASS: no tools module resolved from outside the disposable root
  LOADED 23
PASS: the repository is not on the isolated interpreter's path
PASS: the Capability to Fabric path executes from the installed surface alone
PASS: the installed runtime and the production Fabric store are unchanged
```

**23 `tools` modules loaded, every one from the disposable root.** The
no-strays assertion is what makes the rest mean anything: a suite that proved
imports work while leaving the checkout reachable would prove nothing.

### The path executes, not merely imports

Importing proves a module resolves. The suite also runs the real calls, so a
missing transitive dependency surfaces as a failure rather than lurking:

```python
report = inspect_records(str(root), expected_uid=..., expected_gid=...)
#   → report.status == STATUS_REPORTED

verdict = verify_selected_evidence(
    str(root), expected_uid=..., expected_gid=...,
    selection_id='CSEL-000001', instance_id='CINST-000001',
    capability_package_id='CPKG-0001', evaluated_at=...)
#   → a verdict object
```

The empty fixture store cannot satisfy the verification, so the verdict is a
refusal — **which is the point**: a refusal is a result, and reaching one means
every transitive import resolved and every code path ran.

### Negative control

One required module removed from an otherwise complete root:

```
PASS: removing one required module fails, naming exactly that module
      ModuleNotFoundError: No module named 'tools.fabric.models'
```

It fails, and it fails **for the expected reason** — naming the removed module,
not a generic import error that could mask a different defect.

---

## 10. Security and authority analysis

The runtime identity is `kyri-capability`, **uid 999, gid 987**. Measured
against the actual filesystem:

| Authority | Owner:group | Mode | Runtime read | Runtime write |
|---|---|---|---|---|
| `/var/lib/kyri/fabric` | `1000:1000` | `700` | **NO** | **NO** |
| `/var/lib/kyri/trust` | `1000:1000` | `700` | **NO** | **NO** |
| `/var/lib/kyri/artifacts` | `0:0` | `755` | yes | **NO** |
| `/var/lib/kyri/evidence` | `0:0` | `755` | yes | **NO** |
| `/etc/kyri/fabric` (operator inputs) | `0:1000` | `750` | **NO** | **NO** |
| `/etc/kyri/trust` (operator inputs) | `1000:1000` | `700` | **NO** | **NO** |

**Dependency closure grants none of the prohibited capabilities:**

- **Write access to Fabric authority** — denied by mode bits alone. Owner is uid
  1000, mode `0700`, runtime is uid 999 and not in the group: no read, no write,
  no traverse.
- **Write access to Trust** — same, and nothing in the closure reaches
  `tools.trust` in any case.
- **Write access to Artifact authority** — root-owned `0755`; read-only for
  everyone else.
- **Write access to Platform Evidence** — same.
- **Operator-root authority** — the Trust plane is not in the closure; the Root
  Authority is unmounted and unreferenced.
- **Bypassing approved-directory input handling** — the approved-directory
  reader lives in `tools/fabric/cli.py`, which is **excluded** from the surface.

### No mutation by import side effect

The brief said to STOP if importing Fabric mutates anything. It does not:

```
errors, evidence, identifiers, inspection, models,
request_identity, store, validator
    top-level non-declarative statements: NONE   (all eight)
```

Every top-level statement in all nine files is an import, a constant, a class or
a function definition. Confirmed empirically as well — importing the whole
closure left the production Fabric digest unchanged.

**No architectural defect. No STOP condition.**

---

## 11. The G11-C boundary

**Preserved, not implemented.** `select` still needs a genuine read-only
preflight before `CSEL-000001` is spent.

**Install-surface impact, as asked:** `tools/fabric/selection.py` is **not** in
the Generation-11 closure. A future select preflight therefore does **not** alter
this install surface — unless the correction moves logic into a module the
closure already carries (`models.py`, `store.py`, `inspection.py`,
`validator.py`), in which case the pinned digest for that module changes and the
surface must be re-derived.

Recorded so G11-C's author knows to check, rather than discovering it during an
install ceremony.

---

## 12. Adjacent defects found and fixed

**The CI-parity check could not see suites with digits in their names.**
`tests/test-developer-experience.sh` matched `tests/test-[a-z-]+\.sh` in both
directions. `tests/test-fabric-g11-integrity.sh` contains `g11`, so the check
**silently skipped it** — which is why G11-A registered that suite in
`run-validation.sh` and never in CI, and the validator passed anyway.

The regex now matches `[a-z0-9-]+`, and **both** suites are registered in
`.github/workflows/ci.yml`. The check that exists to catch exactly this omission
had a blind spot the width of a digit.

**A provisioning-artifact governance rule was tripped and complied with.**
`tests/test-capability-execution-provisioning.sh` asserts that nothing under
`provisioning/execution` is executable. The new surface declaration was created
with mode `0755`; it is now `0644`, matching `install-generation-10.sh` at
`0664`. The rule is right — these artifacts are invoked deliberately
(`bash install-generation-10.sh --verify`), never by accident.

---

## 13. Validator policy ruling

Recorded as instructed:

> **A ceremony or report checkpoint must run the full validator when repository
> `HEAD` has changed since the last full validation. Pure host-side authority
> actions with no repository change do not require a redundant full source
> validator, provided their specific authority validators and invariants pass.**

`docs/standards/definition-of-done-standard.md` §"Local validation" already owns
when the validator runs, so **that document received the smallest appropriate
update** — one bullet stating the ruling and why. No new process document was
created and no broader change was made.

The rule has teeth: two consecutive checkpoints surfaced stale-bound suite
failures that no ceremony would have caught (S5-B1 §12, G11-A §12), because
ceremony checkpoints between them changed `HEAD` without revalidating.

---

## 14. Changed files and commit

**Implementation:** `e9e6405ee8a7d602b58c58559bb43c2fe91f04fc`
`fix(runtime): close installed Fabric dependency`

```
 .github/workflows/ci.yml                        |  13 +
 docs/standards/definition-of-done-standard.md   |   7 +
 provisioning/execution/generation-11-surface.sh |  99 ++++++ (new)
 tests/test-developer-experience.sh              |   4 +-
 tests/test-fabric-runtime-install-closure.sh    | 289 ++++++++ (new)
 tools/dev/run-validation.sh                     |  10 +-
 6 files changed, 419 insertions(+), 3 deletions(-)
```

**No runtime source changed.** G11-B adds an installation surface and a proof;
the nine modules it installs were already correct, `models.py` having been made
correct by G11-A.

### Validation, from the clean implementation commit

| Check | Result |
|---|---|
| `git diff --check` | **PASS** |
| `tools/dev/run-shellcheck.sh` | **PASS** — exit 0 |
| `pre-commit run --all-files` | **PASS** — all five hooks |
| `tools/dev/run-validation.sh` | **PASS (full mode) — 93/93 steps** |
| `tests/test-fabric-runtime-install-closure.sh` | **PASS** |

```
Validation passed (full mode), started 2026-08-26T17:47:18-05:00, 93/93 steps.
```

The new suite is registered in local validation and in CI; the total rose
92 → 93.

---

## 15. Production before / after

| Authority | Before | After | Result |
|---|---|---|---|
| Fabric | `7780dacf…ab072` | `7780dacf…ab072` | **BYTE-IDENTICAL** |
| Trust | `cffd362c…fbbc39` | `cffd362c…fbbc39` | **BYTE-IDENTICAL** |
| Artifact | `63db66fd…8bec25` | `63db66fd…8bec25` | **BYTE-IDENTICAL** |
| Platform Evidence | `227abde8…20984b` | `227abde8…20984b` | **BYTE-IDENTICAL** |
| Installed runtime | 48 objects, no `tools/fabric` | 48 objects, no `tools/fabric` | **UNCHANGED** |
| Installed generation | `CGEN-000000000001` | `CGEN-000000000001` | **UNCHANGED** |

```
CADV-000001  cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195  UNCHANGED
CADV = 1     CADV-000002 : ABSENT
CINST = 0    capability-instance.seq : absent
CROUTE = 0   CSEL = 0
Root Authority : unmounted
tools/fabric installed? NO — Generation 11 not installed
```

**`CADV-000001` at completion: FRESH**, ~20.8 h remaining. Informational.

---

## 16. Actions explicitly NOT performed

- **Generation 11 not installed.** No transaction opened, no object published.
- **Generation 10 not modified.** Every Generation-11 row is a CREATE; no
  installed object is named.
- **No transactional installer written** (§8) — deliberately deferred to the
  ceremony that runs it. See Q1.
- **No `CADV-000002`, no CINST, no CROUTE, no CSEL.**
- **No Fabric, Trust, Artifact or Platform Evidence mutation.**
- **Root Authority not mounted.**
- **G11-C not implemented** — `select` preflight untouched.
- **No runtime source changed.** `admission.py` was deliberately **not** added
  to the install surface (§7).
- **Production not modified to obtain RED** — the reproduction runs against a
  copy.
- **PYTHONPATH isolation not weakened** to make GREEN pass (§9).
- **No secrets recorded.**

---

## 17. Recommended next checkpoint

**G11-C — genuine read-only `select` preflight**, before `CSEL-000001` is spent.

It is the last open blocker in the ledger. It does not touch the Generation-11
install surface (§11), so the two are independent and G11-C need not wait on an
installation ceremony.

Remaining sequence:

1. **G11-C** — `select` preflight.
2. **Generation-11 installation ceremony** — write the transactional installer
   against the reviewed commit, rehearse it, and install under independent
   authorisation. Only after this is the installed runtime self-contained.
3. **A fresh advertisement** — `CADV-000002 supersedes CADV-000001`, using the
   renewal path G11-A established.
4. **CINST-000001** — the first instance admission, with all seven blockers
   closed.

---

## 18. Questions requiring reviewer ruling

1. **Is the surface-declaration / installer split accepted?** (§8.) G11-B
   delivers the pinned matrix and the proof; the 1000-line transactional
   installer is deferred to the ceremony. The alternative is to write it
   speculatively now, untested against production.
2. **Confirm classification A and the narrowed closure** (§6, §7) — in
   particular that **`admission.py` is deliberately excluded**, so G11-A2 and
   G11-A3 are *not* carried into the installed runtime because the installed
   runtime does not perform governed writes.
3. **Is `store.py` in the closure acceptable?** It carries write methods, though
   §10 shows the runtime identity cannot reach any authority and no root is ever
   defaulted. Excluding it is not possible — `inspection.py` requires it.
4. **Should the excluded-module list be enforced beyond the test?** Today a
   future editor could add `admission.py` to the matrix and only this suite would
   object.
5. **Confirm the definition-of-done amendment** (§13) is the right home and the
   right size for the validator ruling.

---

## Appendix A — commands executed

All read-only against production. Writes went to `/tmp` only.

```bash
# Phase 0
git rev-parse HEAD ; git status --porcelain
git merge-base --is-ancestor <each G11-A commit> HEAD
cat /var/lib/kyri/implementation-authority/current-generation
<whole-tree digests: fabric, trust, artifacts, evidence>

# Phase 1 — the installed surface, and RED
find /usr/lib/kyri/python -name '*.py' -not -path '*__pycache__*'
grep -rn "tools\.fabric\|from \.\.fabric" /usr/lib/kyri/python/tools/
python3 -E -c "<import each installed entry point with the repo off sys.path>"

# Phase 2/3 — the closure, computed from source
python3 -c "<AST walk of tools.fabric.inspection's transitive imports>"
python3 -c "<top-level statement audit of all nine modules>"
grep -hE '^(import|from) ' tools/fabric/{...}.py   # third-party surface

# Phase 5 — installed-only GREEN
bash tests/test-fabric-runtime-install-closure.sh

# Phase 6 — authority
python3 -c "<runtime uid/gid vs mode bits on every authority root>"
python3 -c "<import the whole closure; re-digest the Fabric authority>"

# Validation, from the clean implementation commit
git diff --check ; tools/dev/run-shellcheck.sh
pre-commit run --all-files ; tools/dev/run-validation.sh   # 93/93
```

## Appendix B — the closure, stated once

```
tools.capability.coordinator
        │
        ▼
tools.capability.fabric_evidence
        │  from ..fabric.inspection import (STATUS_REPORTED, inspect_records)
        ▼
tools.fabric.inspection          ← C8: reads and reports, writes not one byte
        ├── tools.fabric.errors
        ├── tools.fabric.identifiers
        ├── tools.fabric.models          ← carries the G11-A1 correction
        ├── tools.fabric.store
        │       └── tools.common.immutable_store   (already installed)
        ├── tools.fabric.validator
        │       ├── tools.fabric.evidence
        │       └── tools.fabric.request_identity
        └── tools.fabric.__init__        (docstring only)

NOT reachable, and NOT installed:
        tools.fabric.admission      the governed write path
        tools.fabric.cli            approved-directory operator input
        tools.fabric.selection      G11-C's subject
        tools.fabric.eligibility
        tools.fabric.trust_adapter
        tools.trust.*               the Trust plane, entirely
```
