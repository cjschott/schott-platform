# ENG-0005 S5-B2A — Prepare and Freeze CADV-000001 Operator Authority

**Date:** 2026-08-26
**Checkpoint:** S5-B2A
**Author:** Claude (Claude Code), acting under operator authority
**Reviewer handoff:** Claude → GitHub → independent reviewer → operator freeze

---

## 1. Objective and outcome

**Objective.** Prepare the exact production operator input for `CADV-000001`
under the accepted 24-hour bootstrap validity policy, validate and preflight it
completely, then stop at the root publication boundary and hand the operator an
exact freeze command. Do not create `CADV-000001`.

**Outcome: READY_FOR_OPERATOR_FREEZE.**

The candidate body is derived entirely from current committed authority,
passes 26 scratch validations, and rehearses against the live Fabric authority
with `would_accept: true`, `predicted_record_id: CADV-000001`, `mutated: false`,
replayed identically. Every production authority is byte-identical afterwards.

**The body is frozen for reviewer/operator purposes at
SHA-256 `2cc13b39219f11d29f9968f959e4050257093d70aa7a2a285eda9b8270c6bd01`
(609 bytes).** It has not been edited, reformatted or reserialised since that
digest was computed.

Publication stopped at the root boundary as instructed: `/etc/kyri/fabric` is
`root:cschott 0750` and the invoking identity is `cschott` (uid 1000). **`sudo`
was not used.** The exact fail-closed operator block is §12.

**`CADV-000001` was not created. It remains unspent.**

> ### ⏰ THE FROZEN BODY EXPIRES AT
> # `2026-08-27T14:13:53-05:00`
> **(America/Chicago). At report-commit time, 23.98 hours remained.**
> The write must land **before** this instant or `register_advertisement` will
> refuse it as `invalid-validity-window` — see §11 and §16.

---

## 2. Starting HEAD and authority

| Gate | Required | Observed | |
|---|---|---|---|
| Branch | `arch/eng-0005-execution-transition` | identical | PASS |
| HEAD includes | `f047be278f24da5be8432fdf357dc488171e6c81` | HEAD **is** `f047be27…` | PASS |
| Worktree | clean | clean, no untracked | PASS |
| Fabric contents | exactly CAPDEF/CCON/CPKG/CHOST-0001 | exactly those four, one each | PASS |
| CADV count | 0 | 0 | PASS |
| `capability-advertisement.seq` | absent | absent | PASS |
| Next advertisement identity | `CADV-000001` | `CADV-000001` (read-only peek) | PASS |
| Trust | validates clean | `valid: true`, `problems: []` | PASS |
| `TREC-000001` | verified | `verified`, subject `HOST-0001`, domain `fabric-node` | PASS |
| `TREC-000002` | verified | `verified`, subject `CPKG-0001`, domain `capability-package` | PASS |
| Artifact authority | unchanged | `63db66fd…8bec25` | PASS |
| Platform Evidence | unchanged | `227abde8…20984b` | PASS |
| `/etc/kyri/fabric/cadv-000001.json` | absent | absent | PASS |
| Root Authority | unmounted | not a mountpoint | PASS |

```
Fabric   9cfcc8deb5ae66558582e1e60d43e1753c8544d53f815beefaae852ab127aa4a
Trust    cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39
          counts: authority 1, record 2, decision 2, evidence 7, lineage 3, audit 4
Artifact 63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25
Evidence 227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b

Fabric sequences: capability-contract, capability-definition,
                  capability-host, capability-package, request_identity.lock
CADV = 0   CINST = 0   CROUTE = 0   CSEL = 0
```

**S5-B1's full-validator status remains authoritative.** HEAD is unchanged from
the S5-B1 report commit, the worktree is clean, and no source changed in this
checkpoint — so the 91/91 pass recorded at implementation commit `90597fe…`
still describes this tree. The validator was not re-run, because re-running it
could not tell us anything new about an identical tree.

---

## 3. Rulings applied

