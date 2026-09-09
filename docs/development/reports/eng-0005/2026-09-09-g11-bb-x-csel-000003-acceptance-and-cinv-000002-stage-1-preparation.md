# ENG-0005 G11-BB-X — CSEL-000003 acceptance, and CINV-000002 Stage-1 preparation

**Status: the `CSEL-000003` write is independently verified and accepted. The
fresh Fabric chain is complete and eligible on all twelve conditions. Stage 0 and
Stage 1 for `CINV-000002` are prepared and rehearsed read-only. Nothing was
invoked; `CINV-000002` is unspent.**

```
FABRIC_CHAIN_FRESH          YES   CADV-000005 -> CINST-000004 -> CROUTE-0004 -> CSEL-000003
CURRENT_ELIGIBILITY         PASS  ELIG-1..12
WINDOW_REMAINING            1 day 14:01:12   (closes 2026-09-10T21:30:00-05:00)
SUPERVISION_READY           true
CINV_000002_SPENT           NO
STAGE2_AUTHORISED           NO      STAGE3_AUTHORISED  NO
PRODUCTION_INVOKE_AUTHORISED NO
```

Branch `arch/eng-0005-execution-transition`.

---

## 1. The CSEL-000003 write, verified independently

```
selection_id            CSEL-000003
route_id                CROUTE-0004        route_version           4
selected_instance_id    CINST-000004
considered_candidates   [CINST-000004]     excluded_candidates     []
local_node_identity     HOST-0001
selection_reason        first eligible candidate in declared order
evidence.reason_category    selection
evidence.causal_references  [CROUTE-0004, CINST-000004]
evidence.request_id         g11bbw-select-capdef-0001-ccon-0001-internal-local-only-host-0001-croute-0004
evidence.request_digest     sha256:ca00000e4d9f1dc524c5af7f28fd549c9eb48820cc7888f5a8ba2219aaf80a06

request_class   capability_id CAPDEF-0001   contract_id CCON-0001
                accepted_contract_versions [1.0.0]
                data_classification internal   locality local-only

CSEL_STORED_SHA256      f7c173e15a8762cc624502a79479364eb27bf65cb347779e2114752000467a9f
```

Every field matches G11-BB-W §3–§4, including the reviewed request digest, and
`selected_instance_id` is `CINST-000004` — the gate that checkpoint installed.

### 1.1 The delta, by content reconstruction

```
CREATE   /var/lib/kyri/fabric/capability-selections/CSEL-000003.yaml
REPLACE  /var/lib/kyri/fabric/sequences/capability-selection.seq
           before  53c234e5e8472b6ac51c1ae1cab3fe06fad053beb8ebfd8977b010655bfdd3c3   b"2\n"
           after   1121cfccd5913f0a63fec40a6ffd44ea64f9dc135c66634ba001d10bcf4302a2   b"3\n"
REMOVE   none

reconstructed pre-write aggregate  ce6f7db2335bc8dd7b1cc19166a67531766657476d050796c1861bd2c5a33d61
operator-reported pre-write        ce6f7db2335bc8dd7b1cc19166a67531766657476d050796c1861bd2c5a33d61   MATCH

post-write aggregate               3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b
```

Exactly three paths carry the write instant, and nothing else in the store is
newer:

```
2026-09-09 07:21:01.361  sequences/capability-selection.seq
2026-09-09 07:21:01.367  capability-selections/CSEL-000003.yaml
2026-09-09 07:21:01.369  capability-selections/            (directory entry)
```

```
CSEL-000001  e08a4df4ab758cb0d25609e3cc02b4adca7568ff464b312ac3a2c88b8bbe79bb  mtime 2026-08-28 20:59:49  UNCHANGED
CSEL-000002  d344c89729ebbfed61a928881c1933deb235b77df19031469085c49d634a4ccb  mtime 2026-09-03 18:11:44  UNCHANGED
trust        53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f            UNCHANGED

fabric validate  valid, findings []   CADV 5  CINST 4  CROUTE 4  CSEL 3
trust  validate  valid, problems []
```

