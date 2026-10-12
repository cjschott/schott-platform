"""Rehearsal mode for the Capability Runtime.

**One rehearsal state, consulted where a preparation stops being reversible.**
The invoke path does three durable things — it materialises and publishes a
package tree, it allocates a `CINV`, and it writes the invocation record — and
until G11-AB the only way to learn whether an invocation would be accepted was
to do all three and read the answer afterwards. A refused first attempt spent
`CINV-000001` and `CRES-000001` permanently, which G11-AA proved rather than
predicted.

The Fabric plane already solved this. `tools.fabric.admission.rehearsing()` runs
the real governed operation against the real store and stops at its first
irreversible act, so a rehearsal answers the same question the write answers
instead of a second implementation's approximation of it. This module is that
mechanism for the capability plane, deliberately shaped the same way.

**A rehearsal is not a lease.** It reserves nothing. Between rehearsing and
writing, another caller may take the identifier that was predicted and the
binding may stop being eligible, which is why the write path allocates for
itself and re-verifies everything rather than being handed a plan to trust.

Kept in its own module rather than added to an existing one so that what reads
this state is obvious from the import: `package_resolution` before it stages,
and `evidence` before it allocates. Nothing else consults it, and nothing may
branch on it to reach a *different* conclusion — only to stop short of writing
the one it already reached.
"""
from __future__ import annotations

import contextlib
import contextvars

_REHEARSING = contextvars.ContextVar("capability_rehearsing", default=False)


@contextlib.contextmanager
def rehearsing():
    """Run one preparation as a rehearsal: verify fully, mutate nothing.

    Everything up to the first irreversible act still happens against the real
    stores — selected-evidence verification, current Fabric eligibility, the
    operation and scope gates, manifest validation, and the full traversal of
    the source package tree with every symlink, size and race refusal it
    carries.

    What does not happen is the staging directory, the identifier allocation,
    and the record write.
    """
    token = _REHEARSING.set(True)
    try:
        yield
    finally:
        _REHEARSING.reset(token)


def is_rehearsing() -> bool:
    """Whether the caller is inside `rehearsing()`."""
    return _REHEARSING.get()
