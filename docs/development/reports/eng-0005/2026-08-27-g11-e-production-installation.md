# ENG-0005 G11-E — Production Generation-11 Installation

**Date:** 2026-08-27
**Checkpoint:** G11-E
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer

---

## 1. Objective and outcome

**Objective.** Record the completed production Generation-11 installation
ceremony durably, and verify — independently, read-only, and without trusting
the ceremony's own output — that the installed runtime is exactly the
post-install Generation-11 surface.

**Outcome: ACCEPTED.**

The operator performed the privileged ceremony. This checkpoint performed **no
installation, no mutation, and no privileged operation of any kind** — every
command below ran as uid 1000, and the audit is proven not to have changed a
byte of what it inspected.

The installed runtime is verified as Generation 11:

- **57 objects**, up from 48;
- the **nine** declared Fabric objects present, each byte-identical to reviewed
  commit `6016d4f`, `root:root 0444`, in a `root:root 0755` package directory;
- **no undeclared object** beneath `tools/fabric`, no symlink, no residue;
- **exactly nine files touched** by the installation — mtime `2026-08-27 09:33`
  — and they are exactly the nine new objects. Not one Generation-10 object was
  written;
- the governed write path, the operator-input surface and the Trust plane are
  **not merely absent from disk but not importable** by the installed runtime;
- the implementation-authority and control fingerprints and all four governance
  authorities are **byte-identical to the G11-D pre-install capture**.

**The G11-B defect is closed in production.** With the repository removed from
`sys.path`, `tools.capability.fabric_evidence`, `tools.capability.coordinator`,
`tools.capability.cli` and `tools.fabric.inspection` all import from
`/usr/lib/kyri/python`, and **not one of the 40 loaded `tools` modules resolves
from outside it**. The installed runtime has stopped borrowing a checkout.

Two findings are recorded rather than smoothed over:

- **Two installed helper modules lag the repository source** (§10.1). They are
  not a Generation-11 concern — no generation since 7 republishes them, their
  bytes match an ancestor of the Generation-10 authority exactly, and their
  mtimes are 2026-08-13. Recorded because a future generation will have to
  decide about them.
- **`CADV-000001` is FRESH, but only for 4h 35m** (§19). That is a live
  constraint on the next step, not a defect.

**The `/root` evidence artifacts could not be read unprivileged** (§14). Their
existence and consistency rest on the operator's `--verify-installed` passing,
not on my direct observation, and this report says so rather than implying
otherwise.

---

## 2. Operator ceremony commands

Performed by the operator with privilege. **Not performed, not repeated and not
altered by this checkpoint.**

```bash
sudo bash provisioning/execution/install-generation-11.sh --verify
sudo bash provisioning/execution/install-generation-11.sh --install          # exactly once
sudo bash provisioning/execution/install-generation-11.sh --verify-installed
```

All three reported **all checks passed**.

The ceremony object is `provisioning/execution/install-generation-11.sh`,
committed at `ac60ec672f0986a671886507816dd6d224ed8db3` (G11-D), mode `0644` —
invoked deliberately via `bash`, never by accident.

---

## 3. `--verify` output summary

The read-only preflight, as reported by the operator:

| Gate | Result |
|---|---|
| repository at branch, reviewed authority present and an ancestor of HEAD | PASS |
| nine source objects match reviewed authority `6016d4f` | PASS |
| matrix equals the recomputed dependency closure | PASS |
| all excluded Fabric modules outside the closure and outside the matrix | PASS |
| installed runtime is exactly the accepted Generation-10 baseline (48 objects) | PASS |
| Fabric package directory does not exist yet | PASS |
| no transaction residue at any of the nine target pathnames | PASS |
| neither sudoers grant exists — G3 and G6.1B stay closed | PASS |
| every target stages beside itself, so publication is a rename | PASS |
| governed write path, operator-input surface and Trust plane absent | PASS |
| no transaction in progress | PASS |
| host at Generation 10 and ready: 9 CREATE, object count 48 → 57 | PASS |

---

## 4. `--install` output summary

The transaction:

| Phase | Result |
|---|---|
| PREPARE staged exactly nine objects, nine pathnames reserved | PASS |
| all prepared objects verified against the reviewed commit | PASS |
| COMMIT created and verified exactly nine objects | PASS |
| Generation-11 evidence written | PASS |
| Generation-10 evidence preserved | PASS |
| transaction artifacts removed | PASS |
| all nine installed objects correspond to reviewed commit `6016d4f` | PASS |
| governed write path, operator-input surface, Trust plane absent | PASS |
| every Generation-10 object remains its accepted baseline | PASS |
| implementation-authority and control fingerprints unchanged | PASS |

**Nine CREATE, zero REPLACE.** No Generation-10 object was named by the matrix,
so none could be altered — and §10 confirms independently that none was.

---

## 5. `--verify-installed` output summary

| Gate | Result |
|---|---|
| all nine installed objects correspond to reviewed commit `6016d4f` | PASS |
| governed write path, operator-input surface and Trust plane absent | PASS |
| every Generation-10 object exactly its accepted baseline, nothing removed | PASS |
| Fabric package directory holds only declared objects | PASS |
| neither sudoers grant exists | PASS |
| no transaction artefacts remain | PASS |

**all checks passed.**

---

## 6. Reviewed source authority

```
6016d4f0b8cfea9bfc8f60166b7cba5a2fa82a75
```

The commit at which all five known Generation-11 source blockers closed —
G11-A1, G11-A2, G11-A3 (`c35ccd8c`, `305f84aa`), G11-B (`e9e6405e`) and G11-C
(`6016d4f0`). Pinned in the ceremony, never `HEAD`.

Verified an ancestor of the current repository `HEAD`
(`dd974823169ce8f52be86bff71b3c0b08c1a530a`), which is unchanged by the
host-side installation and carries the G11-D implementation `ac60ec6` and its
report `dd97482`.

---

## 7. The nine installed objects

`/usr/lib/kyri/python/tools/fabric/`, all `root:root 0444`, directory
`root:root 0755`:

```
__init__.py          identifiers.py        request_identity.py
errors.py            models.py             store.py
evidence.py          inspection.py         validator.py
```

The transitive import closure of `tools.fabric.inspection` — the single symbol
`tools/capability/fabric_evidence.py` reaches into Fabric for — minus the three
modules Generation 10 already installed (`tools/__init__.py`,
`tools/common/__init__.py`, `tools/common/immutable_store.py`).

---

## 8. Installed object count 48 → 57

```
before (Generation 10, G11-D capture) : 48
after  (Generation 11, this audit)    : 57
delta                                 : +9, exactly the CREATE count
```

Nothing beneath `tools/fabric` other than the nine:

```
non-.py files (excluding __pycache__) : 0
symlinks                              : 0
```

No `__pycache__` exists beneath `tools/fabric` yet — the installed Fabric
package has not been imported by a privileged runtime process since
installation. Expected, and not a defect: `__pycache__` appears on first import
by a process that can write there, and the ceremony's foreign-object gate
exempts it (G11-D §13.2).

---

## 9. Digest verification

Each installed object verified against **both** the reviewed matrix in
`provisioning/execution/generation-11-surface.sh` **and** the blob at commit
`6016d4f` — three-way agreement, not two:

| Object | SHA-256 | installed = matrix = commit |
|---|---|---|
| `tools/fabric/__init__.py` | `e761edea8dfe6df49080d58441f41b48558c335d82a309ca12e7cd271bdf6230` | **MATCH** |
| `tools/fabric/errors.py` | `ddc6a7654ca5e38aa828070bd5400a7bc93bee48db231494e235ff8d9c1e954a` | **MATCH** |
| `tools/fabric/identifiers.py` | `e523096cb23864d0970ccd038c8ad1532ca0a245b268a51838195c6328b63226` | **MATCH** |
| `tools/fabric/models.py` | `c6e0ce6d4b70a077072794ffd2cde548ea3b031c061e108eb37769dccd5d657b` | **MATCH** |
| `tools/fabric/request_identity.py` | `b0ff8b1dde147d186b0675b55ecdc9999d603dede9e4f459b1cd3d8bccfc1267` | **MATCH** |
| `tools/fabric/evidence.py` | `48abf37c7a8c4bb4a16398aa2f4c32c98ecf8af72dfbb85df96f2f9dcf5e1be1` | **MATCH** |
| `tools/fabric/store.py` | `beda03b71cbdc5568afe0c54d682afbdce94b508b4d18beefa0c78704aa3a13a` | **MATCH** |
| `tools/fabric/validator.py` | `dfdc02ffe0f6040751250216de7fad135e59b174c9084287e039eb0d02c1acda` | **MATCH** |
| `tools/fabric/inspection.py` | `a59d36b1900fcd3b25bdd649c3e4cb37c1de8fd2e9700234d4355833c250ca4a` | **MATCH** |