**No sole-head model is applied to selections.** None of the three carries a
`supersedes` field, so all three are unsuperseded and that is the designed
shape, not a fork:

```
CSEL-000001  route CROUTE-0002 v2  selected CINST-000002   has_supersedes False
CSEL-000002  route CROUTE-0003 v3  selected CINST-000003   has_supersedes False
CSEL-000003  route CROUTE-0004 v4  selected CINST-000004   has_supersedes False
```

`CINV-000001` names `CSEL-000002`, which is untouched historical evidence.

## 2. The fresh chain, and the lease

```
capability-advertisement  seq=5  heads=[CADV-000005]
capability-instance       seq=4  heads=[CINST-000004]
capability-route          seq=4  heads=[CROUTE-0004]
capability-selection      seq=3  (no supersedes field on any selection)

CSEL-000003 binds CROUTE-0004 / CINST-000004
```

Eligibility, released logic, live, at `2026-09-09T05:57:48-05:00`:

```
ELIG-1 .. ELIG-12   all met      unmet []      eligible = true
```

```
FABRIC_CHAIN_FRESH  YES        CURRENT_ELIGIBILITY  PASS
WINDOW_REMAINING    1 day, 14:01:12    both windows close 2026-09-10T21:30:00-05:00
```

### 2.1 Is the window sufficient? Yes — and here is why the question is narrower than it looks

**Eligibility is evaluated exactly once, at Stage 1, and never again.**
`verify_selected_evidence` — which calls `evaluate_eligibility` and owns
`REASON_INELIGIBLE` — is reached from `coordinator.prepare_invocation` and from
`command_preflight`, and from nowhere else. `authorise_launch` (Stage 2)
validates the prepared record, re-presents the payload against the digest the
record already committed to, and validates the package; it does not open the
Fabric. `command_execute` (Stage 3) says so in its own docstring:

> *It decides nothing about whether execution is permitted. That was decided
> twice already: `invoke` verified eligibility and spent the identity, and
> `authorise-launch` published the handoff and wrote the authorisation.*

Further, the instant eligibility is judged at is `requested_at` — the
operator-supplied argument on the invoke command — not a clock.

**So the lease has to cover the `requested_at` of Stage 1 only.** Stages 2 and 3
are unaffected by its expiry. With 1 day 14 h remaining, that is comfortable, and
**no renewal is required before spending `CINV-000002`.**

The corollary is worth stating plainly rather than leaving implicit: if Stage 1
lands and Stages 2–3 slip past `2026-09-10T21:30`, they will still proceed,
because nothing downstream re-asks. That is the designed division of
responsibility, not an oversight — but it means the lease is a bound on *when
the decision may be made*, not on *when the work may run*.

## 3. Runtime and supervision

Measured from the released calculation against the installed runtime:

```
coordinator_identity_authority  true      execution_identity_authority  true
execution_identity_account      kyri-capability
helper_compatibility            compatible      helpers_blocking  []
supervision_ready               true
launch_grant                    unobservable    reconcile_grant   unobservable
```

Installed bytes, at the digests the reviewed authority `ef4f744` declares:

```
/usr/libexec/kyri-exec-worker.py                      2d320630aca559c747522bb528f87172e747f30a182db0fec70e31eca272ddf5
/usr/lib/kyri/python/kyri_exec_transition_action.py   b11a2f19bc469ae4494fbcb08798e02124f2ceced7f9d0d239fad600822be315
/usr/lib/kyri/python/kyri_exec_quota.py               54a9b15c6c6e3b785218d75c91b896f0723d3bf2051ebfca1351c84aa9855ca7
/usr/libexec/kyri-exec-transition                     0d9c8d8c918198ba6d07ba2e84c7bbca3a4a1c7f78d96ba79463d2617ede51a1
/usr/libexec/kyri-exec-reconcile                      2878fff04bb20b358cc82b2686989b7a47df7f67e99296dfa15226db75798f77
```

### 3.1 What I could not verify, and did not