**Advertisement duration — exactly 24 hours.** Explicit reviewer/operator
bootstrap policy for this ceremony. **Not an ADR-derived default**, and nothing
in this checkpoint claims otherwise. ADR-0012:809 continues to state that
advertisement freshness windows are unenforced until a runtime exists. No
duration is encoded in any schema, model, constant or configuration key — it
lives in the frozen body and in this report only.

**Time relationship — R13.** `observed_at <= recorded_at < valid_until`, with
the preferred shape adopted: one fresh ceremony instant for both `observed_at`
and `recorded_at`, and `valid_until = observed_at + 24 hours`. The committed
operation gave no reason to deviate. All timestamps are timezone-aware. **The
S5-B0 rehearsal timestamp was not reused** — a fresh instant was taken (§5).

**Supersession — R14.** This is the first advertisement: `supersedes` and
`superseded_by` are **absent from the body entirely**, not present-and-null.
They are unreachable optional fields (blocker #7) and were not populated merely
because the model exposes them. `notes` likewise omitted.

**Refusal vocabulary.** `invalid-validity-window` remains the committed reason
for every invalid temporal relationship. No new vocabulary was introduced or
needed here.

---

## 4. Derivation from committed authority

Re-read from the current tree, not from memory. The advertisement authority is
unchanged from the S5-B0 findings apart from the R13 hardening added in S5-B1.

**Accepted parameters** — `inspect.signature(register_advertisement)` at HEAD:

```
request_id  actor  recorded_at  capability_host_id  capability_package_id
contract_id  satisfied_contract_versions  advertised_resource_profile
observed_at  valid_until  provenance      + approving_authority (default None)
```

There is no `description` and no `notes` parameter; supplying either raises
`TypeError`, which the CLI reports as *"the decision body does not match this
operation"*. The four existing Fabric operator inputs all carry `description`;
this one must not, and does not.

**`actor` must be `CHOST-0001`.** Verified still in force at
`tools/fabric/admission.py:1303-1306`:

```python
        host = _resolve(store, "capability-host", capability_host_id)
        # A host may advertise only itself.
        if actor != capability_host_id:
            _refuse(REFUSED, REASON_NOT_SUBJECT)
```

Neither `primary-platform-operator` nor `HOST-0001` may be substituted.
`HOST-0001` is the Platform Model node identity that `CHOST-0001` *references*
(`node_identity_reference: HOST-0001`); the Fabric subject is the `CHOST` record.
Committed authority did **not** unexpectedly change, so no STOP was triggered.

**`approving_authority` must be absent.** Still in force at
`admission.py:1275-1276` — supplying one is refused as
`unexpected-approving-authority`, because *"recording one would make a
self-report into an approval."* The operation still requires a self-report
rather than human approval, so the field is omitted.

**Values derived from the governed records, not chosen:**

| Body field | Value | Derived from |
|---|---|---|
| `capability_host_id` | `CHOST-0001` | the only governed Fabric host; `node_identity_reference: HOST-0001` |
| `capability_package_id` | `CPKG-0001` | the governed package, `trusted` as `TREC-000002` |
| `contract_id` | `CCON-0001` | `CPKG-0001.contract_id == CCON-0001`, enforced at `admission.py:1304` |
| `satisfied_contract_versions` | `["1.0.0"]` | `CPKG-0001.satisfied_contract_versions == ['1.0.0']`; equals `CCON-0001.contract_version` `1.0.0`. **Verified, not assumed** |
| `advertised_resource_profile` | `{"architecture": "x86-64"}` | `CHOST-0001.verified_resource_profile == {'architecture': 'x86-64'}` — the one mechanically supported dimension |
| `provenance` | `class` / `source` / `recorded_at` | the exact three-key shape used by all four existing Fabric inputs; `class: declared`, `source:` the governing ADR |
| `actor` | `CHOST-0001` | required equal to `capability_host_id` |

**No CPU, memory or accelerator dimension is claimed.** The governed resource
vocabulary offers `host_cpu_cores`, `host_memory_mb`, `accelerator_class`,
`accelerator_memory_mb` and `accelerator_compute_capability`; none is claimed,
because `EVID-000001` proves exactly one field for this target and a self-report
may never enlarge what an operator attested.

---

## 5. Ceremony instant and the 24-hour delta

A fresh instant was taken from the system clock in `America/Chicago` (CDT,
UTC−05:00) at the moment of preparation, seconds resolution:

```
T = 2026-08-26T14:13:53-05:00      recorded_at
T = 2026-08-26T14:13:53-05:00      observed_at   (identical to recorded_at)
V = 2026-08-27T14:13:53-05:00      valid_until   = T + 24 hours
```

**Absolute expiration instant: `2026-08-27T14:13:53-05:00`
(= `2026-08-27T19:13:53+00:00` UTC).**

Mechanically asserted before the body was accepted:

```
PASS  all three instants timezone-aware
PASS  observed_at == recorded_at                     2026-08-26T14:13:53-05:00
PASS  valid_until - observed_at == exactly 24 hours  delta=1 day, 0:00:00
PASS  observed_at <= recorded_at < valid_until
PASS  valid_until > observed_at  (pre-existing rule)
```

The S5-B0 rehearsal instant (`2026-08-26T13:12:47-05:00`) was **not** reused;
this is a distinct, freshly read instant, which is why the body digest differs
from S5-B0's `9a400d01…2da3`.

---

## 6. Exact body content

Scratch path: `/tmp/s5-b2a-scratch/approved/cadv-000001.json`
Canonical destination: `/etc/kyri/fabric/cadv-000001.json`

```json
{
  "request_id": "s5b2-register-advertisement-cpkg-0001-chost-0001",
  "actor": "CHOST-0001",
  "recorded_at": "2026-08-26T14:13:53-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": ["1.0.0"],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-08-26T14:13:53-05:00",
  "valid_until": "2026-08-27T14:13:53-05:00",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-26"
  }
}
```

| | |
|---|---|
| **SHA-256** | **`2cc13b39219f11d29f9968f959e4050257093d70aa7a2a285eda9b8270c6bd01`** |
| **Size** | **609 bytes** |
| **Request ID** | `s5b2-register-advertisement-cpkg-0001-chost-0001` |
| **Encoding** | UTF-8, LF line endings, two-space indent, single trailing newline |

**These bytes are frozen.** They were not edited, reformatted or reserialised
after the digest was computed. The digest was re-verified after both preflight
runs and remains `2cc13b39…6bd01`.

The `request_id` follows the `s<stage>-<operation>-<subjects>` convention of the
four existing Fabric inputs and differs from S5-B0's rehearsal identity
(`s5b-…`), so the frozen request is distinguishable from the rehearsal in the
audit record.

---

## 7. Scratch validation — 26 assertions, all pass

Validated through the real model, the real store and the real governed records —
no re-implemented semantics.

```
=== JSON syntax and field closure ===
PASS  valid JSON object
PASS  every key is an accepted parameter          extra=[]
PASS  every required parameter present            missing=[]
PASS  approving_authority absent (self-report, not approval)
PASS  no unreachable optional populated (supersedes/superseded_by/notes)

=== actor and binding ===
PASS  actor == capability_host_id                 (CHOST-0001)
PASS  actor == CHOST-0001
PASS  capability_host_id == CHOST-0001
PASS  capability_package_id == CPKG-0001
PASS  contract_id == CCON-0001

=== current CHOST ===
PASS  CHOST-0001 resolves in the live store
PASS  CHOST-0001 is not superseded

=== package / contract consistency ===
PASS  CPKG.contract_id == body.contract_id
PASS  CCON.capability_id == CPKG.capability_id
PASS  advertised versions subset of package declared   ['1.0.0'] <= ['1.0.0']
PASS  advertised versions non-empty
PASS  advertised version equals the contract version

=== advertised resource profile ===
PASS  every dimension is governed                 ['architecture']
PASS  claim contained by verified profile          {'architecture': 'x86-64'}
                                                   within {'architecture': 'x86-64'}
PASS  no CPU / memory / accelerator dimension claimed

=== R13 temporal invariant ===
PASS  all three instants timezone-aware
PASS  observed_at == recorded_at                  2026-08-26T14:13:53-05:00
PASS  valid_until - observed_at == exactly 24 hours   delta=1 day, 0:00:00
PASS  observed_at <= recorded_at < valid_until
PASS  valid_until > observed_at (pre-existing rule)

=== identity ===
PASS  next advertisement identity is CADV-000001
PASS  destination does not exist

=== provenance ===
PASS  provenance keys match the Fabric convention  ['class','recorded_at','source']
PASS  provenance.class == declared

ALL SCRATCH VALIDATIONS PASS
```

Field closure was checked against `inspect.signature(register_advertisement)`
rather than a transcribed list, so a body naming something the operation does not
take — or omitting something it requires — is caught here rather than as an
opaque `TypeError` at the CLI.

Resource containment used the committed `tools.fabric.resources.satisfies` and
`RESOURCE_FIELDS`, not a hand comparison.

---

## 8. Scratch approved-directory design

The Fabric CLI reads a decision body **only** from inside an approved directory,
resolving the name fully and then checking containment
(`tools/fabric/cli.py::_decision_body` → `tools.common.containment.contained_path`).
A traversing name, an absolute path, or a symlink pointing outside is refused
rather than followed.

**That boundary was not weakened for rehearsal.** Instead an isolated scratch
approved directory was created and used through the same contained reader:

```
/tmp/s5-b2a-scratch/approved            drwx------  cschott:cschott  0700
/tmp/s5-b2a-scratch/approved/cadv-000001.json
```

Properties that make this safe as a rehearsal boundary:

- It is a **real, separate** approved directory, not a relaxation of the
  production one. `/etc/kyri/fabric` was never passed as
  `--approved-directory` during rehearsal, and nothing was written to it.
- It is `0700` and owned by the invoking identity, so no other account can
  substitute the body between validation and rehearsal.
- The CLI applies **identical** containment semantics to it as to the production
  directory — same function, same resolution, same refusal.
- It holds exactly one file: the candidate. There is nothing else for a
  mistyped `--input-file` to reach.

The production freeze destination remains `/etc/kyri/fabric/cadv-000001.json`,
and the S5-B2B preflight must be re-run against **that** directory once the
operator has published (§17).

---

## 9. Production-equivalent preflight

```
$ python3 -m tools.fabric.cli register-advertisement --preflight \
    --store-root /var/lib/kyri/fabric \
    --expected-uid 1000 --expected-gid 1000 \
    --input-file cadv-000001.json \
    --approved-directory /tmp/s5-b2a-scratch/approved
```

Exit 0. Complete output:

```json
{
  "destination": "/var/lib/kyri/fabric/capability-advertisements/CADV-000001.yaml",
  "destination_exists": false,
  "mutated": false,
  "operation": "register-advertisement",
  "outcome": "preflight",
  "predicted_record_id": "CADV-000001",
  "record_kind": "capability-advertisement",
  "rehearsal_outcome": "preflight",
  "rehearsal_reason": null,
  "request_digest": "sha256:f8b1a42607ea287c00bc0f5af8145743af9cfcd869302b09ec2792ab7a23a38a",
  "request_id": "s5b2-register-advertisement-cpkg-0001-chost-0001",
  "store_exists": true,
  "store_root": "/var/lib/kyri/fabric",
  "would_accept": true
}
```

All four required conceptual results met:

| Required | Observed |
|---|---|
| `would_accept: true` | `true` |
| `mutated: false` | `false` |
| `predicted_record_id: CADV-000001` | `CADV-000001` |
| `destination_exists: false` | `false` |

**Captured determinism values:**

| | |
|---|---|
| Request digest | `sha256:f8b1a42607ea287c00bc0f5af8145743af9cfcd869302b09ec2792ab7a23a38a` |
| Request ID | `s5b2-register-advertisement-cpkg-0001-chost-0001` |
| Outcome / rehearsal outcome | `preflight` / `preflight`, `rehearsal_reason: null` |
| Predicted record ID | `CADV-000001` |
| Record kind | `capability-advertisement` |

No other fingerprint is exposed by this surface. Unlike the Trust plane, the
Fabric preflight reports no record or content fingerprint — the record does not
exist yet and the operation does not compute one in advance.

**This is production-equivalent.** It runs against the **live** Fabric store,
opened `open_for_read`, under `admission.rehearsing()`, through the same governed
operation the write uses. The only difference from the S5-B2B write is the
approved directory the body is read from — which will become
`/etc/kyri/fabric` once the operator publishes.

### 9.1 Replay

Run twice. Outputs `diff`-clean — **identical in every field, including
`request_digest`.**

### 9.2 Post-rehearsal non-mutation

```
CADV count                     : 0
capability-advertisement.seq   : does not exist
sequences present              : capability-contract, capability-definition,
                                 capability-host, capability-package,
                                 request_identity.lock          (unchanged)

Fabric    9cfcc8deb5ae66558582e1e60d43e1753c8544d53f815beefaae852ab127aa4a  unchanged
Trust     cffd362c376bd01b5a992c6a22f404c158624692c8ea85c9df64037b75fbbc39  unchanged
Artifact  63db66fde41d0a9eeef877fe2efca952b061dcff015d40dd78a993f4218bec25  unchanged
Evidence  227abde89d161ce421ba506a98f004a777bc6fbd8a53b166fa0907f8fc20984b  unchanged

scratch body digest after both runs: 2cc13b39…6bd01   (unchanged)
```

---

## 10. Before / after authority digests

| Authority | Before S5-B2A | After S5-B2A | Result |
|---|---|---|---|
| Fabric `/var/lib/kyri/fabric` | `9cfcc8de…27aa4a` | `9cfcc8de…27aa4a` | **BYTE-IDENTICAL** |
| Trust `/var/lib/kyri/trust` | `cffd362c…fbbc39` | `cffd362c…fbbc39` | **BYTE-IDENTICAL** |
| Artifact `/var/lib/kyri/artifacts` | `63db66fd…8bec25` | `63db66fd…8bec25` | **BYTE-IDENTICAL** |
| Platform Evidence `/var/lib/kyri/evidence` | `227abde8…20984b` | `227abde8…20984b` | **BYTE-IDENTICAL** |
| `/etc/kyri/fabric` | 4 operator inputs | 4 operator inputs | **unchanged — nothing published** |
| Root Authority | unmounted | unmounted | **unchanged** |

---

## 11. Canonical destination and derived metadata

**Canonical destination: `/etc/kyri/fabric/cadv-000001.json`** — the lowercased
record identifier plus `.json`, the convention every existing Fabric operator
input follows. Because `CADV` identifiers are six digits, the name is
`cadv-000001.json` (not `cadv-0001.json`).

Ownership and mode **derived, not assumed**, from the existing inputs:

```
$ stat -c '%n %U:%G %a' /etc/kyri/fabric /etc/kyri/fabric/*.json
  /etc/kyri/fabric              root:cschott  750
  /etc/kyri/fabric/capdef-0001.json  root:cschott  640
  /etc/kyri/fabric/ccon-0001.json    root:cschott  640
  /etc/kyri/fabric/chost-0001.json   root:cschott  640
  /etc/kyri/fabric/cpkg-0001.json    root:cschott  640
```

**Derived convention: files `root:cschott`, mode `0640`; directory
`root:cschott`, mode `0750`.** Numeric: `uid 0`, `gid 1000`.

**Why publication requires root, and why it stopped here:**

```
$ id -un                                     → cschott (uid 1000)
$ [ -w /etc/kyri/fabric ]                    → NO
$ touch /etc/kyri/fabric/.probe              → Permission denied
$ [ -e /etc/kyri/fabric/cadv-000001.json ]   → ABSENT
```

`sudo` was **not** used, per instruction. The destination is absent, so the
operator block's refusal guard has something real to protect.

---

## 12. Exact operator freeze command

Run as an operator with root. **This block publishes the reviewed body and does
nothing else. It does not create `CADV-000001`.**

It is **self-contained**: the reviewed bytes are reproduced inline from this
report rather than read from `/tmp`, so it remains correct if the scratch
directory has been cleared. The heredoc was verified to reproduce the frozen
bytes exactly — digest `2cc13b39…6bd01`, `cmp`-identical to the scratch body.

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

DEST=/etc/kyri/fabric/cadv-000001.json
WANT=2cc13b39219f11d29f9968f959e4050257093d70aa7a2a285eda9b8270c6bd01
STAGE="$(mktemp)"
trap 'rm -f "${STAGE}"' EXIT

# 1. Refuse if the destination already exists. Never overwrite operator authority.
if [[ -e "${DEST}" || -L "${DEST}" ]]; then
  printf 'REFUSE: %s already exists\n' "${DEST}" >&2
  exit 1
fi

# 2. Materialise the reviewed bytes exactly as published in the S5-B2A report.
cat > "${STAGE}" <<'JSON'
{
  "request_id": "s5b2-register-advertisement-cpkg-0001-chost-0001",
  "actor": "CHOST-0001",
  "recorded_at": "2026-08-26T14:13:53-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": ["1.0.0"],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-08-26T14:13:53-05:00",
  "valid_until": "2026-08-27T14:13:53-05:00",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-08-26"
  }
}
JSON

