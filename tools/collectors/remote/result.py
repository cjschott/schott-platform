"""Failure semantics for remote collection.

One rule governs this module: a collection failure is not a target failure.

A collector that could not connect has learned nothing about the host. The
network may be broken, the credential may have expired, the name may resolve
somewhere unexpected. Reporting any of that as an outage manufactures one out
of an observation gap — and the platform already has a layer whose job is
interpreting evidence, which cannot do that job if the evidence has been
pre-interpreted here.

So every summary below describes the attempt. None says the host is down, a
service failed, or declared state is wrong. Nothing in this module is in a
position to know those things.
"""

from __future__ import annotations

from ..exceptions import CollectorFailure
from ..models import CollectorError, ResultStatus
from ..redaction import redact_text
from .models import RemoteExecutionResult, RemoteFailureCategory

# Whether trying again could plausibly produce a different answer. A rejected
# credential and a mismatched host key will not fix themselves; a timeout or a
# dropped connection might.
RETRYABLE_CATEGORIES = frozenset({
    RemoteFailureCategory.TIMEOUT.value,
    RemoteFailureCategory.TRANSPORT_FAILURE.value,
})

# UNAVAILABLE means "could not look". FAILED means "looked, and the attempt
# was not usable". The distinction is worth keeping: an operator reading a
# timeline needs to know which of those happened.
_UNAVAILABLE = frozenset({
    RemoteFailureCategory.TIMEOUT.value,
    RemoteFailureCategory.TRANSPORT_FAILURE.value,
    RemoteFailureCategory.AUTHENTICATION_FAILURE.value,
    RemoteFailureCategory.HOST_KEY_FAILURE.value,
})

DEFAULT_SUMMARIES = {
    RemoteFailureCategory.TIMEOUT.value:
        "the operation did not complete within its time ceiling",
    RemoteFailureCategory.OUTPUT_LIMIT.value:
        "the operation produced more output than its ceiling permits",
    RemoteFailureCategory.AUTHENTICATION_FAILURE.value:
        "the target refused the offered authentication",
    RemoteFailureCategory.HOST_KEY_FAILURE.value:
        "the target's host key did not match the approved known-hosts entry",
    RemoteFailureCategory.TRANSPORT_FAILURE.value:
        "the connection attempt did not complete",
    RemoteFailureCategory.UNSUPPORTED_TARGET.value:
        "the target does not permit this operation",
    RemoteFailureCategory.COLLECTION_FAILURE.value:
        "the operation completed but produced nothing usable",
}


def error_for(execution: RemoteExecutionResult) -> CollectorError:
    """Convert one failed attempt into a redacted collector error."""
    category = execution.failure_category or RemoteFailureCategory.COLLECTION_FAILURE.value
    summary = execution.summary or DEFAULT_SUMMARIES.get(
        category, "the collection attempt did not complete")
    safe_summary, _ = redact_text(f"{execution.operation_id}: {summary}")
    return CollectorError(
        category=category,
        summary=safe_summary,
        retryable=category in RETRYABLE_CATEGORIES,
        redacted=True,
    )


def error_from_exception(operation_id: str, error: Exception) -> CollectorError:
    """Convert a transport exception into a redacted collector error.

    The message is redacted rather than dropped. A transport exception often
    names the host and the option that failed, which is genuinely useful, and
    occasionally carries a URL with embedded credentials, which is not.
    """
    summary, _ = redact_text(f"{operation_id}: {type(error).__name__}: {error}")
    return CollectorError(
        category=RemoteFailureCategory.TRANSPORT_FAILURE.value,
        summary=summary,
        retryable=True,
        redacted=True,
    )


def status_for(errors: list[CollectorError]) -> str:
    """The result status implied by a set of errors."""
    if any(error.category in _UNAVAILABLE for error in errors):
        return ResultStatus.UNAVAILABLE.value
    return ResultStatus.FAILED.value


def collection_failed(errors: list[CollectorError]) -> CollectorFailure:
    """Build the exception that ends a collection with categorised errors.

    Raised rather than returned so no partially-parsed observation can escape
    alongside it. Output that exceeded a ceiling or arrived after a timeout is
    discarded, never parsed: half a file yields a confident wrong answer, which
    is worse for an operator than no answer at all.
    """
    return CollectorFailure(errors=errors, status=status_for(errors))