Three items in the authorisation need privilege the coordinator does not have.
**None is claimed above.**

```
/etc/sudoers.d/kyri-exec-launch      -r--r----- root:root   present, CONTENTS UNREADABLE
/etc/sudoers.d/kyri-exec-reconcile   -r--r----- root:root   present, CONTENTS UNREADABLE
/etc/sudoers.d/kyri-exec-verify      ABSENT                 (directory listing is readable)
```

The two grants exist and the verification grant is absent — that much the
directory shows. **Whether each grant pins the installed entrypoint by digest is
not observable to me**, which is exactly why the released surface reports both as
`unobservable` rather than guessing. `GEN15_VERIFY_INSTALLED` is likewise the
operator's earlier result, not a fresh measurement: it needs root.

### 3.2 `execution_image_available: false` is blindness, not absence — read it carefully

The Stage-1 preflight (§6) reports:

```
execution_image_id         5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
execution_image_available  false
```

**The image id is right and the `false` is a false negative.** `_execution_outlook`
constructs `RootlessImageStore()` with no home, so it resolves `$HOME` — the
*coordinator's* home — and finds no `images.json`; the exception is swallowed and
the field is set to `False`. Pointed at the execution identity's real store it
gives `Permission denied`, because that store is `kyri-capability:kyri-capability 750`:

```
RootlessImageStore(home=None)                    ImageStoreUnreadable: images.json missing
RootlessImageStore(home='/data/kyri/capability') ImageStoreUnreadable: Permission denied
```

So the field reports `false` on every coordinator-run preflight regardless of
whether the image is present. It is the same visibility boundary the grants sit
behind — but where the grants honestly say `unobservable`, this one asserts a
definite `false` an operator could reasonably read as a blocker. Recorded as a
defect in §10; it does not affect Stage 1, which never consults it.

```
IMAGE_AUTHORITY = declared id matches (5cee2b53…); PRESENCE OPERATOR-VERIFIABLE ONLY
```

The image's presence in the execution identity's store is the operator command in
§9.

## 4. Invocation history anchor

```
CINV-000001 sha256   1dcef40d0ca289e5c65642cd3f704be864529ffb26b05cfbe1b8cb087d6cfaaa   unchanged
            outcome  execution-prepared   adapter_identity null
            selection_id CSEL-000002      instance_id CINST-000003
            -> permanently UNRESOLVED, resume FORBIDDEN

CINV_COUNT 1     CRES_COUNT 0     CINV_NEXT CINV-000002     CRES_NEXT CRES-000001
validate_store   findings ()

no CINV-000002 state exists anywhere under /data/kyri/capability-runtime
execution plane holds only CINV-000001 (launch-authorisation, two transitions, one lock)
handoff root holds only CINV-000001
```

Container state is **not** claimed: listing the execution account's containers
needs `sudo runuser -u kyri-capability`. The operator command is in §9. Historical
`trackb-*` containers must remain.

## 5. Stage 0 — the payload, and the three digests kept apart

A **fresh** payload for the second invocation, in a fresh approved root, labelled
so it can never be confused with the first.

```
STAGE-0 ROOT        /data/kyri/work/g11bb2      (fresh; the first used /data/kyri/work/g11bb)
STAGE-0 FILE        second-invoke.json
raw source SHA256   e12a525c289458f49ae1f5ae073ac97aac927627f15ac2a2450557f4cad65127
raw source bytes    283
```

**The raw digest and the governed digest are different values over the same
document, and must not be conflated:**

| | value | what it is |
| --- | --- | --- |
| **raw source SHA256** | `e12a525c…` | `sha256sum` of the 283 bytes on disk, including layout and trailing newline. What the operator checks after writing the file. |
| **governed `payload_digest`** | `sha256:e2914a90…` | `invocation_identity.payload_digest` — sha256 over `canonical_json.serialise(document)`, 254 canonical bytes. **This is what `CINV-000002` will record**, and what Stage 2 re-presents against. |

