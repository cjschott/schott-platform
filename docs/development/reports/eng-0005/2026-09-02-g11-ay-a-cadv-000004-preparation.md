# ENG-0005 G11-AY-A — CADV-000004 preparation

> **Superseded as of 2026-09-02 — the 48-hour candidate.** The reviewer replaced
> the 48-hour ceremony ruling with **96 hours** before any freeze or Fabric
> write, for the reason §4 of this report raised: too little room for AY-B,
> AY-C/D, G11-AZ and G11-BA. The candidate below was **never frozen and never
> installed** — production Fabric is byte-identical to before it was prepared —
> and it **must not be installed now**.
>
> Superseded candidate, recorded so it can be recognised and refused:
> `59c5fceeb758d0495300343362a5b73863dcf46d37374704331eb9e8b9412ba5`,
> request digest `sha256:9e964cb1…32e888`.
>
> The live candidate is **[G11-AY-A2](2026-09-02-g11-ay-a2-cadv-000004-preparation-96h.md)**.
>
> Everything else here stands and is not restated there: the G11-AX closure
> (§1), the live Fabric state (§2), the allocator derivation (§3), the encoding
> and destination precedent (§5), the ceremony ordering (§9), and the five
> validation repairs (§12) are all unchanged by the reruling.

**Status: prepared, awaiting operator freeze.** No production byte was written.
This report covers the **advertisement** only. The instance is a separate
sub-checkpoint (AY-C/AY-D) and is deliberately not frozen here — see §9.

Branch `arch/eng-0005-execution-transition`, starting HEAD
`310c5904a99965462f294e2bd47a1a32dfe31bc4`, all six workflows green.
Repair commit `dade900` — see §12; the Fabric preparation itself required no
repository change.

---

## 1. G11-AX closure, independently confirmed

The operator's helper install was verified from bytes, not from the summary:

| | |
| --- | --- |
| ten helper objects at reviewed bytes, `root:root`, declared mode | **10/10** |
| library-root `.py` objects | **79** — 78 runtime + the one created helper module, exactly as AX.2 §9 predicted |
| live Generation-14 readiness rule | 8 objects → **`compatible`**, 0 blocking |
| sudoers non-`README` | 0 |

`HELPER_COMPATIBILITY = compatible`. `HELPER_COHERENCE = PASS`.

**An outstanding item, named rather than left implicit.** No G11-AX completion
report exists yet: `310c590` is the *preparation* report, written before the
operator's install. The install evidence is carried in this report's §1 and the
brief, but AX has no post-install report of its own. That is a documentation gap,
not a state gap — every claim in it has been re-derived here — and it should be
closed rather than forgotten.

## 2. Live Fabric, read directly

| kind | records | sequence | head |
| --- | --- | --- | --- |
| advertisement | 3 | 3 | **CADV-000003** |
| instance | 2 | 2 | **CINST-000002** |
| route | 2 | 2 | **CROUTE-0002** |
| selection | 1 | 1 | **CSEL-000001** |
| contract / definition / host / package | 1 each | 1 each | `CCON-0001` / `CAPDEF-0001` / `CHOST-0001` / `CPKG-0001` |

Store ownership: `/var/lib/kyri/fabric` is `cschott:cschott 0700` — the
coordinator's, so the Fabric write itself needs no elevation. Only the **freeze**
does, because `/etc/kyri/fabric` is `root:cschott 0750`.

## 3. Next identifiers, derived from the allocator

Not taken from the previous report's prediction. `peek_next_id` was asked of the
live store through the released reader:

```
capability-advertisement  next -> CADV-000004
capability-instance       next -> CINST-000003
capability-route          next -> CROUTE-0003
capability-selection      next -> CSEL-000002
```

`CADV_NEXT = CADV-000004`, destination absent. The prediction agreed with the
prior derivation, but it was re-derived rather than trusted.

## 4. Validity duration — a ceremony ruling, not a source constant

Source carries **no architectural default**: no `timedelta`, no hour constant,
no default validity anywhere in `tools/fabric/`. The window is whatever a
ceremony declares, which is why it needs ruling each time rather than inheriting.

The checkpoint brief supplies that ruling explicitly, and it is recorded here as
**ceremony policy for G11-AY**:

**`VALIDITY_DURATION = 48h`**

Adopted as a fresh ruling for this checkpoint — *not* because CADV-000003 used
48 hours. No runtime or schema change accompanies it.

### What 48 hours has to cover, stated plainly

The window opens at `observed_at` and closes 48 hours later. Between those
instants the remaining programme must complete:

| | |
| --- | --- |
| AY-B | write CADV-000004 |
| AY-C / AY-D | prepare and write CINST-000003 |
| G11-AZ | CROUTE successor and fresh CSEL |
| G11-BA | sudoers, final preflight, first production invoke |

Registration itself will not decay — the window is judged against the body's own
`recorded_at`, never against a clock, so a frozen body stays acceptable however
late it is replayed. **What decays is the useful remainder.** A body written
after its `valid_until` would be accepted and born useless.

This is not an objection to the ruling; it is the consequence of it. If the
remaining checkpoints are not expected to complete inside two days, a longer
window should be ruled *now* rather than a second renewal ceremony spent later.

## 5. The candidate

Every field derived from current governed authority and cross-checked against
the records that carry it:

| field | value | source of truth |
| --- | --- | --- |
| `capability_host_id` | `CHOST-0001` | live host record |
| `capability_package_id` | `CPKG-0001` | live package record |
| `contract_id` | `CCON-0001` | `CPKG-0001.contract_id` |
| `satisfied_contract_versions` | `["1.0.0"]` | `CPKG-0001.satisfied_contract_versions` |
| `advertised_resource_profile` | `{architecture: x86-64}` | `CHOST-0001.verified_resource_profile` |
| `provenance` | declared / ADR-0012 | precedent, re-read |
| `supersedes` | `CADV-000003` | current advertisement head |
| `actor` | `CHOST-0001` | the subject's own claim |
| `approving_authority` | **absent** | a self-report may not carry one |

```json
{
  "request_id": "g11ay-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000003",
  "actor": "CHOST-0001",
  "recorded_at": "2026-09-02T10:18:57-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-09-02T10:18:57-05:00",
  "valid_until": "2026-09-04T10:18:57-05:00",
  "supersedes": "CADV-000003",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-02"
  }
}
```

| | |
| --- | --- |
| bytes | **672** |
| SHA-256 | `59c5fceeb758d0495300343362a5b73863dcf46d37374704331eb9e8b9412ba5` |
| request digest | `sha256:9e964cb1032df0b89d5aca162263c6509d93f62f98d00b50d328ef143332e888` |
| destination | `/etc/kyri/fabric/cadv-000004.json`, `root:cschott 0640` |

Encoding and destination mode follow the live precedent, re-read rather than
assumed: `/etc/kyri/fabric/cadv-000003.json` is 2-space-indented JSON with a
trailing newline at `root:cschott 0640`, in a `root:cschott 0750` directory.

## 6. Fixture rehearsal, on a faithful history

The fixture is a full copy of the production Fabric — three advertisements, two
instances, both routes, the selection and every sequence — not a synthesised
final state, because supersession is judged against history.

**Accepted:** `would_accept: true`, `mutated: false`, predicted `CADV-000004`.

**Refused, each with its governed reason:**

| body | reason |
| --- | --- |
| supersedes `CADV-000002` (already superseded) | `renewal-predecessor-not-current` |
| `valid_until` before `observed_at` | `invalid-validity-window` |
| window closing before `recorded_at` | `invalid-validity-window` |
| unknown `capability_host_id` | `unresolved-reference` |
| naming an `approving_authority` | `unexpected-approving-authority` |

The fixture was byte-identical before and after every rehearsal.

**The fixture write then succeeded**, producing a record whose shape matches
`CADV-000003` exactly except for the renewed chain and window — and carrying the
**same request digest** the preflight reported.

## 7. Live preflight

Read-only, against the production store:

```
predicted_record_id : CADV-000004
destination         : /var/lib/kyri/fabric/capability-advertisements/CADV-000004.yaml
destination_exists  : false
would_accept        : true
mutated             : false
request_digest      : sha256:9e964cb1032df0b89d5aca162263c6509d93f62f98d00b50d328ef143332e888
```