```
matched = 9    mismatched = 0
```

`models.py` at `c6e0ce6d…` is the post-G11-A1 file — the mandatory
`advertisement_id` correction is in the installed runtime.

Modes and ownership, every row:

```
444 root:root  ×9        directory 755 root:root
```

---

## 10. Generation-10 preservation proof

Two independent proofs, because the strongest one does not depend on reading
root-owned evidence.

### 10.1 Digest comparison against the Generation-10 authority

Every installed object that is not one of the nine, compared against the blob at
the accepted Generation-10 authority `83da574bacde762de3222c60eb1873b2a750e54c`:

```
Generation-10 objects expected : 48
matched                        : 46
differing                      : 2
unaccounted for                : 0
missing                        : 0
```

**The two differing objects are not a Generation-11 concern, and the reason is
provable.**

```
/usr/lib/kyri/python/kyri_exec_transition.py
/usr/lib/kyri/python/kyri_exec_transition_action.py
```

- The installed bytes match **exactly** the repository blobs at commit
  `cfb0edd31b3589f12b6ba583ebfa48bb64e89519` (2026-08-13, *"feat(execution):
  carry the governed profile on a sealed root-authored FD"*), which is an
  **ancestor of the Generation-10 authority**.
- `install-generation-8`, `-9`, `-10` and `-11` name these files **zero** times.
  Generation 7 was the last to publish them, so they have never been
  republished, and they legitimately lag the repository source.
- Their mtimes are **2026-08-13 16:36**, two weeks before this installation.

So the comparison baseline in this section — "the repo source at the
Generation-10 commit" — is the wrong reference for these two: no generation
republished them, so the installed bytes are the *last published* bytes, not the
*current source* bytes. Nothing drifted.

**Observation carried forward, not a blocker.** The installed
`kyri_exec_transition.py` predates the G6.1 correction that made `worker_script`
a required argument. The repository source has moved on; the installed runtime
has not. A future generation that needs the transition path corrected will have
to include these two in its matrix. Recorded here so that decision is made
deliberately rather than discovered.

### 10.2 The decisive proof — what the installation actually touched

Independent of any digest baseline:

```
objects with mtime on 2026-08-27 : 9

  09:33  tools/fabric/__init__.py          09:33  tools/fabric/models.py
  09:33  tools/fabric/errors.py            09:33  tools/fabric/request_identity.py
  09:33  tools/fabric/evidence.py          09:33  tools/fabric/store.py
  09:33  tools/fabric/identifiers.py       09:33  tools/fabric/validator.py
  09:33  tools/fabric/inspection.py
```

**Exactly nine files were written, and they are exactly the nine new
Generation-11 objects.** No Generation-10 object was touched by the
installation. This is the claim that matters, and it holds without reference to
any evidence file.

---

## 11. Excluded runtime surface proof

Proven two ways — absent from disk, and **not importable by the installed
runtime**.

| Surface | Present on disk | Importable |
|---|---|---|
| `tools/fabric/admission.py` — the governed write path | **ABSENT** | `ModuleNotFoundError` |
| `tools/fabric/selection.py` — C6 selection | **ABSENT** | `ModuleNotFoundError` |
| `tools/fabric/cli.py` — approved-directory operator input | **ABSENT** | `ModuleNotFoundError` |
| `tools/fabric/eligibility.py` | **ABSENT** | `ModuleNotFoundError` |
| `tools/fabric/trust_adapter.py` | **ABSENT** | `ModuleNotFoundError` |
| `tools/fabric/evidence_authority.py` | **ABSENT** | `ModuleNotFoundError` |
| `tools/fabric/resources.py` | **ABSENT** | `ModuleNotFoundError` |
| `tools/trust` — the Trust plane, entirely | **ABSENT** | `ModuleNotFoundError` |

The second column is the stronger statement. Absence from a directory listing is
a fact about the filesystem; unimportability is a fact about what the runtime can
reach. **The installed Capability Runtime cannot resolve the Fabric mutation
surface, the operator input surface, or the Trust plane at all.**

Consistent with G11-B §6: installing modules makes code resolvable and grants no
authority — and here, the modules that *would* mutate are not even resolvable.

---

## 12. Installed-only import proof

Run against **production**, from `/`, with `python3 -E` (dropping every `PYTHON*`
variable), `PYTHONPATH` unset, and every `/opt` and `schott-platform` entry
filtered out of `sys.path`. **The repository was not added to `sys.path`.**

```
sys.path:
    /usr/lib/kyri/python
    /usr/lib/python312.zip
    /usr/lib/python3.12
    /usr/lib/python3.12/lib-dynload
    /usr/local/lib/python3.12/dist-packages
    /usr/lib/python3/dist-packages

  IMPORT OK   tools.capability.fabric_evidence  <- /usr/lib/kyri/python/tools/capability/fabric_evidence.py
  IMPORT OK   tools.capability.coordinator      <- /usr/lib/kyri/python/tools/capability/coordinator.py
  IMPORT OK   tools.capability.cli              <- /usr/lib/kyri/python/tools/capability/cli.py
  IMPORT OK   tools.fabric.inspection           <- /usr/lib/kyri/python/tools/fabric/inspection.py

  tools modules loaded: 40
  resolved outside /usr/lib/kyri/python: NONE
```

The no-strays line is what makes the rest mean anything: an import proof that
left the checkout reachable would prove nothing.

The `tools.fabric` modules the runtime actually loads are **exactly the nine**:

```
tools.fabric            tools.fabric.inspection        tools.fabric.store
tools.fabric.errors     tools.fabric.models            tools.fabric.validator
tools.fabric.evidence   tools.fabric.request_identity
tools.fabric.identifiers
count: 9
```

The closure is complete — nothing is missing — and closed — nothing extra is
reached. **The three modules that could not import at Generation 10 now import,
from the installed runtime alone.**

---

## 13. Transaction cleanup proof

Across the whole library root, not merely the nine target pathnames:

```
*.kyri-gen11.new      : 0
*.kyri-gen11.gen10    : 0
*.kyri-gen10.*        : 0
*.new / *.writing / *.restoring / *.publishing : 0
symlinks under tools/fabric : 0
undeclared objects under tools/fabric : 0
```

No prepared material, no rollback material, no partially-written object, no
residue from this transaction or its predecessor.

---

## 14. Evidence preservation — and the limit of this audit

The ceremony writes `/root/kyri-gen11-{library,helper}-digests.txt` at `0400`
and preserves the Generation-10 pair, and its journal at
`/root/kyri-gen11-transaction/journal` should read `state=COMMITTED`.

**None of these is readable by an unprivileged process, and this audit is
unprivileged:**

```
/root/kyri-gen10-library-digests.txt   not readable unprivileged (root-only, expected)
/root/kyri-gen10-helper-digests.txt    not readable unprivileged (root-only, expected)
/root/kyri-gen11-library-digests.txt   not readable unprivileged (root-only, expected)
/root/kyri-gen11-helper-digests.txt    not readable unprivileged (root-only, expected)
/root/kyri-gen11-transaction/journal   not readable unprivileged (root-only, expected)
```

**Stated plainly: I did not verify these files directly.** Their existence and
internal consistency rest on the operator's `--verify-installed` having passed —
that mode fails closed if any of the four evidence files is missing or if the
journal is not `COMMITTED`, so a passing run is a meaningful attestation. It is
attestation, not observation, and this report does not present it as more.

Reading them would require privilege this checkpoint must not take. A reviewer
wanting direct confirmation can run, as root:

```bash
sudo head -6 /root/kyri-gen11-helper-digests.txt
sudo grep '^state=' /root/kyri-gen11-transaction/journal
sudo wc -l /root/kyri-gen11-library-digests.txt   # expect 57
```

---

## 15. Sudoers state

```
/etc/sudoers.d/kyri-exec         absent
/etc/sudoers.d/kyri-exec-verify  absent
```

**G3 and G6.1B remain closed.** The ceremony writes no sudoers policy, and none
appeared.

---

## 16. Implementation-authority fingerprints

```
/var/lib/kyri/implementation-authority
    1de790c92fd145c49b4a956f3abd74651e01b7effdc1d08bd6fbf515318c9422
/var/lib/kyri/implementation-authority-control
    b68f99f479fcffa0066269abd2ed7a2acdaa1d9c6b978d6b109794d647c985e6

current-generation:
    {"cgen":"CGEN-000000000001",
     "generation_digest":"fc9a3ec3ab1d9c9c25514ecab86a078dcd18261fbb87d28d093660ce899e0163"}
```

**`CGEN-000000000001` is unchanged, and correctly so.** CGEN is the *governed
implementation-authority* generation, advanced by admission when it publishes a
CIMP record. The installer's "Generation 10 / 11" is the *runtime library*
generation. They are independent numbering schemes, and G11-D asserted
structurally that the ceremony contains no reference to `current-generation` or
`CGEN-` at all.

**Installing a library did not advance a governed authority**, which is exactly
the intended behaviour.

---

## 17. Root Authority state

```
/mnt/kyri-root : unmounted
```

Not mounted before, during, or after. Not referenced by the ceremony.

---

## 18. Fabric / Trust / Artifact / Evidence non-mutation proof

Whole-tree digests, relative-path method (the method G11-D established as
reproducing the prior reports):

| Authority | G11-D pre-install | G11-E post-install | Result |
|---|---|---|---|
| Fabric | `7780dacf…ab072` | `7780dacf274f57e000a0ab93208e7b89a6b1933ed2c181cec5f79a49119ab072` | **BYTE-IDENTICAL** |
| Trust | `cffd362c…fbbc39` | `cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39` | **BYTE-IDENTICAL** |
| Artifact | `30732e2c…6257f` | `30732e2c7b22f18453410d73823ba084738447fcc0d5311eb89d7d7b4a36257f` | **BYTE-IDENTICAL** |
| Platform Evidence | `227abde8…20984b` | `227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b` | **BYTE-IDENTICAL** |

**The installation of nine runtime modules moved no governance authority.**

The Artifact digest carries forward the discrepancy recorded in G11-D §18: it
does not reproduce the `63db66fd…` value stated in G11-A/B/C, but it is
unchanged across this installation and the bytes have not moved. That remains an
open question about the earlier records, not about this ceremony.

### This audit's own non-mutation

```
objects after the audit                      : 57  (unchanged)
__pycache__ created beneath tools/fabric     : 0
anything beneath tools/fabric newer than 09:34 : 0
```

The import proof ran as uid 1000 against a `root:root 0755` directory, so CPython
could not write bytecode. **The audit observed without altering.**

---

## 19. `CADV-000001` freshness

**FRESH — but only just.**

```
now         2026-08-27T09:38:28-05:00
valid_until 2026-08-27T14:13:53-05:00
remaining   4h 35m
verdict     FRESH
```

```
CADV-000001 digest cb2e16c7a2a8ae1b3a92df27718f57c71f251c46f4e22bdc9afff819b6c7e195
                   UNCHANGED from G11-B, G11-C and G11-D
```

Not modified, not superseded, not read by anything in this checkpoint beyond
this measurement.

**This is a live constraint on the next step, not a defect.** The brief
anticipated expiry; the advertisement has not expired, but the window closes at
14:13:53 today. Either:

- **a `CINST-000001` admission happens inside the remaining window**, using
  `CADV-000001` as its advertisement identity; or
- **the window lapses and `CADV-000002` must supersede it**, via the governed
  supersession path G11-A3 established.

Nothing breaks when it lapses — an expired advertisement is expected historical
authority, retained, not deleted. But a CINST needs a fresh claim, and G11-A
made stale-advertisement admission a refusal, so an admission attempted after
14:13:53 with `CADV-000001` **will be refused**. That refusal would be correct
behaviour, not a fault.

---

## 20. Exact current platform state

```
Repository        /opt/schott-platform
Branch            arch/eng-0005-execution-transition
HEAD              dd974823169ce8f52be86bff71b3c0b08c1a530a
Worktree          clean

Installed runtime /usr/lib/kyri/python
  objects         57
  tools/fabric    present — 9 files, root:root 0444, directory root:root 0755
  installed at    2026-08-27 09:33
  library generation  11
  CGEN            CGEN-000000000001  (governed authority, unchanged)

Fabric store      /var/lib/kyri/fabric
  CAPDEF-0001  CCON-0001  CPKG-0001  CHOST-0001  CADV-000001
  CINST  = 0        capability-instance.seq  : absent
  CROUTE = 0        capability-route.seq     : absent
  CSEL   = 0        capability-selection.seq : absent
  sequences present: advertisement, contract, definition, host, package,
                     request_identity.lock

Gates             /etc/sudoers.d/kyri-exec         absent
                  /etc/sudoers.d/kyri-exec-verify  absent
Root Authority    unmounted
Transaction       no residue anywhere under the library root
```

All five source blockers closed; the reviewed closure installed; the installed
runtime self-contained; **no governance identity yet spent beyond `CADV-000001`.**

---

## 21. Actions explicitly NOT performed

- **No installation.** `--install` was not run, re-run, or altered.
- **No privileged operation whatsoever.** No `sudo`, no `runuser`; every command
  in this checkpoint ran as uid 1000. Where privilege would have been required
  (§14), the limit is stated rather than worked around.
- **Generation 11 not altered.** Not one installed byte written; proven in §18.
- **No `CADV-000002`.** `CADV-000001` untouched and unsuperseded.
- **No CINST, no CROUTE, no CSEL.** No sequence advanced; none created.
- **No Fabric, Trust, Artifact or Platform Evidence mutation.**
- **Root Authority not mounted.**
- **No repository source changed.** This commit adds one report and nothing else.
- **The repository was not added to `sys.path`** for the import proof (§12).
- **The two lagging helper modules were not corrected** (§10.1) — outside this
  checkpoint's scope, and a matrix decision for a future generation.
- **The full source validator was not re-run** to "validate" the installation.
  Repository `HEAD` did not change because of a host-side install, and a source
  validator cannot attest to a production install. §22 records what was run.
- **No secrets, credentials, tokens or passwords recorded.**

---

## 22. Repository checks for this report commit

Report-commit policy only. **These validate the repository, not the production
installation**, and are not presented as doing otherwise.

| Check | Result |
|---|---|
| `git status --porcelain` before commit | clean but for the new report |
| `git diff --check` | **PASS** |
| `pre-commit run --all-files` | **PASS** — all five hooks |
| `tests/test-docs-static.sh` | **PASS** |

The full validator was last run green at **94/94** from `ac60ec6` (G11-D §19).
`HEAD` has not changed for any source reason since.

---

## 23. Recommended next checkpoint

**`CINST-000001` — the first governed instance admission**, now that the
installed runtime is self-contained and all five source blockers are closed.

The advertisement window decides the shape of the next step:

1. **If admitted before `2026-08-27T14:13:53-05:00`** — proceed directly with
   `CADV-000001` as the advertisement identity, using the G11-A1 mandatory
   `advertisement_id` and the G11-A2 effective-target binding, rehearsed via the
   existing `--preflight` before the identity is spent.
2. **If the window lapses first** — publish `CADV-000002 supersedes CADV-000001`
   through the governed supersession path from G11-A3, then admit against the
   fresh advertisement. `CADV-000001` is retained as historical authority.

Then, in order:

3. **`CROUTE-000001`** — the route the selection will resolve against.
4. **`CSEL-000001`** — the first governed selection, rehearsed with the G11-C
   read-only preflight so the binding is known before the identity is spent.

Two items carried forward from earlier checkpoints, neither blocking:

- **The Artifact digest discrepancy** with the G11-A/B/C records (G11-D §18,
  §18 here) — the bytes have not moved; the recorded value may need correction.
- **The two lagging execution helper modules** (§10.1) — a matrix decision for
  whichever generation next corrects the transition path.

---

## Appendix A — commands executed

**All read-only. No `sudo`. No writes to any production path.**

```bash
# Repository authority
git rev-parse --abbrev-ref HEAD ; git rev-parse HEAD ; git status --porcelain
git merge-base --is-ancestor <ac60ec6|dd97482|6016d4f> HEAD

# Installed surface
find /usr/lib/kyri/python -type f -name '*.py' | wc -l          # 57
ls -la /usr/lib/kyri/python/tools/fabric
find /usr/lib/kyri/python/tools/fabric -mindepth 1
stat -c '%a %U:%G' <each of the nine> /usr/lib/kyri/python/tools/fabric

# Digest verification, three-way
source provisioning/execution/generation-11-surface.sh
sha256sum <each installed target>
git cat-file blob 6016d4f:<each source> | sha256sum

# Generation-10 preservation
git ls-tree -r --name-only 83da574 -- tools/__init__.py tools/capability tools/common
git cat-file blob 83da574:<each> | sha256sum          # 46/48 match
git log --format=%H -- provisioning/execution/kyri-exec-transition.py
git merge-base --is-ancestor cfb0edd 83da574          # provenance of the two
find /usr/lib/kyri/python -type f -name '*.py' -newermt '2026-08-27 00:00'   # exactly 9

# Exclusions and residue
find /usr/lib/kyri/python -name '*.kyri-gen11.*' -o -name '*.new' …
test -e /usr/lib/kyri/python/tools/{fabric/{admission,selection,cli,…}.py,trust}

# Installed-only import proof — repository NOT on sys.path
cd / && unset PYTHONPATH && python3 -E -c "<filter /opt from sys.path; import; list strays>"

# Gates, authority, Fabric state
test -e /etc/sudoers.d/kyri-exec{,-verify} ; mountpoint -q /mnt/kyri-root
find /var/lib/kyri/implementation-authority{,-control} -printf '%p %s %m\n' | sort | sha256sum
cat /var/lib/kyri/implementation-authority/current-generation
ls -1 /var/lib/kyri/fabric/*/ ; grep valid_until <CADV-000001>
( cd <authority root> && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum )
```

## Appendix B — the transition, stated once

```
BEFORE  (Generation 10, G11-D capture)          AFTER  (Generation 11, this audit)

  /usr/lib/kyri/python                            /usr/lib/kyri/python
    48 objects                                      57 objects            (+9)
    tools/fabric : ABSENT                           tools/fabric : 9 files, 0444 root:root

  tools.capability.fabric_evidence                tools.capability.fabric_evidence
    ModuleNotFoundError: tools.fabric               IMPORT OK, from the installed root
  tools.capability.coordinator                    tools.capability.coordinator
    ModuleNotFoundError: tools.fabric               IMPORT OK, from the installed root
  tools.capability.cli                            tools.capability.cli
    ModuleNotFoundError: tools.fabric               IMPORT OK, from the installed root

  the installed runtime borrowed a checkout       the installed runtime is self-contained

UNCHANGED ACROSS THE TRANSITION
  CGEN-000000000001                 the governed authority did not move
  Fabric / Trust / Artifact / Evidence  byte-identical
  46 of 48 Generation-10 objects    exact; the other 2 untouched since 2026-08-13
  CADV=1 CINST=0 CROUTE=0 CSEL=0    no identity spent
  both sudoers grants               absent
  Root Authority                    unmounted

STILL UNREACHABLE, BY DESIGN
  tools.fabric.admission  selection  cli  eligibility  trust_adapter
  tools.trust.*
        not merely absent from disk — not importable by the installed runtime
```