They are not equal and there is no reason they should be: reformatting the file
changes the first and not the second. The schema validated at
`schema_version = 1`; `operation` and `arguments.count` are required, `label` and
`note` optional, and the schema is closed — a `schema_version` key inside the
document is refused as an unknown field (§8, P6).

```bash
# STAGE 0 -- creates only the reviewed operator work area. No Fabric, no CINV.
mkdir -p -m 0700 /data/kyri/work/g11bb2
cat > /data/kyri/work/g11bb2/second-invoke.json <<'JSON'
{
  "operation": "execute",
  "arguments": {
    "count": 1,
    "label": "g11bb2-second-controlled-production-invoke"
  },
  "note": "ENG-0005 G11-BB2: the second controlled production invocation, CINV-000002, on the CADV-000005 / CINST-000004 / CROUTE-0004 / CSEL-000003 chain."
}
JSON
chmod 0600 /data/kyri/work/g11bb2/second-invoke.json

# REFUSE unless the raw bytes are the reviewed ones.
ACTUAL="$(sha256sum /data/kyri/work/g11bb2/second-invoke.json | cut -d' ' -f1)"
test "${ACTUAL}" = "e12a525c289458f49ae1f5ae073ac97aac927627f15ac2a2450557f4cad65127" || {
  echo "REFUSE: rendered ${ACTUAL}, reviewed e12a525c289458f49ae1f5ae073ac97aac927627f15ac2a2450557f4cad65127"
  exit 1; }
test "$(wc -c < /data/kyri/work/g11bb2/second-invoke.json)" = "283" || {
  echo "REFUSE: wrong byte count"; exit 1; }

stat -c '%n %U:%G %a %s bytes' /data/kyri/work/g11bb2 /data/kyri/work/g11bb2/second-invoke.json
#   require: both cschott:cschott, root 700, file 600

# Container baseline immediately before the ceremony.
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
#   require: only pre-existing trackb-*; NO kyri-CINV-*
#   also confirms the execution image is present:
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman images --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}'
#   require: 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
#            localhost/kyri-capability-execution:g5
#   Do NOT pull, build, load or retag anything.
```

## 6. Stage 1 — the command, and what it should do

Every argument re-derived from the installed CLI parser and current production
authorities, not copied.

```bash
# STAGE 1 -- prepares and allocates CINV-000002. EXPECT rc=1. See below.
cd /opt/schott-platform
python3 -m tools.capability.cli invoke \
  --store-root /data/kyri/capability-runtime \
  --expected-uid 1000 --expected-gid 1000 \
  --fabric-root /var/lib/kyri/fabric \
  --fabric-expected-uid 1000 --fabric-expected-gid 1000 \
  --approved-artifact-root /var/lib/kyri/artifacts \
  --trusted-source-uid 0 \
  --staging-root /data/kyri/capability-runtime/staging \
  --coordinator-uid 1000 \
  --approved-payload-root /data/kyri/work/g11bb2 \
  --payload-source-uid 1000 \
  --payload-file second-invoke.json \
  --invocation-id g11bb2-second-controlled-invoke \
  --selection-id CSEL-000003 \
  --instance-id CINST-000004 \
  --package-id CPKG-0001 \
  --operation execute \
  --trust-store-root /var/lib/kyri/trust \
  --actor primary-platform-operator \
  --request-id g11bb2-second-production-invoke \
  --requested-at "$(date -Is)" ; echo "rc=$?"

# Capture the immutable record before going any further.
sha256sum /data/kyri/capability-runtime/capability-invocations/CINV-000002.yaml
cat /data/kyri/capability-runtime/sequences/capability-invocation.seq
```

### 6.1 **Exit 1 IS SUCCESS. Do not treat it as a failure.**

Derived from the installed Generation-15 source, not assumed from `CINV-000001`:

- `command_invoke` calls `prepare_invocation` **without** `adapter` or
  `execution_binding`; both default to `None`.
- `_bound_adapter_identity(None, None)` is therefore `None`, so nothing executes
  inline and the record's `adapter_identity` is `null`.
