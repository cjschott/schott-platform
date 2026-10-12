# ENG-0005 G11-BC-J — Fabric renewal and the corrected payload, prepared

**Checkpoint:** G11-BC-J (preparation only)
**Date:** 2026-09-13
**Branch:** `arch/eng-0005-execution-transition`
**Reviewer rulings carried in:** `CRES-000001_ACCEPTED=YES`,
`CINV-000002_FINAL=YES`, `CINV-000002_EXECUTE_AGAIN_AUTHORISED=NO`,
`FABRIC_RENEWAL_REQUIRED=YES`

Nothing was written to Fabric, Trust, the runtime store, the handoff, or
`/etc/kyri/fabric`. No CINV or CRES was allocated. Every rehearsal below ran
against **copies** of the production stores.

Four freeze blocks and one payload are prepared. All five were driven through
the real Fabric and capability engines on an isolated copy, in order, and the
chain ends with `would_accept: true` / `predicted_invocation_record_id:
CINV-000003`.

---

## 0. A sequencing concern, stated before the work

The renewal starts a four-day clock. `CINV-000003` **may not execute** until the
separate duplicate-result pre-execution guard checkpoint is accepted (§10). So
freezing this chain today buys a lease that cannot legally be used yet, and if
the guard checkpoint runs past 2026-09-17T19:00:00-05:00 the chain expires
unused and G11-BC-J is repeated verbatim.

The preparation is durable; the clock is not. **Recommendation: accept this
preparation now, run the guard checkpoint next, and execute these freeze blocks
after it is accepted** — the bodies do not decay (every instant in them is a
literal, §3.2), so the delay costs nothing and the window is then spent on the
part that needs it.

This is a recommendation about ordering, not a refusal. Everything asked for is
prepared and verified below.

---

## 1. Current authorities, reconstructed

All values measured this checkpoint, read-only.

| required | measured | |
| --- | --- | --- |
| `HOST_GENERATION` | **17** — derived, not assumed: the four installed objects (`helpers.py 78da8519…`, `kyri_exec_launcher.py 152038b1…`, `kyri_exec_podman.py 04205c53…`, `kyri_exec_transition_action.py d40f5121…`) are all in Generation-17's declared target set, and `helpers.py` is the Gen-17 readiness rule, not Gen-15's `6dd93606…` | ✔ |
| `HELPER_COMPATIBILITY` | `compatible` | ✔ |
| `HELPER_BLOCKING` | 0 | ✔ |
| `SUPERVISION_READY` | `true` (coordinator + execution identity authority both true; grants `unobservable` unprivileged, as always) | ✔ |
| `CINV-000002` SHA256 | `923ff0d72e3217cbaa378cf55b69045e3dde914e1afce4becab9a5a7e6d3f4aa` | ✔ |
| `CINV-000002` classification | SPENT_AND_RESOLVED — a CRES exists for it with `attempt_number 1` | ✔ |
| `CRES-000001` SHA256 | `18ba4c3428f3b87a033abdeb54feb63a4cda6c8c41597e5ab591e7e7a7396f2d` | ✔ |
| `CRES-000001` outcome | `provider-error`, final | ✔ |
| CINV sequence | 2 | ✔ |
| CRES sequence | 1 | ✔ |
| Fabric valid | `fabric validate` → `status: reported`, **findings: []**, counts 5/1/1/1/4/1/4/3 | ✔ |
| Trust valid | `trust validate-store` → `valid: true`, **problems: []**, aggregate `53605e4e…` | ✔ |

### 1.1 Next identities, derived from live counters

Read from the sequence files, not inferred from the record names:

| counter | value | next |
| --- | --- | --- |
| `capability-advertisement.seq` | 5 | **CADV-000006** |
| `capability-instance.seq` | 4 | **CINST-000005** |
| `capability-route.seq` | 4 | **CROUTE-0005** |
| `capability-selection.seq` | 3 | **CSEL-000004** |
| `capability-invocation.seq` | 2 | **CINV-000003** |
| `capability-result.seq` | 1 | **CRES-000002** |

All six match the expected conceptual values. Confirmed a second time by
inventory: the stores hold `CADV-000001..5`, `CINST-000001..4`,
`CROUTE-0001..4`, `CSEL-000001..3`. Note the route identifier is **four**
digits (`CROUTE-0005`), matching the existing records, not six.

---

## 2. The expired chain, reconfirmed

| record | field | value |
| --- | --- | --- |
| CADV-000005 | `valid_until` | `2026-09-10T21:30:00-05:00` |
| CINST-000004 | `admitted_until` | `2026-09-10T21:30:00-05:00` |

