"""Exception types for the collector framework.

Messages must never contain a secret value. Where a key is rejected for
looking secret-bearing, the key name is reported and the value is withheld:
an error message that echoes the secret it objected to has leaked it into
whatever log captured the error.
"""


class CollectorError(Exception):
    """Base class for collector framework errors."""


class CollectorConfigurationError(CollectorError):
    """A collection context or plugin configuration is unusable.

    Raised before any collection occurs so the framework fails closed.
    """


class CollectorRegistrationError(CollectorError):
    """A plugin could not be registered.

    Raised for duplicate identifiers and for classes that do not implement
    the plugin contract.
    """


class CollectorValidationError(CollectorError):
    """A manifest or result failed validation."""


class CollectorExecutionError(CollectorError):
    """A plugin failed while collecting.

    Expected source failures should be returned as redacted error entries in
    a CollectorResult rather than raised; this type is for framework-level
    faults the plugin could not convert.
    """


class CollectorFailure(CollectorError):
    """A collection failed in a way the plugin has already categorised.

    The generic handler in `execute` reports `<ExceptionType> during
    collection`, which is right for an unexpected fault and useless for an
    expected one: it cannot distinguish a timeout from a rejected credential.
    Plugins that can tell those apart raise this instead, and the lifecycle
    uses the errors as given rather than inventing a category.

    Added in v0.9.0 for remote collection, where "why did this not work" is
    the operational question and the answer must not be flattened to
    "internal". Nothing about the lifecycle is bypassed: the result is still
    built by `execute`, still carries no evidence identifier, and still
    contains no observations.

    Errors must already be redacted. This type is a way to report a category,
    not a way to smuggle a value past the redaction boundary.
    """

    def __init__(self, errors, status: str = "failed") -> None:
        self.errors = tuple(errors)
        self.status = status
        summaries = "; ".join(getattr(error, "summary", "") for error in self.errors)
        super().__init__(summaries or "collection failed")
