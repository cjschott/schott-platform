#!/usr/bin/env python3
"""Administrative helper source for ENG-0005. **Not installed by anything.**

This file is the source an operator's interactively-authenticated helper would
run. Installing it, owning it as root, and writing the sudoers drop-in that
reaches it are gates G2 and G3, and none of that happens here or in any test.

**It decides nothing.** Every verb below is dispatched into
``tools.capability.execution.admin``, which binds it to an operation T15 or T16
already implemented under that operation's own limits. This file's whole job is
to turn one authenticated operator decision into one call, and to refuse
everything that is not exactly that.

**The argument contract is one verb and one `CINV`, and nothing else.** No
shell, no path, no container identity, no Podman argument, no environment
override, and no flag that changes a limit. An argument list of any other shape
is refused before anything is read, because an argument this narrow is only
narrow if it is checked before it is used.

**No `NOPASSWD`.** Every invocation is a fresh interactive authentication, and
a retry is a fresh authentication and a fresh `CADM`. That is what makes
"unlimited numeric retries" safe: each one is an operator deciding again, not a
loop deciding for them.

Governed by ``docs/superpowers/specs/2026-08-11-first-adapter-design.md`` §20.
"""

from __future__ import annotations

import sys

# The verb vocabulary is restated here as text on purpose: this file must be
# readable as a complete statement of what the helper can be asked to do,
# without following an import to find out. The dispatcher validates it again.
VERBS = (
    "retain",
    "destroy",
    "retain-residue",
    "retry-cleanup",
    "retain-collision",
    "destroy-collision",
    "retain-start-unknown",
    "destroy-start-unknown",
    "retain-lifecycle-failure",
    "destroy-lifecycle-failure",
    "acknowledge-state-lost",
    "retain-quarantine-incomplete",
    "retain-quarantine-residue",
    "inspect-admin-integrity",
)

USAGE = "usage: kyri-exec-admin <verb> [CINV-nnnnnn]"


def _is_cinv(value: str) -> bool:
    return (len(value) == 11 and value.startswith("CINV-")
            and set(value[5:]) <= set("0123456789"))


def parse_arguments(arguments: list[str]) -> tuple[str, str | None]:
    """The one accepted argument shape, or a refusal.

    Inspection takes no `CINV` and every mutating verb requires one. Accepting
    a stray argument "just in case" is how a helper acquires a second meaning.
    """
    if not arguments or len(arguments) > 2:
        raise SystemExit(USAGE)
    verb = arguments[0]
    if verb not in VERBS:
        raise SystemExit(f"{USAGE}\nunknown verb: {verb}")

    if verb == "inspect-admin-integrity":
        if len(arguments) != 1:
            raise SystemExit("inspect-admin-integrity takes no further argument")
        return verb, None

    if len(arguments) != 2 or not _is_cinv(arguments[1]):
        raise SystemExit(f"{USAGE}\n{verb} requires one CINV-nnnnnn argument")
    return verb, arguments[1]


def main(argv: list[str]) -> int:
    """Refuse anything that is not one verb and at most one `CINV`.

    Wiring this to real authority — verified roots, an authenticated
    authorisation, and a destruction backend — happens behind G2 and G3. Until
    then the helper validates its contract and stops, which is the only
    behaviour that is safe to have written down before it is installed.
    """
    parse_arguments(list(argv[1:]))
    sys.stderr.write(
        "kyri-exec-admin is not installed: authority wiring is gated at G2/G3\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