`compute-eligibility` for CINST-000004, evaluated at `2026-09-13T20:06:56-05:00`:

```
eligible: false
unmet:    ["ELIG-6", "ELIG-7"]
reasons:  ["advertisement-not-fresh", "admission-window-expired"]
```

**Ten of twelve conditions are met.** ELIG-1 through ELIG-5 and ELIG-8 through
ELIG-12 all report `met` with `reason: null`. The only failures are the two
expected expiry/freshness reasons — nothing else in the chain moved. Trust,
package manifest, host admission, contract satisfaction and scope are all
still good.

Nothing was renewed.

---

## 3. CADV-000006 — prepared

| | |
| --- | --- |
| `supersedes` | CADV-000005 |
| `observed_at` | `2026-09-13T19:00:00-05:00` |
| `recorded_at` | `2026-09-13T19:00:00-05:00` |
| `valid_until` | `2026-09-17T19:00:00-05:00` |
| `request_id` | `g11bcj-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000005` |
| **frozen file SHA256** | `a55e1c38f237c45558b48f28c8b5d7084fa0d9df02cc5fb659d03e1b3a49013d` |
| **bytes** | 673 |
| **request digest** | `sha256:76a99d3ee1a21b7bb55cb33c366d13686b0813a526f7e2bf474d12324bd09675` |

### 3.1 The validity window, chosen deliberately

The observed history: 1 day, 1 day, 2 days, 4 days, 4 days.

```
CADV-000001  2026-08-26T14:13:53 -> 2026-08-27T14:13:53   1 day
CADV-000002  2026-08-28T09:24:51 -> 2026-08-29T09:24:51   1 day
CADV-000003  2026-08-28T16:19:19 -> 2026-08-30T16:19:19   2 days
CADV-000004  2026-09-02T12:02:14 -> 2026-09-06T12:02:14   4 days
CADV-000005  2026-09-06T21:30:00 -> 2026-09-10T21:30:00   4 days
```

**There is still no maximum-window policy.** `admission.py:1367–1382` enforces
only `valid_until > observed_at` and `observed_at <= recorded_at < valid_until`.
G11-BB-T recorded that a ten-year window was rehearsed and accepted by the
engine. That remains true and remains an open architecture gap; this checkpoint
does not close it and must not close it by choosing a number.

**Four days is chosen because it is the reviewed precedent, not because it is
convenient.** It is not an escalation over CADV-000004 or CADV-000005. Given §0,
the window is the constraint that forces the renewal to be spent rather than
left lying around: if the guard checkpoint slips, `register-advertisement`
refuses with `invalid-validity-window` rather than installing a stale lease.
That is the fail-closed behaviour working, and it is the reason not to stretch
the window to cover an unknown delay.

### 3.2 Why the frozen bodies do not decay

Every instant in all four bodies is a **literal**, never `$(date -Is)`. The
engine requires `observed_at <= recorded_at < valid_until` over those literals,
so the digest an operator renders tomorrow is the digest pinned here. All four
instants are already in the past (rendered at 20:09 local; the latest instant is
19:45), so there is no wait before the blocks can be run.

### 3.3 Freeze block — CADV-000006

