# Linux Services Collector

Observes the load, active, and enablement state of explicitly allow-listed
units on an approved remote Linux host.

- **Collector id:** `linux-services`
- **Source type:** `ssh-command`
- **Permission:** `read-remote-host`
- **Operation:** `linux.service_state`, run once per named unit

Governed by [ADR-0010](../decisions/ADR-0010-remote-read-only-collection.md).
See [Remote Read-Only Collection](remote-collection.md) for the transport,
host-key, and authentication rules that apply to every remote collector.

## Facts collected

One fact per unit, named `service.<unit>`, carrying:

| Field | Meaning |
|---|---|
| `id` | The unit as the host names it |
| `load_state` | Whether the unit definition loaded |
| `active_state` | Whether it is active |
| `sub_state` | The finer-grained state, such as `running` |
| `unit_file_state` | Whether it is enabled at boot |

`active_state` and `unit_file_state` answer different questions — a service
can be running but not enabled, which survives until the next reboot and not
past it. Both are collected because reporting only one hides that case.

## Units are named, never enumerated

A unit is observed only if it appears in the target's `allowed_units`.

**There is no enumeration operation.** Listing every unit on a host returns an
unbounded result shaped by whatever happens to be installed, which turns a
targeted question into a survey of the machine. Broad enumeration can be
authorised later as a deliberate decision; it will not arrive as a default.

Unit names are checked twice, and both checks apply:

1. Against a strict pattern in the catalog — so a name cannot be anything
   other than a unit name. A value containing a separator, a path traversal,
   or a glob is refused.
2. Against the target's allowlist — so an otherwise valid name cannot be one
   nobody approved.

A rejected name is never echoed into an error message. It is
attacker-influenced text, and those messages land in logs.

## Not collected

- **Journals and log content** — logs are the richest source of accidental
  secrets on any machine: tokens in URLs, credentials in error messages,
  personal data in request traces. A collector that reads them ships all of
  that into evidence records as a side effect of checking whether a service is
  running.
- **Process detail** — PIDs, arguments, and resource usage per service
- **Unit enumeration** — see above
- **Service configuration** — unit file contents routinely carry credentials
  in `Environment=` lines

None can be enabled by configuration; each would require a new catalog
operation and a review.

## What it never does

This collector **reads** service state. It cannot start, stop, restart,
reload, enable, disable, or mask a unit. Those verbs are absent from the
catalog, so there is no code path that performs them — not a disabled one, not
one behind a flag.

## Secret handling

Remote output is redacted at the transport edge, before parsing and before any
fingerprint is computed. Only the five listed properties are parsed out of the
response; other output is discarded rather than recorded, which keeps unit
metadata that was never asked for out of evidence.

This collector requires no secret of its own; authentication is referenced by
the target, never read or held here.

## Failure modes

Failure is all-or-nothing: if any unit's query fails, the collection fails and
no observations are emitted.

Failures are categorised by what happened to the *attempt* —
`authentication_failure`, `host_key_failure`, `timeout`, `output_limit`,
`transport_failure`, `unsupported_target`, `collection_failure`. **None of
them says a service failed.** A query that could not be answered says nothing
about whether the service is healthy, and treating an unreachable host as a
down service manufactures an outage out of an observation gap.

A target listing no allowed units is a configuration failure, not an empty
result. Reporting "no services" for a host nobody configured would read as a
finding.

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
the observation layer (ADR-0004).

It performs no remediation. It does not restart a failed service, and could
not: no mutation operation exists to run.

## Related

- [Remote Read-Only Collection](remote-collection.md)
- [ADR-0010: Remote Read-Only Collection](../decisions/ADR-0010-remote-read-only-collection.md)
- [Collector Plugin Standard](../standards/collector-plugin-standard.md)
