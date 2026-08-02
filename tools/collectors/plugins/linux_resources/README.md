# Linux Resources Collector

Remote and read-only. Observes capacity: processors, memory, and durable filesystems.

- **Collector id:** `linux-resources`
- **Permission:** `read-remote-host`
- **Manifest:** [manifest.yaml](manifest.yaml)

Full documentation, including what this collector deliberately does not
collect, lives in [docs/collectors/linux-resources.md](../../../../docs/collectors/linux-resources.md).

The rules that govern every remote collector — transport, host keys,
authentication references, limits, and failure semantics — are in
[docs/collectors/remote-collection.md](../../../../docs/collectors/remote-collection.md)
and [ADR-0010](../../../../docs/decisions/ADR-0010-remote-read-only-collection.md).

This collector observes. It never administers: it changes nothing on the
target, persists no evidence, assigns no EVID identifier, and performs no
remediation.
