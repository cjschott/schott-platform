# Trust Mechanism Migration

Before v0.9.4 the platform had four trust systems. Each was reviewed and each
was fail-closed, and nobody could answer *"what does this platform trust?"*
without reading four unrelated modules.

This release gives them one decision point: `tools/trust/gateway.py`.

Governed by [ADR-0011](../decisions/ADR-0011-trust-plane.md). See also the
[runtime overview](runtime-overview.md).

## Inventory

Every trust decision found in the repository, and where it went.

| Mechanism | ADR-0011 domain | Was | Now |
|---|---|---|---|
| Collector manifest authorization | `collector-plugin` | `CollectorManifest.validation_errors()` | Gateway; the model asks |
| Collector source-type approval | `collector-plugin` | `registry.py` membership test | Gateway; the registry asks |
| Remote target operation authorization | `host` | `RemoteTarget.permits()` | Gateway; the lifecycle asks |
| Remote operation catalog membership | `remote-transport` | `operation_for()` lookup | Gateway; the catalog asks |
| Host-key policy | `ssh-host-key` | target validation | Gateway policy |
| Authentication reference kinds | `user` | target validation | Declared; **not yet decided at runtime** |
| Platform capabilities | `capability-package` | declared records | Declared; **not yet decided at runtime** |

**No new domain was invented.** Operation authorization is host trust expressed
through scope's `permitted_operations`, not a sixteenth category — which is why
the fifteen ADR-0011 domains needed no schema change.

## The single decision point

```
request
   |
   v
TrustGateway.query(domain, subject_id, action, context)
   |
   +-- store configured?  --yes-->  Trust Plane runtime   (root-terminated)
   |
   no
   v
   code-owned policy (tools/trust/policy.py)
   |
   v
allow / deny + written reasons + which source decided
```

The two sources are never combined. When a store is configured it is
authoritative and policy is not consulted, because two sources that can both
answer are two authorities again.

## Every verdict names its source

- **`trust-plane-runtime`** — root-terminated, immutable, auditable.
- **`code-owned-policy`** — reviewed code, fail-closed, **not** traceable to an
  external Operator Root Authority.

Recording the source is the point. A verdict that could not tell them apart
would hide exactly the gap this release leaves open.

## Behaviour is unchanged

Only the decision *authority* moved. Every allow and every deny is what it was
at v0.9.3, including the exact wording of each refusal — a released error
message is part of released behaviour.

This is asserted positively rather than by absence: every manifest shape the
released code refused is asserted to still be refused, and every shape it
accepted is asserted to still validate. The three collector suites pass
unchanged, which is the evidence.

## What is honestly not finished

**The code-owned rules are not root-terminated.** Until an operator
instantiates an Operator Root Authority and seeds a store, the platform
enforces the same rules it always did, from the same reviewed code — in one
place instead of four, but without a chain terminating outside the platform.

This is the remaining gap between "one trust system" and "one *root-terminated*
trust system", and it cannot be closed here: doing so would require inventing a
deployment identity, which ADR-0011 forbids and this sprint was told not to do.

**Two domains are declared but not decided.** Identity (`user`) and capability
(`capability-package`) subjects live in reviewed files. The gateway denies them
at runtime with a reason naming the gap, rather than allowing them and implying
a decision nobody made.

**Structural containment stays where it is.** The operation catalog still owns
its argv, host-key verification is still mandatory in the transport, and the
command runner still holds its executable allowlist. These are the *definition*
of the trust boundary rather than decisions about a subject, and moving
reviewed argv into a policy function would put executable text one indirection
further from review.

## Still forbidden

No automatic trust, no trust on first use, no automatic enrollment, no
automatic approval, no automatic recovery, no trust scores, no learning, no
prediction, no runtime mutation. **Reasoning consumes trust; trust never
consumes reasoning** — the gateway imports no reasoning layer and no model
client.

The gateway writes nothing, allocates no identifier, and emits no audit event.
Asking what is trusted must not change what is trusted.

## Related

- [ADR-0011: The Trust Plane](../decisions/ADR-0011-trust-plane.md)
- [Trust Plane runtime overview](runtime-overview.md)
- [Trust domains](trust-domains.md)