```bash
bash <<'FREEZE_CADV'
set -Eeuo pipefail
DEST=/etc/kyri/fabric/cadv-000006.json
REVIEWED=a55e1c38f237c45558b48f28c8b5d7084fa0d9df02cc5fb659d03e1b3a49013d
REVIEWED_BYTES=673

# Bodies that are NOT this one, refused BY NAME. The first is a draft from this
# same checkpoint that the engine ACCEPTS -- verified, not assumed: preflighting
# 3d9ed123 against a copy of production returned would_accept true and
# predicted_record_id CADV-000006. So this block is the only thing between a
# stale paste and an immutable record nobody reviewed.
SUPERSEDED_2130_DRAFT=3d9ed12316d94d114857e1068cf2a0ea74d9d1a0fd8468c9164bc81254ecfb75
ACCEPTED_CADV5=ee862cc2d9d946df895962fe6f165e610554813f0d712b5c1dbac67c83cd09ad

printf '\n--- /etc/kyri/fabric BEFORE ---\n'
sudo find /etc/kyri/fabric -mindepth 1 -printf '%p  %u:%g  %m  %s\n' | sort

sudo test ! -e "${DEST}" || { echo "REFUSE: ${DEST} already exists"; exit 1; }

TMP="$(mktemp)"
cat > "${TMP}" <<'BODY'
{
  "request_id": "g11bcj-register-advertisement-cpkg-0001-chost-0001-supersedes-cadv-000005",
  "actor": "CHOST-0001",
  "recorded_at": "2026-09-13T19:00:00-05:00",
  "capability_host_id": "CHOST-0001",
  "capability_package_id": "CPKG-0001",
  "contract_id": "CCON-0001",
  "satisfied_contract_versions": [
    "1.0.0"
  ],
  "advertised_resource_profile": {
    "architecture": "x86-64"
  },
  "observed_at": "2026-09-13T19:00:00-05:00",
  "valid_until": "2026-09-17T19:00:00-05:00",
  "supersedes": "CADV-000005",
  "provenance": {
    "class": "declared",
    "source": "docs/decisions/ADR-0012-distributed-capability-fabric.md",
    "recorded_at": "2026-09-13"
  }
}
BODY

ACTUAL="$(sha256sum "${TMP}" | cut -d' ' -f1)"
case "${ACTUAL}" in
  "${SUPERSEDED_2130_DRAFT}")
    echo "REFUSE: this is the SUPERSEDED G11-BC-J 21:30 draft, not the reviewed body"
    rm -f "${TMP}"; exit 1 ;;
  "${ACCEPTED_CADV5}")
    echo "REFUSE: this is the already-accepted CADV-000005 input"
    rm -f "${TMP}"; exit 1 ;;
esac
test "${ACTUAL}" = "${REVIEWED}" || {
  echo "REFUSE: rendered ${ACTUAL}, reviewed ${REVIEWED}"; rm -f "${TMP}"; exit 1; }
test "$(wc -c < "${TMP}")" = "${REVIEWED_BYTES}" || {
  echo "REFUSE: rendered $(wc -c < "${TMP}") bytes, reviewed ${REVIEWED_BYTES}"
  rm -f "${TMP}"; exit 1; }

sudo install -o root -g cschott -m 0640 "${TMP}" "${DEST}"
rm -f "${TMP}"

printf '\n--- frozen input ---\n'
sudo sha256sum "${DEST}"
sudo stat -c '%n  %U:%G  %a  %s bytes' "${DEST}"

printf '\n--- read-only preflight (NO Fabric write) ---\n'
cd /opt/schott-platform
python3 -m tools.fabric.cli register-advertisement \
  --store-root /var/lib/kyri/fabric --expected-uid 1000 --expected-gid 1000 \
  --evidence-root /var/lib/kyri/evidence --evidence-trusted-uid 0 \
  --input-file cadv-000006.json --approved-directory /etc/kyri/fabric --preflight

printf '\n--- production Fabric must be byte-identical to before ---\n'
find /var/lib/kyri/fabric -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
echo "expect 3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b  -"
FREEZE_CADV
```

Expected preflight: `would_accept true`, `mutated false`, `predicted_record_id
CADV-000006`, `destination_exists false`, `request_digest sha256:76a99d3e…`.

`root:cschott 0640` matches all twenty accepted inputs already in that
directory; live policy was read, not assumed.

---

## 4. CINST-000005 — prepared

| | |
| --- | --- |
| `supersedes` | CINST-000004 |
| `advertisement_id` | CADV-000006 |
| `admitted_at` / `recorded_at` / `evaluated_at` | `2026-09-13T19:15:00-05:00` |
| `admitted_until` | `2026-09-17T19:00:00-05:00` — equal to the advertisement's `valid_until`, which is the maximum the engine permits |
| `admission_decision_id` | `eng-0005-cinst-000005-admission` |
| binding root | CAPDEF-0001 / CCON-0001 / CPKG-0001 / CHOST-0001, versions `["1.0.0"]`, TREC-000002 (package) + TREC-000001 (host) |
| **frozen file SHA256** | `a242a4b3c7bef26fc8fcdcfcf1d3f9fad7a7b0d6671bfe17e949036013a52f5b` |
| **bytes** | 1269 |
| **request digest** | `sha256:ff9f534c0197dbc42c5c8169cb05ab19e85599582bc1b391a432345607f103b7` |

### 4.1 Requested scope == effective scope, proven not assumed

The rehearsal write produced CINST-000005 in the copy, and its `effective_scope`
was compared field-for-field against the input's `admission_scope`:

```
requested: {"permitted_capabilities": ["CAPDEF-0001"],
            "permitted_data_classifications": ["internal"],
            "permitted_operations": ["execute"],
            "permitted_targets": ["HOST-0001"]}
effective: identical
verdict:   IDENTICAL -- no silent narrowing
```

