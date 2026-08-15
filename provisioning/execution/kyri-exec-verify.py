"""The G6.1 verification-only transition policy. **Not installed by anything here.**

This file becomes `/usr/lib/kyri/python/kyri_exec_verify.py`, owned
`root:root`, mode `0444`. It is an internal library component, exactly as the
production policy is: no separate executable, no separate privilege.

**It differs from the production policy in one value: the worker target.** Not
a mode, not a flag, not a field somebody sets at runtime — a different
compiled-in pathname in a different governed module, selected by which
privileged entrypoint the operator was authorised to run. Everything else about
the transition is the production decision, imported rather than restated,
because a second copy of a credential-drop policy is a second thing to keep
correct and a first thing to get wrong.

**Why a module and not an argument.** An argument that selects the terminal
target is an argument that can select the production target, and a sudoers
regex is a poor place to be certain it cannot. Two modules, two entrypoints,
two sudoers rules: the authority to run verification is simply not the
authority to run production, and that is a property of which paths exist rather
than of a check somebody remembered to write.

**It cannot widen the transition.** `policy_for` calls the production
`policy_for` and replaces exactly one field of the frozen result. Identity,
descriptors, environment, roots, quota — all of it is whatever production
decided, so a change there reaches this automatically and a divergence cannot
be introduced here quietly.

**The privileged action still runs production code, deliberately.** The action
layer resolves the policy module by name from `sys.modules` and finds
`kyri_exec_transition`, which this module imports. So `worker_argv`, the
descriptor transport, the drop and the verification are the production
functions, unmodified, and the only thing this module contributes to the
privileged sequence is the value of `policy.worker_script`. That is the whole
point: "the same transition, aimed at a different terminal target" is a claim
that should be true by construction rather than by inspection.

Governed by ``docs/superpowers/specs/2026-08-11-execution-transition-boundary.md``
§3.2 and §3.3, and the G6.1 milestone.

Intended installed ownership and mode: ``root:root``, ``0444``.
"""

from __future__ import annotations

import dataclasses
from typing import Any, Sequence

# The production policy, whole. Looked up under both spellings for the same
# reason the action layer does: an installed helper and the test fixture load it
# under different names.
try:  # pragma: no cover - exercised by whichever name is present
    import kyri_exec_transition as _production
except ImportError:  # pragma: no cover
    import sys as _sys

    _production = _sys.modules["kyri-exec-transition"]

# Re-exported because the entrypoint reads it off whichever policy module it
# loaded, and it must be the production type: the action layer raises and
# catches production refusals, and two refusal classes would mean a refusal that
# nothing catches.
TransitionRefused = _production.TransitionRefused

# The one value that differs, and the reason this module exists.
WORKER_SCRIPT = "/usr/libexec/kyri-exec-verify-worker.py"

# Stated rather than left to be inferred from the absence of something.
PRODUCTION_WORKER_SCRIPT = _production.WORKER_SCRIPT


def policy_for(argv: Sequence[str]) -> Any:
    """The production transition decision, with the verification target.

    Exactly one field is replaced, on a frozen dataclass, after production has
    validated the whole command line. There is no second parser here and no
    second grammar, so a `CINV` production would refuse never reaches this — and
    no argument, environment variable or caller-supplied path contributes to the
    target, because the target is a constant in this file.

    The production result is checked before it is replaced. If it did not name
    the production worker, then either the module beneath this one is not the
    module this was written against or something has already substituted a
    target; both are refusals rather than a base to build on.
    """
    policy = _production.policy_for(argv)
    if policy.worker_script != PRODUCTION_WORKER_SCRIPT:
        raise TransitionRefused(
            "the production policy did not name the production worker; "
            "refusing to derive a verification policy from it")
    return dataclasses.replace(policy, worker_script=WORKER_SCRIPT)
