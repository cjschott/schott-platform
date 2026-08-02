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

### What a target may be

A target names **exactly one machine**, in one of three forms:

| Form | Example |
|---|---|
| DNS name | `schmgmt.home.arpa`, `schmgmt` |
| IPv4 literal | `192.168.86.11` |
| IPv6 literal | `2001:db8::10` |

**Explicit addresses exist for bootstrap and DNS-failure situations.**
Requiring a name would mean the platform cannot observe a host precisely when
name resolution is what broke — which is exactly when an operator most needs
to look, and when a host may not yet have a name at all.

**Naming one machine by address is not host discovery.** The platform is told
about one machine; it does not go looking for others. Nothing resolves a name,
reverses an address, or expands a scope.

### What a target may never be

| Rejected | Example | Why |
|---|---|---|
| CIDR range | `192.168.86.0/24`, `2001:db8::/64` | A scope, not a host |
| Address range | `192.168.86.10-192.168.86.20`, `192.168.86.10-20` | A scope, not a host |
| Wildcard | `*.home.arpa` | Matches more than one host |
| List | `schmgmt,schai`, `schmgmt schai` | More than one host |
| URL | `ssh://schmgmt` | Carries a scheme the target does not choose |
| Embedded username | `cschott@schmgmt` | Identity belongs in `username` |
| Host with port | `schmgmt:22` | The port has its own field |
| Bracketed IPv6 | `[2001:db8::10]`, `[2001:db8::10]:22` | Brackets are URL syntax |
| Malformed literal | `999.168.86.11`, `2001:db8:::10` | Refused, never treated as a name |
| Surrounding whitespace | `" schmgmt"` | See below |
| Empty | `""` | Names nothing |

Address literals are parsed by Python's `ipaddress` module, **never by a
pattern**. A permissive regular expression accepts malformed literals, and
`999.168.86.11` quietly becoming a "hostname" is precisely the failure this
avoids. Compound and scope syntax is refused *before* parsing is attempted, so
no later rule can be tricked into accepting part of a larger value.

Surrounding whitespace is **refused rather than trimmed**. Silently editing a
declared value means the reviewed target and the used target differ, and the
difference is invisible in review.

### Storage form

An IPv6 literal is stored **canonical, lower-case, compressed, and
unbracketed** — the form the ssh client takes as a bare argument, and the same
value that was reviewed. Brackets belong to URL syntax and never appear in a
target or in argv.

`RemoteTarget.port` remains the only port field. It is passed through the
client's own port option and never fused into the host argument, which would
make an IPv6 literal ambiguous since its colons are already part of the
address.

### Host keys apply to address literals too

Host-key verification is **not relaxed for an address literal**. An IP target
is verified exactly like a name.

This matters in practice: OpenSSH keys `known_hosts` entries by the host
string as given, and a non-standard port is recorded in bracketed form
(`[192.168.86.11]:2222`). The entry must match the identity OpenSSH actually
uses, so enrolling `schmgmt` does not cover `192.168.86.11`, and enrolling
port 22 does not cover port 2222. Enroll the entry for the exact target form
in use.

The bracketed form appears **only inside the `known_hosts` file**, which is
OpenSSH's own format. It is never a target value.

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

## Atomic collection

> **Remote collection is atomic at the collector level in v0.9.0.**
> **Successful intermediate operations are discarded if the collector cannot**
> **produce its complete declared fact contract.**

If any required operation fails, the collector returns:

- no observations
- no content fingerprint
- a specific failure category describing the attempt

Successful intermediate output does not appear in the returned facts, in the
errors, in the fingerprint, in logs, or in any temporary file — nothing is
written to disk on the way, so there is no partial artefact for a later run to
find. This is verified by a test that makes four operations succeed and one
fail, then asserts none of the four successful values survives anywhere in the
result.

**Why.** A record mixing fresh facts with silently missing ones reads as
complete, and every layer above treats a successful record as a full one. A
clean failure carrying a specific category is more useful to an operator than
a partial record that has to be second-guessed.

**The cost is real.** One failing operation loses the facts that did arrive.
Partial collection is deferred, not approximated: an explicit completeness
marker is a reasonable future design, and guessing at one now would put the
weakest part of the contract where operators trust it most.

## What `subprocess_access: true` means here

Remote collector manifests declare `subprocess_access: true`. Read literally
that sounds like general execution authority. It is not, and the difference is
worth stating precisely.

**What the collectors do:**

- They do **not** import `subprocess`, and contain no `os.system`, `os.popen`,
  `Popen`, or `shell=True`.
- They do **not** construct an argv, and never supply executable text.
- They select **code-owned operation identifiers** and nothing else.

**Where execution actually lives:**

- `SSHRemoteTransport` owns the one subprocess call in the remote package —
  asserted by test, which fails if any other module in the package so much as
  mentions `subprocess`.
- The executable and every client option are fixed in code.
- The argv comes from the catalog, always as discrete arguments, never joined.

So `subprocess_access: true` denotes **constrained, indirect transport
capability** — this collector causes a process to run, through one audited
chokepoint, with a fixed executable and a code-owned argv.
It is **not general subprocess authority**.

The manifest field cannot currently express that distinction. Declaring `true`
is the honest choice of the two available: `false` would claim the collector
causes no process to run, which is not so. A richer execution-capability
vocabulary is reserved for a later release, and the schema is deliberately not
redesigned here.

Remote collection also cannot route through `command_runner.py`, the local
chokepoint, whose executable allowlist refuses `ssh` outright — correctly, for
a module whose job is local execution. Rather than punch a hole in that
allowlist, remote execution has its own audited home with its own rules. Two
reviewable places, and nowhere else.

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