`permitted_operations: ["execute"]` is unchanged and deliberately so. This is
the **Fabric** vocabulary; see §8.

Refusal digests for the freeze block: superseded 21:45 draft
`d812eb1b8fe0734857db357a373e47649d1ca1c661e8a3c77534c0388cf3bba4`, accepted
CINST-000004 input `5d268f703d01f5e07106e77333a766e23e1d489eddbb974d60f5d4522a5e699c`.
Destination `/etc/kyri/fabric/cinst-000005.json`, refused if it exists.
Preflight against the frozen input with `--trust-store-root /var/lib/kyri/trust`;
Fabric aggregate re-checked against `3fa32b83…` after.

---

## 5. CROUTE-0005 — prepared

| | |
| --- | --- |
| `supersedes` | CROUTE-0004 |
| `route_version` | **5** (CROUTE-0004 carries 4) |
| `candidate_instances` | `["CINST-000005"]` — the new live binding root and **nothing else** |
| `recorded_at` | `2026-09-13T19:30:00-05:00` |
| **frozen file SHA256** | `77aac8c8e8aa2e40a2bc9c9888ead1b9ecbb5444f41d8d1a1b41c7e2c483e1e3` |
| **bytes** | 678 |
| **request digest** | `sha256:147178472b2d970f5299907f5e4ccb16ccb8ec4250bce73363b6841279980de8` |

### 5.1 Eligibility fully green **before** the route was accepted

Required by the checkpoint, and this is the gate that was checked first. With
CADV-000006 and CINST-000005 applied to the rehearsal copy, evaluated at the
route's own `recorded_at`:

```
compute-eligibility --instance-id CINST-000005 --evaluated-at 2026-09-13T19:30:00-05:00
  eligible:       True
  unmet:          []
  reasons:        []
  conditions met: 12 of 12
```

Twelve of twelve. The route was only then preflighted and applied.

Refusal digests: superseded 22:00 draft
`19d09124c2de327a0f108e455be487b9d77be37b54ab24c05319201c13f5e308`, accepted
CROUTE-0004 input `bfb153831a11a28064ca1e6c0bbbbd7ad877667987866135c355ea0419a9aeda`.

---

## 6. CSEL-000004 — prepared

| | |
| --- | --- |
| route | CROUTE-0005 (version 5) |
| `recorded_at` / `evaluated_at` | `2026-09-13T19:45:00-05:00` |
| **frozen file SHA256** | `0f2b38d360adc17bec48d8b4c6558eb0d4daf461ebcfad518c078025b2fdef93` |
| **bytes** | 605 |
| **request digest** | `sha256:8f1ccea3c4bd9b8e4c449b4064d73dd524cccb71ccb606bd907235b5a6c1499a` |
| **`selected_instance_id`** | **`CINST-000005`** |

### 6.1 The prior lesson, applied

`would_accept: true` is not enough, and the freeze block pins the two facts
**separately**:

```
test "${DIGEST}"   = "sha256:8f1ccea3c4bd9b8e4c449b4064d73dd524cccb71ccb606bd907235b5a6c1499a"
test "${SELECTED}" = "CINST-000005"
```

`selected_instance_id` is reported by the **preflight itself**, so it can be
read and pinned before any write. That was confirmed in the rehearsal: the
preflight output carried `"selected_instance_id": "CINST-000005"` alongside
`"would_accept": true`, and the applied record carried the same. A selection
that accepted but resolved to some other instance would satisfy the digest pin
and fail this one.

Refusal digests: superseded 22:15 draft
`93c0e373c327d6d51c175c69edc2f8c8ab0c76399d57bf93f65dbb41f30b2690`, accepted
CSEL-000003 input `700a1390de06ffd770293c50c97391970337b8a2a8fd52b396e49060d453953e`.

---

## 7. The corrected payload

**Recomputed, and the recomputation found a discrepancy worth stating.**

`4257f93b…` / `272` from G11-BC-I is the **canonical** digest and canonical byte
count, not a raw file digest — G11-BC-I never wrote that document to a file. The
two are different numbers and both matter: the freeze block pins the **raw file**,
and the CINV record binds the **canonical** value. Pinning the canonical digest
as if it were the file digest would make the freeze refuse every time.

Two candidates, both computed:

