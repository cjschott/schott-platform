# Remote Read-Only Collection

**Remote collectors observe. They never administer.**

Every rule below follows from that one sentence. Where a rule looks
inconvenient, the inconvenience is the point: each convenience that was
rejected turns a read-only observer into a remote execution service.

Governed by [ADR-0010](../decisions/ADR-0010-remote-read-only-collection.md).

> Every host name in this document is synthetic (`web01.invalid`,
> `db02.invalid`). Real host names, addresses, user names, and key paths do
> not belong in repository documentation.

## Threat model

The question this design answers is not "how do we read facts from a host" —
that is easy. It is **"what can go wrong when a central, automated system
holds credentials to many machines"**, because that system is a high-value
target precisely because of what it can reach.

What is defended against:

| Threat | Defence |
|---|---|
| Command injection through configuration | Argv comes from a code-owned catalog; configuration selects an identifier and nothing else |
| A compromised platform pivoting to hosts | No mutation operation exists to run; the catalog has no escalation, package manager, or interpreter |
| Machine-in-the-middle on first contact | Host-key verification is mandatory; unknown keys fail closed; enrollment is out of scope |
| A rebuilt or spoofed host | A changed key fails the attempt rather than being accepted |
| Credential theft from the repository | No credential material is stored; authentication is referenced |
| Credential leakage into records | Remote output is redacted at the transport edge, before parsing and before fingerprinting |
| Resource exhaustion by a hostile host | Every operation is bounded by time and bytes; output past a ceiling is discarded |
| Quiet scope growth | Adding a fact requires a code change and review |

What is **not** defended against, stated plainly:

- **The OpenSSH client is external code.** Its option parsing is not ours.
  Every relevant option is pinned explicitly rather than inherited, and static
  tests assert the dangerous ones are absent — but this is mitigation, not
  proof.
- **Fake-transport coverage is not real-world coverage.** Nothing in the test
  suite proves the client behaves as modelled against a live host. First real
  use needs supervised validation.
- **Credentials still exist somewhere.** This design keeps them out of the
  repository and out of records. It does not solve secret management, which
  remains an operator responsibility.
- **A host can lie.** Everything collected is what the machine *says* about
  itself. A compromised host reports whatever it likes, and no amount of
  read-only care changes that.

## Targets are declared, never discovered

A host this platform has not been told about in a reviewed file cannot be
contacted. There is no scan, no address range, and no default.

Target files live in an approved directory and are refused if they resolve
outside it — a symlink pointing elsewhere is refused rather than followed,
because a containment check that follows links contains nothing.

A hostname must be a DNS name containing at least one letter. That single rule
refuses wildcards, address ranges, and bare address literals together, which
matters because hyphens and digits are both legal in DNS labels and
`192.168.1.1-192.168.1.50` is otherwise hard to distinguish from a name.

**Trade-off, stated:** a host with no DNS name cannot be declared. That is a
real limitation. A name is the reviewable form — an address says nothing about
which machine it is and silently follows whatever now answers to it.

## Host keys

Host-key verification is **mandatory and cannot be disabled**. The only
accepted `host_key_policy` value is `strict`, and there is no permissive
alternative to set. A policy field that can express "ignore" eventually gets
set to it, usually at 2am during an incident.

- An unknown host key fails the attempt.
- A changed host key fails the attempt. A changed key is exactly the event the
  check exists to surface; accepting it automatically converts the alarm into
  a log line nobody reads.
- The known-hosts file is named per target and is never `/dev/null`.

**Enrollment is deliberately absent.** There is no command in this platform
that adds or trusts a host key, and adding one is not a small convenience: a
collector that can enroll a key can enroll an attacker's. Operators enroll
keys out of band, verifying the fingerprint through a channel that is not the
connection being verified.

After a legitimate rebuild, host-key collection fails until an operator
updates the known-hosts entry. That friction is intended.

## Authentication reference

Authentication material is **referenced, never stored**. A target names where
its credential lives; the platform never reads it and never passes it as an
argument. Command lines are visible in process listings.

| Kind | Meaning |
|---|---|
| `ssh-key-path` | A path to a private key the ssh client reads |
| `ssh-agent` | An agent holds the key; only the socket is passed through |
| `secret-source` | An identifier resolved by an external secret system |

Credential-bearing keys in a target file — `password`, `passphrase`,
`private_key`, `token`, and their relatives — are **refused outright** at any
depth, and the refusal never echoes the value it objected to. Ignoring them
would leave a working secret sitting in a reviewed file everyone assumes holds
none.

There is no `sudo`, and no way to request it. Every fact collected here is
readable unprivileged, so `sudo` would buy nothing — and it would leave the
platform holding privileged remote execution against the day someone wants a
fact that needs it. At that point the decision would already have been made,
quietly, by a collector.

## The operation catalog

Everything that can happen on another machine is written out in
`tools/collectors/remote/command_catalog.py` as a tuple of discrete arguments.

- Configuration may choose an **operation identifier**. It may never supply
  command text.
- No argv is assembled from configuration, and none is ever joined into a
  string. No shell is invoked on either side.
- The catalog is a read-only mapping with no `add`, `register`, `extend`, or
  `update` entry point.
- Adding a fact requires a code change and a review. This friction is
  deliberate: configuration is reviewed as data, and command text is code.

Nine operations exist in this release. All are unprivileged reads.

