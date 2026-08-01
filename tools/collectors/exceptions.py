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
