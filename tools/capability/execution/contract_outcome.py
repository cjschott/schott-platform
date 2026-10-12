"""How one execution outcome presents through a governed capability contract.

The runtime and a contract speak two different vocabularies, and nothing bound
them together. ``lifecycle`` concludes an outcome class in the runtime's words
-- ``records.OUTCOME_CLASSES`` -- and a ``capability-contract`` declares failure
modes in the governed contract vocabulary. Those sets are neither equal nor
nested, so "every failure this capability can suffer is one the contract
declares" was a claim nobody could check. This module is the translation, and
it exists so that claim becomes a test.

**It translates; it concludes nothing.** Every judgement it reads was already
made: the disposition is T13's, the result admission is T14's, and the outcome
class arrives copied through the adapter. Nothing here re-reads an exit code,
re-parses a document, or revisits whether a result may be trusted.

**`provider-error` becomes `adapter-error`, and the runtime keeps its word.**
A workload that ran and exited nonzero *is* the provider's failure, and
``lifecycle`` is right to say so on the runtime plane. But a contract's failure
modes are what a caller observes through the interface, and a caller cannot
distinguish "the capability's process died" from "the machinery could not serve
the call": both mean the invocation produced no believable result through no
fault of the request. That is what ``adapter-error`` names. The generic mapping
is not changed -- it is read, and translated once, here.

**A completed run that produced nothing is still a failure.** The adapter
reports ``completed`` from the lifecycle and separately reports that no result
was admitted, so an invocation can carry a success-shaped outcome class and no
result at all. Which failure that was is recoverable from the output tree the
adapter already carries: no tree means the tree itself was refused, a tree
without a root-level result means nothing was produced, and a tree with one
means the document was present and failed its contract.

**An outcome class nobody emits is refused, not guessed.** ``cancelled`` is in
the released record vocabulary and no committed code produces it. Mapping it
would be inventing a governed answer for a condition nobody has ever observed;
if it starts being emitted, that is a ruling, not a default.

**Fail-closed, and there is no fallback to fall back to.** Every supported
mapping is written out. There is no default arm, no ``get`` with a second
argument, and no ``except`` that answers anyway -- an outcome class this module
does not recognise raises, and so does one that does not *state* what it is:
a missing ``succeeded`` or ``output`` is not a convenient ``False`` or
``None``, it is an object nobody can translate. The consequence is deliberate.
When ``records.OUTCOME_CLASSES`` next grows, the new member cannot flow through
here wearing whatever mode happened to be nearest; it refuses until somebody
decides what the contract should say about it.

Governed by ``platform-model/schemas/capability-contract.schema.yaml``
(``enums.failure_mode``).
"""

from __future__ import annotations

from typing import Any

# The lifecycle's word for a workload that started, ended, and exited zero. It
# is not a failure by itself: whether the invocation succeeded depends on
# whether a result was admitted, which T14 decides.
COMPLETED = "completed"

# Runtime outcome class -> governed contract failure mode. Closed: an outcome
# class absent from here is refused rather than mapped to something plausible.
CONTRACT_FAILURE_MODE: dict[str, str] = {
    "refused": "refused",
    "adapter-error": "adapter-error",
    "timeout": "timeout",
    "interrupted": "interrupted",
    "serialisation-failure": "serialisation-failure",
    # The correction. `lifecycle` maps COMPLETED_NONZERO here and keeps that
    # meaning; through the contract the caller sees an invocation that returned
    # nothing believable and was not their fault.
    "provider-error": "adapter-error",
}

# In `records.OUTCOME_CLASSES`, emitted by nothing. Named so that its absence is
# a checked fact rather than an oversight.
UNREACHABLE_OUTCOME_CLASSES = ("cancelled",)


class ContractOutcomeError(ValueError):
    """The outcome cannot be presented through a governed contract."""


# Distinguishes "the outcome says False" from "the outcome does not say". A
# `getattr` default would answer the second question with the first, which is
# how a malformed outcome acquires a governed failure mode it was never given.
_UNSTATED = object()


def _stated(outcome: Any, field: str) -> Any:
    """The field the outcome actually carries, or refuse.

    Fail-closed by construction: nothing here supplies a value the caller did
    not. An outcome missing a field is not an outcome with a convenient default
    for it -- it is an object this module cannot translate.
    """
    value = getattr(outcome, field, _UNSTATED)
    if value is _UNSTATED:
        raise ContractOutcomeError(f"the outcome states no {field!r}")
    return value


def _uncollected(tree: Any) -> str:
    """Why a completed run admitted no result, from the tree already collected.

    The three cases are the collector's own three, recovered from what the
    adapter carries rather than from a classification it discarded.
    """
    if tree is None:
        # `collect` refused the tree outright, or there was no output at all.
        # Either way nothing believable came back, and it was not the caller's
        # doing.
        return "adapter-error"
    manifest = getattr(tree, "manifest", None)
    present = getattr(manifest, "result_present", None)
    if not isinstance(present, bool):
        raise ContractOutcomeError("the output tree carries no manifest")
    return "serialisation-failure" if present else "result-missing"


def contract_failure_mode(outcome: Any) -> str | None:
    """The governed failure mode ``outcome`` presents as, or ``None``.

    ``None`` means the invocation succeeded. Every other answer is a member of
    the contract's governed failure vocabulary, so a contract declaring the
    modes reachable for its capability declares all of them.
    """
    outcome_class = _stated(outcome, "outcome_class")
    if not isinstance(outcome_class, str):
        raise ContractOutcomeError("an execution outcome is required")

    if outcome_class in UNREACHABLE_OUTCOME_CLASSES:
        raise ContractOutcomeError(
            f"{outcome_class!r} is emitted by nothing; presenting it needs a "
            "ruling, not a default")

    succeeded = _stated(outcome, "succeeded")
    if not isinstance(succeeded, bool):
        raise ContractOutcomeError("an outcome states success as a boolean")
    if outcome_class == COMPLETED:
        return None if succeeded else _uncollected(_stated(outcome, "output"))

    if succeeded:
        # A trusted result exists only where the lifecycle said completed-zero.
        # Anything else claiming success is a contradiction, not a translation.
        raise ContractOutcomeError(
            f"{outcome_class!r} cannot carry a trusted result")

    try:
        return CONTRACT_FAILURE_MODE[outcome_class]
    except KeyError:
        raise ContractOutcomeError(
            f"no governed failure mode for outcome class {outcome_class!r}"
        ) from None