- `command_invoke` ends with an **unconditional** `return EXIT_DENIED`, under the
  comment *"Every outcome reachable here is a governed negative"*. `EXIT_DENIED`
  is `1`.

So a fully successful Stage 1 writes an immutable `CINV` **and exits 1**. The
JSON is the verdict; the exit code is not.

### 6.2 Expected Stage-1 output

Rehearsed read-only against production (§7):

```
EXPECTED_STAGE1_STATUS          prepared
EXPECTED_STAGE1_REASON          no_authorised_adapter
EXPECTED_STAGE1_PROCESS_EXIT    1
EXPECTED_CINV_ID                CINV-000002

invocation_id          g11bb2-second-controlled-invoke
result_record_id       null            <- no CRES is written at Stage 1; CRES_NEXT stays CRES-000001
adapter_identity       null            <- recorded in the CINV; nothing was authorised to run
payload_digest         sha256:e2914a9086558b3d67813d8a409a47064db9b83d76f62b6bc9b4c2a2b948533c
binding_digest         sha256:58ef2481b2eae49d9b75f90edf3d58d164455704e6029d170ca524bc06dbb5da
artifact_digest        sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
staged_path            /data/kyri/capability-runtime/staging/tree-sha256-6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
selection_id           CSEL-000003     instance_id  CINST-000004
```

**Stop and report if `status` is anything other than `prepared`, if
`invocation_record_id` is not `CINV-000002`, or if `staged_path` is null.**

`adapter_identity: null` is the field that makes an unresolved invocation
distinguishable later: it says no mechanism was ever authorised, so an absent
result means nothing was attempted rather than that something ran unaccounted
for.

## 7. The Stage-1 rehearsal, executed read-only

`invoke --preflight` runs the same governed path against the same stores opened
read-only and stops at the allocation boundary. Run against production with the
reviewed payload:

```
would_accept                    true       would_refuse_reason  null
current_eligibility             true       eligibility_reasons  []
predicted_invocation_record_id  CINV-000002
selection_id CSEL-000003        instance_id CINST-000004
scope_permits_operation         true
payload_digest    sha256:e2914a9086558b3d67813d8a409a47064db9b83d76f62b6bc9b4c2a2b948533c
binding_digest    sha256:58ef2481b2eae49d9b75f90edf3d58d164455704e6029d170ca524bc06dbb5da
package_tree_sha256  sha256:6f2282c58ad8d5bf5a463ca09b8a2c5c3f3faef31aea95e2b07100720e6c9a8e
would_stage_at    /data/kyri/capability-runtime/staging/tree-sha256-6f2282c5…

implementation_id CIMP-000001   execution_backend python-podman-v1
argv_contract     fixed-python-entrypoint-v1
execution_image_id 5cee2b5305b5c5ebe3e8f4facfd1a6cc2c2057a7d301d6869783dddc463f5190
execution_image_available false           <- §3.2: blindness, not absence
adapter_authorised        false           <- why Stage 1 stops at no_authorised_adapter
supervision_ready         true    helper_compatibility compatible    helpers_blocking []
```

The preflight's `payload_digest` equals the governed digest computed
independently in §5. Capability-runtime store and Fabric were byte-identical
before and after.

## 8. Negative and safety battery

All read-only, against production or fixtures. **The capability-runtime store was
byte-identical before and after the entire battery** — no `CINV`, no `CRES`, no
sequence movement.

