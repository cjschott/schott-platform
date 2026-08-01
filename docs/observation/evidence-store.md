# Evidence Store

Append-only storage for evidence, verifications, and knowledge events.

## Layout

```
<store-root>/
  evidence/        EVID-000001.yaml
  verifications/   VER-000001.yaml
  events/          MEM-000001.yaml
  indexes/         derived, replaceable
  state/           derived cache, replaceable
  sequences/       identifier allocation state
```

Filenames always match identifiers. `validate-store` reports any file whose
name and `id` field disagree, because a mismatch means a record cannot be
found by the identifier that cites it.

## The root is always explicit

There is no default. A default store root eventually becomes a production path
someone wrote to by accident, and the failure is silent.

The store also refuses a root inside a git repository unless a caller opts in
explicitly. Generated records under version control would swamp the declared
model and create an editable second copy of records whose whole value is that
they cannot be edited. The opt-in exists for test fixtures, which use synthetic
repositories rather than the real one.

## Atomic, overwrite-refusing writes

Writes go to a temp file, then `os.link` to the final name:

```
write .EVID-000001.tmp  →  fsync  →  link to EVID-000001.yaml  →  remove temp
```

`link` fails when the destination exists. That makes committing a write and
refusing an overwrite the *same* atomic operation, rather than a check followed
by a write that could race between the two.

`os.replace` was rejected explicitly: it is equally atomic and it succeeds
silently over an existing record, which is the one outcome this store must
never produce.

Temp files carry a `.tmp` suffix so a leftover is obviously debris rather than
being mistaken for a record. `validate-store` reports any it finds.

## Identifier allocation

Six digits, zero-padded, monotonic: `EVID-000001`, `VER-000001`, `MEM-000001`.

Allocation holds an exclusive `flock` across the whole read-modify-write, so
two processes on this host cannot receive the same number.

If the next identifier's file already exists, it is **skipped** rather than
handed out. Scanning filenames and assuming the sequence owns the next name is
how a store silently overwrites a record it did not know about — a restored
backup, or a file copied in by hand.

Sequence exhaustion raises rather than rolling over. Rollover would reuse
identifiers, and a reused identifier makes every historical citation ambiguous.

## No update, no delete

Neither method exists in v0.7.0. Their absence is the immutability guarantee:
a store that *can* rewrite a record breaks every conclusion that cited it.

Corrections supersede. A new record carries `supersedes: EVID-000041`, and the
superseded record stays readable so past conclusions remain legible.

The only deletion is cleanup of the store's own temp file during a failed
write. The test suite requires every deletion call site to be annotated as
temp cleanup, so record deletion cannot be added without removing an
annotation a reviewer would notice.

## Indexes are derived

`indexes/by-target.yaml` is rebuilt from the records and may be overwritten
freely — everything in it can be recomputed. It is a lookup convenience, never
a source of truth. The same applies to anything cached under `state/`.

## Permissions

Directories are created `0700` and files `0600` where the filesystem supports
it. Tightening is best-effort: on a filesystem that cannot express these modes,
failing the write would be worse than a permissive mode.

## Related

- [ADR-0004: Immutable Knowledge Timeline](../decisions/ADR-0004-immutable-knowledge-timeline.md)
- [Observation engine overview](overview.md)
- [Evidence Standard](../standards/evidence-standard.md)