| Operation | Reads |
|---|---|
| `linux.hostname` | Fully qualified host name |
| `linux.os_release` | Operating system identity |
| `linux.kernel` | Kernel release |
| `linux.architecture` | Machine architecture |
| `linux.uptime` | Seconds since boot |
| `linux.cpu_summary` | Processor topology |
| `linux.memory_summary` | Total and available memory |
| `linux.filesystem_summary` | Durable filesystem capacity |
| `linux.service_state` | State of one named unit |

`linux.service_state` is the only operation taking an argument. The unit name
is validated against a strict pattern **and** must appear in the target's
`allowed_units`. Both checks apply: the pattern stops a name being anything
other than a unit, and the allowlist stops an approved name being one nobody
approved.

Service **enumeration does not exist**. Listing every unit returns an
unbounded result shaped by whatever happens to be installed, turning a
targeted question into a survey of the machine.

## Authorization

A target's `allowed_operation_ids` is the authorization boundary. An operation
absent from that list cannot run against that host, whatever a collector asks
for. A collector requesting an unauthorized operation fails before any
connection is attempted.

## Limits and timeouts

Every attempt is bounded on both axes, and the **lower** of the target's limit
and the operation's ceiling always wins, so neither side can raise the other's.

| Bound | Purpose |
|---|---|
| `connect_timeout_seconds` | Caps waiting for a connection |
| `command_timeout_seconds` | Caps a single operation |
| `max_stdout_bytes` | Caps captured output |
| `max_stderr_bytes` | Caps captured diagnostics |

**Output past its ceiling is discarded, not truncated and parsed.** A parser
handed half a file produces a confident wrong answer, which is worse for an
operator than no answer at all. The same applies after a timeout: partial
output is never accepted.

## Redaction

Remote output is the least trustworthy text in the platform — it comes from a
machine this code does not control and it lands in evidence records.

Redaction happens at the **transport edge**: before parsing, before
normalization, and before any fingerprint is computed. There is no window in
which an unredacted remote string exists inside a collector.

Order matters. A fingerprint computed over unredacted content is a hash of a
secret — a weaker disclosure than plaintext, but still a disclosure, and it
silently defeats the point of not storing the value.

Remote and local output share one definition of what a secret looks like. A
second, divergent definition would mean a pattern fixed in one place stayed
broken in the other.

Decoding is deterministic: undecodable bytes become the replacement character
rather than raising, so a host emitting garbage produces a recorded failure
instead of losing the attempt entirely.

## Failure semantics

**A collection failure is not a target failure.** This is the single most
important thing to understand when reading a remote record.

A collector that could not connect has learned *nothing* about the host. The
network may be broken, the credential may have expired, the name may resolve
somewhere unexpected. Reporting any of that as an outage manufactures one out
of an observation gap — and the platform already has a layer whose job is
interpreting evidence, which cannot do that job if the evidence arrives
pre-interpreted.

Every category describes **the attempt**:

| Category | Means | Retryable |
|---|---|---|
| `authentication_failure` | The target refused the offered authentication | No |
| `host_key_failure` | The host key did not match the approved entry | No |
| `timeout` | The attempt exceeded its time ceiling | Yes |
| `output_limit` | Output exceeded its byte ceiling and was discarded | No |
| `transport_failure` | The connection attempt did not complete | Yes |
| `unsupported_target` | The target does not permit this operation | No |
| `collection_failure` | The operation completed but produced nothing usable | No |

None of these says the host is down, a service failed, infrastructure drifted,
or declared state is wrong. Nothing at this layer is in a position to know any
of that.

`unavailable` means "could not look". `failed` means "looked, and the result
was not usable". An operator reading a timeline needs to know which happened.

**Failure is all-or-nothing per collector.** If any operation fails, the whole
collection fails and no observations are emitted. A record mixing fresh facts
with silently missing ones reads as complete. The cost is real — one failing
operation loses the facts that did arrive — and it is accepted deliberately.

## What remote collectors never do

- Write anything, anywhere, on a target
- Start, stop, restart, reload, enable, or disable a service
- Install, update, or remove a package
- Escalate privilege
- Run a shell, an interpreter, or any command supplied by a user or by
  configuration
- Modify firewall or SSH configuration
- Enroll or trust a host key
- Read logs, journals, process lists, environments, user accounts, command
  history, network connections, or installed package inventories
- Persist evidence or assign a record identifier — identity is assigned by the
  observation layer (ADR-0004)
- Remediate anything

## Relationship to the Distributed Capability Fabric

v0.9.5 will let the platform *use* other machines. This release only lets it
*look at* them, and the ordering is deliberate: observation before placement,
so the fabric is built on a platform that can already describe the nodes it
would place work on.

The architectural rule extends: **no model is Kyri, and no machine is Kyri.**
A target here is a thing observed, never a thing the platform depends on to
function. The control plane keeps operating when every remote target is
unreachable.

## Operator procedure

Enrolling a host key is a manual, out-of-band step. Verify the fingerprint
through a channel other than the connection being verified, then add the entry
to the known-hosts file named by the target:

```bash
# Read the fingerprint from the host itself, via a trusted channel.
# Do not take it from the connection you are about to trust.
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Then check the target is usable before collecting:

```bash
python3 -m tools.collectors.remote_cli validate-target \
    --target web01.yaml --approved-directory /etc/schott/targets
```

List everything that could ever run:

```bash
python3 -m tools.collectors.remote_cli list-operations
```

## Related

- [ADR-0010: Remote Read-Only Collection](../decisions/ADR-0010-remote-read-only-collection.md)
- [Linux Host Collector](linux-host.md)
- [Linux Resources Collector](linux-resources.md)
- [Linux Services Collector](linux-services.md)
- [Collector Plugin Standard](../standards/collector-plugin-standard.md)