| # | input | `would_accept` | reason |
| --- | --- | --- | --- |
| — | **the reviewed request** | **true** | — |
| N1 | wrong selection `CSEL-000002` (the historical one) | false | `claimed-instance-not-selected` |
| N1b | wrong selection `CSEL-000001` | false | `claimed-instance-not-selected` |
| N1c | selection that does not exist | false | `selection-not-found` |
| N2 | wrong instance `CINST-000003` (superseded, ineligible) | false | `claimed-instance-not-selected` |
| N2b | wrong instance `CINST-000001` | false | `claimed-instance-not-selected` |
| N2c | instance that does not exist | false | `claimed-instance-not-selected` |
| N3 | wrong package `CPKG-0002` | false | `claimed-package-not-bound` |
| N4 | operation `administer` | false | `operation-not-permitted-by-scope` |
| N5 | `requested_at` after the lease closes | false | `admission-window-not-open` |
| P1 | payload name traversing out of the approved root | refused, rc=2 | `a trusted source name may not traverse` |
| P3 | wrong `--payload-source-uid` | refused, rc=2 | trusted-source check |
| P4 | other-writable approved root (`0777`) | refused, rc=2 | `the approved root is writable` |
| P4b | group-writable approved root (`0770`) | refused, rc=2 | same |
| P6 | payload carrying an unknown field | refused | `SchemaViolation: unknown field 'schema_version'` |

Three results need stating rather than tabulating, because they are not what the
authorisation expected.

**P2 — "payload outside approved root" is enforced as ownership and mode, not as
a fixed pathname.** A *different* directory with the right owner and `0700` is
accepted with the identical digest. The platform pins that the named root is
coordinator-owned and not group/other-writable; it does not pin *which* root is
"the approved" one. That is operator discipline, and it is why the Stage-0 block
pins the raw digest.

**P5 — a payload changed after review is ACCEPTED at Stage 1**, and simply binds
a different `payload_digest` (`sha256:6c732ed5…` for a `count: 2` variant). Stage
1 records whatever it is given. The protection lives at **Stage 2**, where
`authorise_launch` re-presents the payload and refuses on mismatch:

```
if invocation_payload_digest(payload_binding.document) != record.get("payload_digest"):
    raise LaunchRefused("the presented payload is not the one CINV-000002 was prepared with")
```

So the operator's protection at Stage 1 is the raw-digest check in the Stage-0
block, and the platform's is the binding at Stage 2.

**Helper incompatibility, `supervision_ready: false`, and image mismatch do NOT
refuse Stage 1.** `_execution_outlook`'s own docstring says so: *"None of it is
required for preparation to succeed — preparation ends before the adapter — so
none of it makes a rehearsal refuse."* They gate later:

```
helper closure / supervision_ready   the coordinator refuses before crossing the
                                     privilege boundary (Stage 2/3)
image identity                       profile.py compare("oci_image_id", profile, observed)
                                     at container verification (Stage 3)
```

That ordering is correct — preparation is a decision, not an execution — but it
means a green Stage 1 is **not** evidence that Stage 3 can run.

## 9. Stages 2 and 3 — documented, NOT authorised

```
STAGE2_AUTHORISED = NO        STAGE3_AUTHORISED = NO
```

```bash
# STAGE 2 -- NOT AUTHORISED BY THIS CHECKPOINT.
python3 -m tools.capability.cli authorise-launch \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000002 \
  --cimp CIMP-000001 \
  --approved-payload-root /data/kyri/work/g11bb2 \
  --payload-file second-invoke.json \
  --package-entrypoint main.py ; echo "rc=$?"

# STAGE 3 -- NOT AUTHORISED BY THIS CHECKPOINT.
python3 -m tools.capability.cli execute \
  --expected-uid 1000 --expected-gid 1000 \
  --cinv CINV-000002 \
  --actor primary-platform-operator \
  --recorded-at "$(date -Is)" ; echo "rc=$?"
```

The **same** payload file is presented to Stages 1 and 2; its digest binds them.

### 9.1 The CINV-000001 defect cannot reproduce against these bytes

`CINV-000001` died at Stage 3 because the worker asked for `READ` on directories
the deployment grants only `TRAVERSE`. The G11-BB helper ceremony replaced the
three modules that did that with an `O_PATH` anchor, and the installed bytes are
the reviewed targets:

```
kyri-exec-worker.py                2d320630…  DEPLOYED   _ANCHOR_FLAGS = O_PATH|O_NOFOLLOW|O_CLOEXEC|O_DIRECTORY
kyri_exec_transition_action.py     b11a2f19…  DEPLOYED   _ANCHOR_FLAGS = O_PATH|…
kyri_exec_quota.py                 54a9b15c…  DEPLOYED   _ANCHOR_FLAGS = O_PATH|…
```