# 3. Verify the source digest immediately before copying.
GOT="$(sha256sum "${STAGE}" | cut -d' ' -f1)"
if [[ "${GOT}" != "${WANT}" ]]; then
  printf 'REFUSE: source digest %s != reviewed %s\n' "${GOT}" "${WANT}" >&2
  exit 1
fi

# 4. Install the exact reviewed bytes with the derived owner, group and mode.
install -o root -g cschott -m 0640 "${STAGE}" "${DEST}"

# 5. Verify the destination digest.
GOT_DEST="$(sha256sum "${DEST}" | cut -d' ' -f1)"
if [[ "${GOT_DEST}" != "${WANT}" ]]; then
  printf 'FAIL: destination digest %s != reviewed %s\n' "${GOT_DEST}" "${WANT}" >&2
  exit 1
fi

# 6. Verify the destination metadata.
META="$(stat -c '%U:%G %a' "${DEST}")"
if [[ "${META}" != "root:cschott 640" ]]; then
  printf 'FAIL: destination metadata %s != root:cschott 640\n' "${META}" >&2
  exit 1
fi

printf 'FROZEN: %s\n' "${DEST}"
printf '  sha256   %s\n' "${GOT_DEST}"
printf '  metadata %s\n' "${META}"
```

**What this block deliberately does not do:** it does not run
`register-advertisement`, does not create `CADV-000001`, does not touch the
Fabric, Trust, Artifact or Evidence stores, does not create sequence state, and
does not mount the Root Authority. Publishing the operator input and creating
the record are two separately authorized acts.

If the destination already exists with a different digest, the block refuses
rather than overwriting; disposition is an operator decision, not an automatic
replacement.

---

## 13. Expiry safety and time remaining

The 24-hour window is anchored to `recorded_at` inside the body, so the clock
started when the body was prepared, not when it is published.

```
prepared / recorded_at : 2026-08-26T14:13:53-05:00
valid_until            : 2026-08-27T14:13:53-05:00
checked at             : 2026-08-26T14:14:51-05:00
time remaining         : 23:59:01  (23.98 hours)
margin rule            : >= 20.00 hours required at handoff
verdict                : OK — no regeneration needed
```

**23.98 hours remained at handoff, comfortably above the 20-hour margin, so the
candidate was not regenerated and these bytes stand.**

**The margin is review-and-execute time, not slack.** Everything from reviewer
acceptance through operator freeze through the S5-B2B write must complete before
`2026-08-27T14:13:53-05:00`. See §16 for what happens if it does not.

---

## 14. Execution-readiness ledger — seven findings

| # | Finding | Status |
|---|---|---|
| 1 | `CapabilityInstance.advertisement_id` must become non-optional — modeled optional while `admit_instance` requires it | **ACTIVE** — before CINST |
| 2 | `admit_instance` must require the admitted host to belong to `effective_scope["permitted_targets"]`; targets is only intersected for non-emptiness (`admission.py:597-617`), never compared to the node, unlike capabilities (`:1534`) and classifications (`:1539`). Tests required: `effective HOST-0001 + admitted HOST-0001 → accept`; `+ admitted HOST-0002 → refuse` | **ACTIVE** — before CINST |
| 3 | Installed Capability runtime lacks `tools.fabric` dependency closure — `/usr/lib/kyri/python/tools/` holds only `capability` and `common`, while installed `fabric_evidence.py` and `coordinator.py` import `tools.fabric` | **ACTIVE** |
| 4 | Generation 11 should package the existing `tools.fabric` rather than duplicate Fabric logic, unless dependency-closure inspection disproves it | **ACTIVE** |
| 5 | `select` lacks genuine read-only preflight; required before `CSEL-000001` is spent | **ACTIVE** |
| 6 | CADV admission-time stale/future-window defect — registration accepted a window that never covered its own request | **CLOSED in S5-B1**, implementation commit `90597fe9e934447dd2bb08c551f160b605c20973`; R13 invariant `observed_at <= recorded_at < valid_until` enforced in `register_advertisement`, refused as `invalid-validity-window`; validator 91/91 |
| 7 | CADV renewal/supersession path required before `CADV-000002` — `supersedes`, `superseded_by` and `notes` are declared but unreachable by any released operation. `CADV-000001` unaffected (R14: no predecessor) | **ACTIVE** — before `CADV-000002` |

An eighth observation carried from S5-B1, not a blocker: all three invalid
temporal relationships report a single reason token, so a caller reading only
the token cannot distinguish a reversed window from an already-closed one from a
future observation. Deliberate, per R13's preference for reuse.

**No blocker was implemented in this checkpoint.**

---

## 15. Actions explicitly NOT performed

- **The body was NOT published** to `/etc/kyri/fabric`. Destination still absent.
- **`CADV-000001` was NOT created.** Count 0, identity unspent.
- **No advertisement sequence state created** — `capability-advertisement.seq`
  still does not exist.
- **No CINST, CROUTE or CSEL** — all 0.
- **Nothing staged. Nothing invoked.**
- **Trust not modified. Artifact authority not modified. Platform Evidence not
  modified.**
- **Root Authority not mounted.**
- **`sudo` not used**, and no root-owned path written.
- **The approved-directory boundary was not weakened** — an isolated real
  approved directory was used, not a relaxation of the production one.
- **No implementation source changed.** No blocker implemented. Generation 11
  not opened, nothing installed.
- **The frozen bytes were not edited, reformatted or reserialised** after the
  digest was reported.
- **No unreachable optional field populated** — `supersedes`, `superseded_by`
  and `notes` are absent, not null.
- **No secrets recorded.**

---

## 16. Timing risk — read before authorizing

The R13 invariant is judged against the body's own `recorded_at`, which is
frozen at `2026-08-26T14:13:53-05:00`. Consequences:

- **If the S5-B2B write is attempted at or after `2026-08-27T14:13:53-05:00`, it
  will be refused** as `invalid-validity-window`. This is the correction working
  exactly as designed — the platform declining to record a claim that was no
  longer true when it was recorded.
- The refusal is safe: it allocates nothing, writes nothing, and leaves
  `CADV-000001` unspent. Nothing is damaged by missing the window.
- **Recovery is simply to regenerate**: take a fresh instant, rebuild the body,
  re-report the digest, re-freeze, and re-run the preflight. The body is
  operator input, not authority, so regenerating costs a checkpoint and no
  governance.
- If the reviewer expects the freeze-plus-write cycle to take longer than a day,
  the better move is to **rule a longer bootstrap window now** rather than to
  race this one.

---

## 17. Next checkpoint after operator freeze

**S5-B2B — final preflight and the single authorized `CADV-000001` write.**

1. Operator runs the §12 block. It reports the destination digest and metadata.
2. Re-verify `/etc/kyri/fabric/cadv-000001.json` is
   `2cc13b39219f11d29f9968f959e4050257093d70aa7a2a285eda9b8270c6bd01`,
   `root:cschott 0640`.
3. Re-run the preflight **against the production approved directory**, not the
   scratch one:

   ```
   python3 -m tools.fabric.cli register-advertisement --preflight \
     --store-root /var/lib/kyri/fabric \
     --expected-uid 1000 --expected-gid 1000 \
     --input-file cadv-000001.json \
     --approved-directory /etc/kyri/fabric
   ```

   Expect `would_accept: true`, `predicted_record_id: CADV-000001`,
   `mutated: false`, and request digest
   `sha256:f8b1a42607ea287c00bc0f5af8145743af9cfcd869302b09ec2792ab7a23a38a` —
   identical to §9, because the body is byte-identical and the digest is
   computed from the body, not from where it was read.
4. Confirm the write will land before `2026-08-27T14:13:53-05:00` (§16).
5. Independent authorization for exactly one `register-advertisement` write.
6. Post-write verification: `CADV-000001` exists; Fabric counts
   `CADV = 1, CINST = 0, CROUTE = 0, CSEL = 0`; Trust, Artifact and Evidence
   byte-identical; append-only proven.
7. **Stop.** Per the accepted ruling, **CINST does not follow CADV** — blockers
   1 and 2 are addressed first.

---

## Appendix A — commands executed

All read-only against production. The only writes were to `/tmp`.

```bash
# Phase 0
git rev-parse HEAD ; git rev-parse --abbrev-ref HEAD ; git status --porcelain
git merge-base --is-ancestor f047be27… HEAD
python3 -m tools.trust.cli validate-store --store-root /var/lib/kyri/trust
python3 -c "<verify_trust_record for TREC-000001 and TREC-000002>"
python3 -c "<FabricStore.open_for_read(...).peek_next_id('capability-advertisement')>"
<whole-tree digests: fabric, trust, artifacts, evidence>

