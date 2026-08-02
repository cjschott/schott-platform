# Linux Resources Collector

Observes how much an approved remote Linux host has: processors, memory, and
durable filesystem capacity.

- **Collector id:** `linux-resources`
- **Source type:** `ssh-command`
- **Permission:** `read-remote-host`
- **Operations:** `linux.cpu_summary`, `linux.memory_summary`,
  `linux.filesystem_summary`

Governed by [ADR-0010](../decisions/ADR-0010-remote-read-only-collection.md).
See [Remote Read-Only Collection](remote-collection.md) for the transport,
host-key, and authentication rules that apply to every remote collector.

## Facts collected

| Fact | Meaning |
|---|---|
| `cpu_logical_count` | Logical processors visible to the kernel |
| `cpu_architecture` | Processor architecture |
| `cpu_model` | Processor model name |
| `memory_total_bytes` | Total memory, in bytes |
| `memory_available_bytes` | Memory available for allocation, in bytes |
| `filesystems` | Durable filesystems with device, type, path, size, and available bytes |

**Everything is reported in bytes.** The kernel reports memory in kibibytes
and the capacity table is asked for bytes explicitly, so nothing downstream
needs to know which unit a fact arrived in. A mixed-unit record is how a
capacity check ends up wrong by a factor of 1024.

## Pseudo-filesystems are excluded

`tmpfs` and its relatives are memory pretending to be disk. Counting them
inflates apparent capacity with space that vanishes on reboot, so they are
excluded by an explicit, reviewable list rather than by a heuristic — the same
set is excluded on every host.

Rows with an unexpected column count are skipped rather than positionally
guessed at.

## Not collected

This collector measures **capacity, not utilisation**, and it is not a
monitoring agent. Sampling load would invite the platform to be read as one,
and a periodic snapshot of a moving quantity is misleading in a way a capacity
figure is not.

- **Load average** — a moving quantity a periodic sample misrepresents
- **Process lists** and per-process memory — reveal what people are running
- **Open files** — a map of what the machine is touching
- **Network throughput** — belongs to monitoring, not inventory

None can be enabled by configuration; each would require a new catalog
operation and a review.

## Secret handling

Remote output is redacted at the transport edge, before parsing and before any
fingerprint is computed. This collector requires no secret of its own;
authentication is referenced by the target, never read or held here.

Capacity figures are not sensitive in themselves, but the redaction boundary
applies uniformly — a single definition of what a secret looks like is easier
to keep correct than a per-collector judgement about which output is safe.

## Failure modes

Failure is all-or-nothing: if any of the three operations fails, the
collection fails and no observations are emitted.

Failures are categorised by what happened to the *attempt* —
`authentication_failure`, `host_key_failure`, `timeout`, `output_limit`,
`transport_failure`, `unsupported_target`, `collection_failure`. **None of
them says the host is down, or that it is out of space.**

Output past its byte ceiling is discarded, not truncated and parsed. A
capacity table cut off halfway yields a confident undercount, which is worse
than no answer.

An unparseable field yields **no fact**, never a zero. Reporting unread memory
as `0` would claim a machine has none.

## No persistence, no identity, no remediation

This collector returns a `CollectorResult` and nothing else. It **never
persists** evidence and assigns no `EVID` identifier — identity is assigned by
the observation layer (ADR-0004).

It performs no remediation. It does not free space, clear caches, or change
anything on the target, and has no code path that could.

## Related

- [Remote Read-Only Collection](remote-collection.md)
- [ADR-0010: Remote Read-Only Collection](../decisions/ADR-0010-remote-read-only-collection.md)
- [Collector Plugin Standard](../standards/collector-plugin-standard.md)