| | option A — the G11-BC-I candidate verbatim | option B — **recommended** |
| --- | --- | --- |
| `operation` | `verify-execution-boundary` | `verify-execution-boundary` |
| `label` | `g11bb2-second-controlled-production-invoke` | `g11bcj-third-controlled-production-invoke` |
| `note` names | *"CINV-000002, on the CADV-000005 / CINST-000004 / CROUTE-0004 / CSEL-000003 chain"* | CINV-000003 on the renewed chain |
| raw file SHA256 | `4c9ff8900103c1cdd23bf863dbc5df390792f80d64b5b1dfd8991c383840de26` (301 bytes) | `9b7a603ca06da5b378a0b1d3a251fc4074f86192c61567109ec4687db003656f` (372 bytes) |
| canonical digest | `4257f93b90a4e51702866bac2f5e5a64c5a62f019c0c357b7d377be858fd31df` (272 bytes) | `be85d58fc410c9de2e501e4721a524b92b4a83865eb4be34db38346262b60749` (343 bytes) |

Option A reproduces G11-BC-I's expected canonical value exactly, which confirms
the recomputation is sound. **It is not recommended.** Its note states that this
is CINV-000002 on a chain that is now expired and superseded — false on both
counts for CINV-000003. This whole sequence exists because a payload field said
something untrue, and shipping a second payload with a false self-description
to fix the first would be a poor trade.

Option B changes `operation` (the correction), `label`, and `note` (so the
document describes itself accurately) and nothing else: `arguments.count` stays
1 and the controlled-production semantics are unchanged.

**Option B is prepared and pinned. If the reviewer prefers A, say so and the
freeze block takes `4c9ff890…` / 301 bytes instead** — one substitution, no
other change.

### 7.1 The full invocation, preflighted end to end

Against copies of *both* stores — the rehearsal Fabric with all four new records
applied, and a copy of the runtime store:

```
outcome                          preflight
would_accept                     true
would_refuse_reason              null
predicted_invocation_record_id   CINV-000003
selection_id                     CSEL-000004
instance_id                      CINST-000005
operation                        execute            <- the FABRIC verb
payload_digest                   sha256:be85d58f…   <- the CAPABILITY verb inside
package_tree_sha256              sha256:6f2282c5…
current_eligibility              true
eligibility_reasons              []
scope_permits_operation          true
helper_compatibility             compatible
supervision_ready                true
```

`execution_image_available: false` is an artefact of the rehearsal running as
`cschott`, which cannot read the `kyri-capability` rootless image store. The
image is present; the G11-BC-G operator check confirmed
`5cee2b53…` under the execution identity.

Nothing was allocated, in production or in the copy: the copy's sequences are
still 2 and 1 and its invocation directory still holds only CINV-000001 and
CINV-000002.

---

## 8. The two vocabularies

```
Fabric operation           execute
  declared in              CINST-000005.effective_scope.permitted_operations
  checked by               fabric_evidence.evaluate, via the scope gate
  carried on               the CINV record, from --operation

Provider payload operation verify-execution-boundary
  declared in              result_content.OPERATIONS
  checked by               packages/kyri-execution-boundary-verification/1.0.0/main.py
                           and again by the collector on the result document
  carried in               the payload document's `operation` field
```

**These are different namespaces.** The §7.1 preflight shows both correct
simultaneously — `operation: execute` accepted by the scope gate while the bound
payload carries `verify-execution-boundary`. Swapping either one breaks the
invocation at a different boundary.

Fabric's `permitted_operations` semantics are **not** weakened. `["execute"]` is
unchanged in CINST-000005, and a new regression case proves the provider still
refuses `execute` after the correction — the fix is the payload's value, not a
loosening of either vocabulary.

`tests/test-capability-execution-payload-operation-contract.sh` now carries 13
assertions. The three added here pin the prepared payload: its canonical digest
(`be85d58f…`, 343 bytes), that it satisfies the provider contract end to end and
produces a `result.json` passing `validate_result_content` whose
`payload_digest` is that same value, and that the Fabric verb is still refused.

---

## 9. The authority gap

```
PAYLOAD_OPERATION_AUTHORITY_GAP=OPEN
```

No authority cross-checks the provider payload's operation vocabulary against
Fabric. `payload.py` types `operation` as `_Field(kind=str, required=True)` —
closed against unknown *fields*, open to any *value* — and no Fabric record
declares what operations a capability performs, so the coordinator has nothing
to check against.

