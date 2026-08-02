# Linux Host Collector

Observes what an approved remote Linux host says it is: name, operating
system, kernel, architecture, and uptime.

- **Collector id:** `linux-host`
- **Source type:** `ssh-command`
- **Permission:** `read-remote-host`
- **Operations:** `linux.hostname`, `linux.os_release`, `linux.kernel`,
  `linux.architecture`, `linux.uptime`

All five are unprivileged reads drawn from the code-owned catalog. This
collector cannot add an operation; it names identifiers the catalog defines.

Governed by [ADR-0010](../decisions/ADR-0010-remote-read-only-collection.md).
See [Remote Read-Only Collection](remote-collection.md) for the transport,
host-key, and authentication rules that apply to every remote collector.

## Facts collected

| Fact | Meaning |
|---|---|
| `hostname` | Fully qualified name the host reports for itself |
| `os_id` | Operating system identifier |
| `os_pretty_name` | Human-readable OS name |
| `os_version_id` | OS version |
| `kernel_release` | Running kernel release |
| `architecture` | Machine hardware architecture |
| `uptime_seconds` | Whole seconds since boot |

Everything here is what the machine *says* about itself. A compromised host
reports whatever it likes, and being read-only does not change that.

## Not collected

This list matters more than the one above. Each entry would be easy to add,
and each changes what kind of system this is:

- **User accounts** — who has access is a question about people
- **Environment variables** — routinely carry tokens and credentials
- **Process lists** — reveal what people are running, and when
- **Command history** — a transcript of what an operator typed
- **Network connections** — a map of what talks to what
- **Installed packages** — an inventory of what is installed is also a
  ready-made list of what to attack

Adding any of these turns an identity check into surveillance of whoever uses
the machine. None can be enabled by configuration; each would require a new
catalog operation and a review.

## Secret handling

Remote output is redacted at the transport edge, before parsing and before any
fingerprint is computed, so no unredacted remote string exists inside this
collector. A secret appearing in output — a credential embedded in a URL, for
instance — is replaced before it can reach an observation or a fingerprint.

This collector requires no secret of its own. Authentication is referenced by
the target, never read or held here.

## Failure modes

Failure is all-or-nothing: if any of the five operations fails, the collection
fails and no observations are emitted. A record mixing fresh facts with
silently missing ones reads as complete.

Failures are categorised by what happened to the *attempt* —
`authentication_failure`, `host_key_failure`, `timeout`, `output_limit`,
`transport_failure`, `unsupported_target`, `collection_failure`. **None of
them says the host is down.** A collector that could not connect has learned
nothing about the machine.

Output that a host returned but this collector could not parse yields **no
fact**, never a zero. An unparseable field means nothing was observed, and
recording that as `0` would be an invention.

## Atomic collection

Remote collection is atomic at the collector level in v0.9.0. Successful
intermediate operations are discarded if the collector cannot produce its
complete declared fact contract — no facts, no fingerprint, and no successful
intermediate value survives anywhere in the result.

Partial collection is deferred, not approximated. See
[Remote Read-Only Collection](remote-collection.md#atomic-collection).

## Execution capability

This collector declares `subprocess_access: true`. It does not import
`subprocess`, construct an argv, or supply executable text; it selects
code-owned operation identifiers. `SSHRemoteTransport` owns the one audited
subprocess call, with a fixed executable and fixed client options. The flag
denotes constrained indirect transport capability, not general subprocess
authority. See
[Remote Read-Only Collection](remote-collection.md#what-subprocess_access-true-means-here).

## No persistence, no identity, no remediation

This collector returns a `CollectorResult` and nothing else. It **never
persists** evidence and assigns no `EVID` identifier — identity is assigned by
the observation layer, because a collector that numbers its own records
controls the audit trail (ADR-0004).

It performs no remediation, changes nothing on the target, and has no code
path that could.

## Related

- [Remote Read-Only Collection](remote-collection.md)
- [ADR-0010: Remote Read-Only Collection](../decisions/ADR-0010-remote-read-only-collection.md)
- [Collector Plugin Standard](../standards/collector-plugin-standard.md)