The reconciliation authority anchor is the same `transition_action` seam and is
deployed with it. The recovery-discovery fix is present in the installed runtime:
`recovery.py` carries the lifecycle-journal signature (`all_states`,
`_container_possible`, `lifecycle_state`) that G11-BB added so a supervised
invocation which lost supervision after creating a container is discoverable at
all — `CINV-000001` was invisible to the enumeration built to find it.

**This is deployment evidence, not an execution proof.** That the defect cannot
reproduce is an argument from the installed bytes and the helper ceremony's own
acceptance; only Stage 3 can demonstrate it, and Stage 3 is not authorised here.

### 9.2 Operator checks I could not perform

```bash
# Containers and the execution image, under the execution identity.
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman ps -a --format '{{.Names}} {{.Status}}'
sudo runuser -u kyri-capability -- env HOME=/data/kyri/capability \
  XDG_RUNTIME_DIR=/run/user/999 podman images --no-trunc

# The two grants, and that each pins the installed entrypoint by digest.
sudo cat /etc/sudoers.d/kyri-exec-launch /etc/sudoers.d/kyri-exec-reconcile
sudo sha256sum /usr/libexec/kyri-exec-transition /usr/libexec/kyri-exec-reconcile
```

## 10. Follow-ups

- **New:** `execution_image_available` reports a definite `false` on every
  coordinator-run preflight because it resolves the coordinator's own image
  store (§3.2). The grants in the same payload report `unobservable`; this field
  should too. It misreports rather than under-reports, which is the worse of the
  two.
- A selection that cannot resolve is accepted with `selected_instance_id: null`
  (G11-BB-W §5.1).
- `create_route` does not check candidate liveness or contract versions
  (G11-BB-V §5.1).
- Scope intersection silently narrows rather than refusing (G11-BB-U §6.1).
- The request digest covers neither `request_id` nor the resolved route.
- There is no maximum validity-window policy (G11-BB-T §2.1).

## 11. Validation

No source, test or provisioning file changed; this checkpoint adds this report
only.

```
FOCUSED INVOCATION/EXECUTION SUITES   17 suites, 1474 assertions, 0 FAIL
  capability-runtime 1089   invoke-preflight 36   invoke-current-eligibility 49
  execution-lifecycle 45    launch-bridge 31      launch-cli 26
  result-contract 12        protocol 34           collector 35
  coordinator-authority 44  authority-anchor      authority-gate 28
  handoff 42                handoff-root-traversal              supervised-execution-e2e
  invoke-execution-e2e      reconciliation

LOCAL_QUICK   PASS
LOCAL_FULL    PASS
GITHUB CI     6/6
CLEAN CLONE   PASS

capability-runtime store, before and after every rehearsal in this checkpoint
  3f400deafcb46071d2979a16965b23e9258f5a355587d4975062e96fc06a01dc   byte-identical
production Fabric
  3fa32b83902c07bc09e02711c15e1d4a714bcb97ed8de640c8ac1d961395b28b   byte-identical
production Trust
  53605e4e738d941ad5f1d2d2d08fe5cb776e484f6fee07f1123859d07828b63f   byte-identical

NO PRODUCTION CINV OR CRES WAS CREATED.
```

## 12. STOP

```
STAGE0_PREPARED   YES        STAGE1_PREPARED   YES
STAGE2_AUTHORISED NO         STAGE3_AUTHORISED NO
CINV_000002_SPENT NO         CRES_COUNT 0
PRODUCTION_INVOKE_AUTHORISED NO
CINV_000001_RESUME_AUTHORISED NO
```

Reviewer accepts this acceptance and preparation; the operator then runs **Stage
0 and Stage 1 only**, and returns the Stage-1 JSON, its exit code, the
`CINV-000002` digest and the invocation sequence. **Stage 2 must not follow
without its own acceptance checkpoint** — the first invocation's Stage 3 is why
each stage is reviewed on its own evidence.