**The request digest is identical across all three**: fixture preflight, fixture
write, and live preflight. That is the exact-request-digest discipline holding —
the operator can compare one value rather than trusting three separate runs.

The body was read from a staging directory rather than `/etc/kyri/fabric`,
because the freeze has not happened yet. The *store* the preflight judged is the
production one; the approved directory only says where the body came from. After
the freeze, §10's step B re-runs the same preflight against the frozen file, and
the digest must not move.

**Live content manifests — Fabric and Trust — were byte-identical before and
after.** Content, not structure: a same-size sequence replacement would be
invisible to a structural check.

## 8. Instance work already proven (not yet frozen)

The instance is a separate write and gets its own sub-checkpoint, but its
derivation was proven end-to-end in the fixture so that AY-C carries no surprises.

**The G11-AG structural bound, exercised rather than asserted.**
`admitted_until` is taken from the written advertisement's own `valid_until` —
read back from the record, not arithmetic repeated in a second place:

| `admitted_until` | verdict |
| --- | --- |
| advertisement `valid_until` **+1 second** | **refused** — `admission-window-exceeds-advertisement` |
| advertisement `valid_until` **+24 hours** | **refused** — `admission-window-exceeds-advertisement` |
| **equal** to advertisement `valid_until` | accepted |
| **6 hours shorter** | accepted |

Refused at one second. There is no R17 tail available.

In the fixture, `admit-instance` for `CINST-000003` against the written
`CADV-000004` preflighted and wrote cleanly, with trust re-evaluated at the new
`evaluated_at` (`TREC-000002`, `TREC-000001` both cited in the resulting
evidence), `supersedes: CINST-000002`, and `lifecycle_state: admitted`. The
fixture Fabric then validated with **zero findings**.

## 9. Ceremony ordering

Deliberately not one step:

```
A  freeze CADV-000004 input          <- this report ends here
B  preflight the frozen input
C  write CADV-000004
D  independently verify it
E  freeze CINST-000003, derived against the LIVE written CADV-000004
F  preflight the frozen instance input
G  write CINST-000003
H  independently verify it
```

The instance body is **not** frozen now, and that is a decision rather than an
omission. Its `recorded_at`, `evaluated_at` and `admitted_at` are the instants of
*its* ceremony, and its `admitted_until` must come from the advertisement record
that actually exists on production — not from a candidate that has not been
written. Freezing it now would mean writing three timestamps and a dependency
before the thing they depend on exists.

## 10. Operator block — freeze only

Fail-if-exists. It writes the reviewed input and verifies it; it performs **no**
Fabric write.

```bash
bash <<'FREEZE_CADV'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/cadv-000004.json
REVIEWED=59c5fceeb758d0495300343362a5b73863dcf46d37374704331eb9e8b9412ba5

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11ay-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000003",
  "actor": "CHOST-0001",
  "recorded_at": "2026-09-02T10:18:57-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-09-02T10:18:57-05:00",
  "valid_until": "2026-09-04T10:18:57-05:00",
  "supersedes": "CADV-000003",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-02"
  }
}
BODY

ACTUAL="$(sha256sum "${TMP}" | cut -d' ' -f1)"
test "${ACTUAL}" = "${REVIEWED}" || {
  echo "REFUSE: rendered ${ACTUAL}, reviewed ${REVIEWED}"; rm -f "${TMP}"; exit 1; }

sudo install -o root -g cschott -m 0640 "${TMP}" "${DEST}"
rm -f "${TMP}"

printf '\n--- frozen input ---\n'
sudo sha256sum "${DEST}"
sudo stat -c '%n  %U:%G  %a  %s bytes' "${DEST}"

printf '\n--- /etc/kyri/fabric AFTER ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

printf '\n--- preflight against the FROZEN input (read-only, no Fabric write) ---\n'
cd /opt/schott-platform
python3 -m tools.fabric.cli register-advertisement \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000004.json --approved-directory /etc/kyri/fabric --preflight
FREEZE_CADV
```

Expect the frozen file at 672 bytes / `59c5fcee…12ba5`, and the preflight to
report `would_accept: true`, `mutated: false`, `predicted_record_id:
CADV-000004`, and request digest `sha256:9e964cb1…32e888` — **the same digest as
§7**. If that digest moves, the body moved, and the ceremony stops.

