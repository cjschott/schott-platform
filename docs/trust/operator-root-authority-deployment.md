# Operator Root Authority Deployment

**This document describes a procedure that has not been run.** No root
authority exists, no trust store has been created, and no production path has
been made. Instantiation is a separate, operator-approved task.

Governed by [ADR-0011](../decisions/ADR-0011-trust-plane.md). See also the
[runtime overview](runtime-overview.md), the
[trust migration](trust-migration.md), and the
[validation checklist](operator-root-authority-validation-checklist.md).

## Boundaries

The root authority is **external to Kyri**. Kyri **persists a declaration only** — that an external root exists and what was verified about it. Kyri
**cannot establish the external identity**, and **cannot approve its own root**:
there is no `approved_by` field on the authority, and a decision whose subject
is its own actor is refused.

The operator performs **out-of-band** identity verification. The concrete
identity is supplied at deployment time, by a human, from outside the platform.

### No identity is inferred

The deployment reads exactly one input file. It never derives an identity from:

- the **current user**
- an **environment variable**
- the **hostname**
- the **SSH key owner**
- the **Git author**
- an **email** address
- a **shell account**

A root the platform could infer is not a root — it is a variable. There is no
interactive prompt, and **no interactive identity guessing**.

### References, never material

**no credentials** are stored in trust records (no credentials, ever). `external_identity_reference`
is an **external reference** resolved outside this platform. All evidence
references are **immutable**. **No TOFU** — trust on first use is not a
deployment shortcut, it is the failure mode this whole layer exists to prevent.
There is **no automatic approval** at any point.

## Proposed paths

**These are proposals. They are not created by this document, and the final
production path is not chosen without operator approval.**

```
/var/lib/kyri/trust/          # store root
  authorities/  records/  decisions/  evidence-references/
  lineages/  audit/  sequences/  indexes/

/etc/kyri/trust/              # approved input directory
  root-authority.yaml  evidence/  decisions/
```

| Rule | Requirement |
|---|---|
| Directories | `0700` |
| Files | `0600` |
| Ownership | dedicated Kyri service account or approved operator |
| Location | **never inside the Git repository** |
| Readability | never **world-readable**, never **group-readable** |
| Links | no **symlink**ed store roots |
| Filesystem | no shared **network filesystem** for the first deployment |
| Allocation | **single-host** sequence allocation only |

A service account is **not created** by this task.

> The network-filesystem restriction is not a preference. Identifier allocation
> uses `fcntl.flock`, which does not coordinate across machines, so a shared
> store could allocate duplicate identifiers.

## Required operator inputs

References only. Synthetic placeholders below.

```yaml
---
authority_type: operator-root
display_name: Operator Root Authority
external_identity_reference: secret-source://approved/operator-root
verification_method: out-of-band-physical-verification
verification_details:
  subject_property: operator-root-identity
  observed_value_reference: /etc/kyri/trust/evidence/root-observed.txt
  comparison_source: printed-fingerprint-record
  performed_by: operator-role-reference
  performed_at: 2026-08-03T09:00:00-05:00
evidence_references:
  - kind: attestation
    reference: /etc/kyri/trust/evidence/root-attestation.txt
    recorded_at: 2026-08-03T09:00:00-05:00
approval_source: named-operator
history_reference: allocated-by-the-runtime
created_at: 2026-08-03T09:00:00-05:00
provenance:
  class: declared
  source: operator-out-of-band
lineage_id: allocated-by-the-runtime
```

The template **must not** contain private keys, passwords, passphrases, bearer
tokens, raw certificate contents, SSH credentials, personal email, a hard-coded
username, or executable commands. Public key content is permitted only where it
is explicitly treated as public evidence, by reference.

## Out-of-band verification

Acceptable verification sources:

- a **physical console**
- an existing, independently trusted **management session**
- a **printed** or separately stored fingerprint
- a **hardware-backed** identity
- an **offline signed** record

Every verification records: the property being verified, the observed value
reference, the comparison source, the actor, the timestamp, an evidence
reference, the approval source, and a written reason.

### What is not verification

- **Verifying identity through the same channel being enrolled.** Reading a key
  from the connection you are trying to trust proves only that the connection
  is consistent with itself.
- **`ssh-keyscan`** as proof of identity.
- **DNS alone.**
- The current **hostname alone**.
- The current **login identity alone**.
- **Git metadata alone.**
- **Self-signed** claims from the subject.

## Instantiation — documented, not executed

**Do not run this in a planning task.** It is recorded here so the later
execution task runs a reviewed command rather than an invented one.

```bash
python3 -m tools.trust.cli init-root \
    --store-root <STORE_ROOT> \
    --input-file <INPUT_FILE_NAME> \
    --approved-directory <APPROVED_INPUT_DIR>
```

The execution task must capture: exit code, created authority ID, fingerprint,
audit event ID, store validation result, file permissions, repository
before/after state, and evidence of no secret leakage.

## Initial trust store seeding

The first migrated subjects, once a root exists. **None is seeded here.**
Concrete identifiers follow released model conventions (`RTGT`, `ROP`, `HOST`,
`CAP`) and are chosen at deployment time.

| Subject | Domain | State | Scope | Notes |
|---|---|---|---|---|
| **collector plugin** manifests (7 declared) | `collector-plugin` | trusted | manifest-declared permissions | one lineage per plugin id |
| allowed collector **source type**s (10) | `collector-plugin` | trusted | source-type only | evidence: reviewed standard |
| **remote target** declarations | `host` | restricted | `permitted_operations` from `allowed_operation_ids` | expiry required |
| permitted **remote operation**s (9) | `remote-transport` | trusted | catalog identifier | evidence: code-owned catalog |
| **host identity** reference for the management host | `ssh-host-key` | trusted | one host, one port | out-of-band fingerprint required |
| **code-owned policy** version | `policy` | trusted | policy revision | records what the fallback was |
| **TrustGateway configuration** | `configuration-snapshot` | trusted | store root in use | records the cutover itself |

Each seeded decision requires evidence references, an approval source, a
history reference, a written reason, and an expiration where the grant is
time-bounded. Lineage behaviour follows ADR-0011: one lineage per subject, new
lineage only after revocation or rejection.

**Authoring fabric-domain grants.** A grant in the `capability-package` or
`fabric-node` domain that is meant to authorise a fabric capability writes that
capability's canonical `CAPDEF-0000` identity into `permitted_capabilities`.
The Fabric allocates that identity when the capability is declared, and
admission refuses a binding whose capability is not contained in the composed
scope — so a grant naming the capability any other way authorises nothing. This
applies to those two domains only. `permitted_operations` for remote targets
still comes from `allowed_operation_ids`, and the remote-collection operation
catalog, its target declarations, and their scope comparisons are unchanged.

## Rollback

Immutable records are never deleted, so **rollback is configuration rollback,
not trust-history rollback**.

1. Stop using the production Trust Plane configuration.
2. Restore the prior runtime configuration, pointing at no store.
3. Code-owned policy resumes **only through explicit operator configuration** —
   never as an automatic consequence of a failure.
4. **Preserve** the failed store for audit (preserve it; do not clean it up).
5. **Never delete** or rewrite trust history.
6. Do **not** silently fall back during an active request.
7. Require a **maintenance window** for both cutover and rollback.
8. Record the **operator decision** and its reason.

Point 3 is the one most likely to be shortcut under pressure. A fallback that
engages automatically when the store misbehaves is a bypass with a friendly
name.

## Related

- [Validation checklist](operator-root-authority-validation-checklist.md)
- [Trust migration](trust-migration.md)
- [Trust Plane runtime overview](runtime-overview.md)
- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