**Nothing was invented here.** No provider vocabulary was encoded into CADV,
CINST, CROUTE or CSEL; the four bodies in §3–§6 carry no capability operation
name anywhere. The only thing standing between a wrong payload operation and a
second `provider-error` is the regression suite in §8 and the reviewer reading
the value — which is why it stays recorded as a gap rather than quietly patched.

---

## 10. The execution blocker

```
CINV_000003_EXECUTION_BLOCKED_BY_DUPLICATE_RESULT_GUARD=YES
```

Per the reviewer's ruling, no production invocation may execute until the
separate duplicate-result pre-execution guard checkpoint is accepted. G11-BC-I
§10.1 established why: the guard in `evidence.record_terminal_result` fires
*after* `supervisor.execute(binding)`, so a re-execute runs the governed
container and only then refuses to record.

**Proof that nothing here clears that gate:**

- `git diff --stat HEAD -- tools/ provisioning/` is **empty**. No runtime,
  helper, coordinator or guard code was touched. `evidence.py` is unmodified.
- No CINV-000003 exists, so there is nothing for `authorise-launch` to
  authorise and nothing for `execute` to name. Both commands take a CINV and
  refuse an absent one.
- No launch-authorisation and no handoff exist for CINV-000003.
- The four freeze blocks write to `/etc/kyri/fabric` and, when run, to the
  Fabric store. Neither is on the execution path: `execute` reads the
  capability-runtime store and the launch authorisation, not Fabric.

Renewing the Fabric chain makes CINV-000003 *allocatable*. It does not make it
*executable*, and the two are separate authorisations.

---

## 11. No new invocation

| required | actual |
| --- | --- |
| CINV sequence = 2 | 2 |
| CRES sequence = 1 | 1 |
| CINV-000003 absent | only `CINV-000001.yaml`, `CINV-000002.yaml` |
| CRES-000002 absent | only `CRES-000001.yaml` |
| no staging tree for CINV-000003 | staging holds one entry, `tree-sha256-6f2282c5…`, pre-existing from CINV-000002 |
| no handoff for CINV-000003 | handoff holds `CINV-000001`, `CINV-000002` |

One subtlety worth naming: `would_stage_at` in the §7.1 preflight points at
`tree-sha256-6f2282c5…`, which **already exists**. The staging path is keyed by
the *package tree digest*, not by the invocation, and CINV-000003 uses the same
governed package as CINV-000002. So a green preflight naming an existing staging
path is correct and is not evidence that anything was created.

---

## 12. Validation

| | |
| --- | --- |
| Fabric focused suites | `test-capability-fabric`, `test-fabric-admission-dependency-bound`, `test-fabric-advertisement-preflight`, `test-fabric-evidence-authority`, `test-fabric-g11-integrity`, `test-fabric-instance-admission-integrity`, `test-fabric-preflight`, `test-fabric-route-head`, `test-fabric-route-preflight`, `test-fabric-runtime` — all PASS |
| payload-operation-contract | PASS, 13 assertions |
| selection-resolution / eligibility | `test-capability-invoke-current-eligibility`, `test-capability-invocation-operation-authority` — PASS |
| invocation preparation | `test-capability-invoke-preflight` — PASS |

Local quick, local full, host-only, six CI workflows and clean clone are
recorded in the RETURN block.

---

## 13. Production non-mutation

| | before | after |
| --- | --- | --- |
| Fabric aggregate | `3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b` | identical |
| Trust aggregate | `53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f` | identical |
| `CINV-000002.yaml` | `923ff0d7…` | identical |
| `CRES-000001.yaml` | `18ba4c34…` | identical |
| CINV / CRES sequences | 2 / 1 | 2 / 1 |
| `/etc/kyri/fabric` | 20 entries | 20 entries — no new frozen input written |
| handoff | CINV-000001, CINV-000002 | identical |

No Fabric write, no Trust write, no CINV or CRES allocation, no `execute`, no
`recover`, no runtime or helper mutation, no sudoers change, no handoff change,
no image change. Every engine call that mutated anything ran against a copy
under the session scratch directory.

---

## 14. Next

Reviewer accepts this preparation. Then, **before** any of the four freeze
blocks are run (see §0):

**G11-BC-K — the duplicate-result pre-execution guard.** Move the check that
refuses a second terminal result to before `supervisor.execute(binding)`, so a
re-execute refuses without creating a container. Blocking for any CINV-000003
execution.

After that checkpoint is accepted, run §3 → §4 → §5 → §6 in order, each
returning its output for review, then prepare CINV-000003 Stage 1 with the
Option B payload.

The G11-BC-G evidence remediation remains prepared and unauthorised; it is
independent of all of this.