# Derivation from committed authority
python3 -c "<inspect.signature(register_advertisement)>"
sed -n '1266,1310p' tools/fabric/admission.py
python3 -c "<read CPKG-0001, CCON-0001, CHOST-0001; read the four /etc/kyri/fabric inputs>"

# Ceremony instant
python3 -c "<datetime.now(ZoneInfo('America/Chicago')), T + 24h>"

# Scratch, validation, digest
mkdir -p /tmp/s5-b2a-scratch/approved && chmod 0700 /tmp/s5-b2a-scratch/approved
python3 -c "<26 scratch assertions through the real model and store>"
sha256sum /tmp/s5-b2a-scratch/approved/cadv-000001.json

# Genuine preflight, twice, through the contained approved-directory reader
python3 -m tools.fabric.cli register-advertisement --preflight \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --input-file cadv-000001.json --approved-directory /tmp/s5-b2a-scratch/approved

# Freeze boundary (refused, as expected)
stat -c '%U:%G %a' /etc/kyri/fabric /etc/kyri/fabric/*.json
[ -w /etc/kyri/fabric ]                  # NO — sudo NOT used
<heredoc digest verified byte-identical to the scratch body>
```

## Appendix B — what this advertisement is, and is not

Restated from the governing schema so the reviewer authorizing the write knows
exactly what is being recorded.

```
record_class            : claim
confers_trust           : false
confers_eligibility     : false
creates_instance        : false
may_modify_trust_state  : false
requires_admitted_subject : true
mutability              : immutable   (update_methods: none, delete_methods: none)
```

`CADV-000001` records that `CHOST-0001` claims, of itself, that it holds
`CPKG-0001`, satisfies contract version `1.0.0` of `CCON-0001`, and has
architecture `x86-64` — and that the claim was true at
`2026-08-26T14:13:53-05:00` and is offered as current until
`2026-08-27T14:13:53-05:00`.

It grants nothing. It does not admit an instance, does not confer eligibility,
does not touch either Trust standing, and cannot admit itself. Writing it is a
precondition of `admit_instance`, not a step toward execution — and per the
accepted ruling, CINST does not follow in this sequence.