The Fabric write is **not** in this block. It is authorised separately, after
this output is reviewed.

## 11. Production state

**Nothing was written.**

| | |
| --- | --- |
| host generation | 14 |
| helper compatibility | `compatible` |
| Fabric records / sequences | unchanged; content manifest byte-identical |
| Trust | unchanged; content manifest byte-identical |
| `CADV-000004` | absent |
| sudoers | closed |
| CINV / CRES | 0 / 0 |
| Fabric chain | **expired** — `CADV-000003` closed 2026-08-30 |
| production invoke | **not authorised** |

## 12. Validation, and the repairs it forced

The Fabric work needed no repository change. Validation nonetheless went red in
**five** places, all from one cause, and all of them consequences of the G11-AX
install rather than of anything prepared here.

**The cause, in one sentence:** `/usr/lib/kyri/python` carries the runtime
objects *and* the flattened privileged helper modules beside them, and G11-AX
created one of the latter — so every count derived from that directory moved by
one while not a single runtime object changed.

G11-AX.2 §9 recorded this in writing as a follow-up before it happened, naming
the Generation-13 and Generation-14 `--verify-installed` counts specifically. It
came due here, and it was wider than that note predicted:

| what broke | repair |
| --- | --- |
| Generation-12 packaging: surface derived from the live tree | subtract **both** successors' library-root creates — the runtime generation's and the helper ceremony's |
| Generation-13 installer: `EXPECTED_LIBRARY_FILES_*` flat counts | expectation stated as runtime objects **plus** published helper modules, read from the AX matrix |
| Generation-13 packaging: host-at-one-of-two-counts | same offset, derived the same way |
| Generation-14 installer: same flat counts | same repair |
| helper-ceremony suite: predecessors copied from the live host | reconstructed from reviewed history instead |

Every repair derives the offset from the AX ceremony's own matrix. None names
`kyri_exec_reconcile.py`, so a future helper ceremony that creates another module
needs no further edit.

**The last one is worth naming separately.** My own G11-AX suite built its
pre-ceremony baseline by copying the live helpers — true until the ceremony ran,
then silently false. That is the third suite in this programme to make exactly
that mistake, after the Generation-12 and Generation-13 packaging suites. The
predecessors are now reconstructed from history, and they resolve to **two
distinct commits** — the verify surface from `16f285e`, the transition surface
from `cfb0edd`. That is the G11-AI split-generation defect visible in the fixture
itself, and it is the state G11-AX ended.

### A live state change worth surfacing

One suite asserted *"this host is truthfully not ready to supervise"* — written
when the identity authorities were absent and the helpers stale. Both are now
installed, so **`supervision_ready` on production is `true`**:

```
coordinator_identity_authority : true
execution_identity_authority   : true   (kyri-capability)
helper_compatibility           : compatible   (0 blocking)
supervision_ready              : true
launch_grant / reconcile_grant : unobservable
```

**This does not authorise production invocation, and the field never claimed
it would.** `supervision_ready` is the conjunction of what the coordinator can
*observe*; it deliberately excludes the two grants it may not read. Sudoers is
closed and the Fabric chain is expired, so nothing can execute.

The suite was pinning a snapshot that the programme was designed to move past. It
now asserts the property that must hold at every stage instead: that the report
is internally honest — readiness is exactly the conjunction of its own observable
inputs, and the unobservable grants are never turned into a verdict, which
matters most precisely when every observable gate is open.

Totals unmoved, since no suite was added: quick **102/102**, full **127/127**.
ShellCheck, Semgrep and both static suites clean. ShellCheck also caught a real
error in one repair — a `${ROOT}` that should have been `${REPOSITORY}`, which
would have silently computed an offset of zero.

## 13. What AY does not restore

After both writes, `CROUTE-0002` still names `CINST-000002`. **`CINST-000003`
will not be routable**, and no service is restored by this checkpoint. Sudoers
stays closed throughout, so no workload could execute even if a route did resolve.

Next: **G11-AZ** — a `CROUTE` successor, then a fresh `CSEL`.
