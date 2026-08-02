"""Exception types for the Trust Plane runtime.

Messages never contain a credential, an evidence value marked sensitive, or a
rejected identity. These messages land in logs, and a refusal that echoes what
it objected to has published it.
"""


class TrustError(Exception):
    """A trust operation was refused."""


class TrustDenied(TrustError):
    """An evaluation denied an activity or a scope request.

    Distinct from a configuration failure: the store was readable, the subject
    was found, and the answer is no.
    """


class TrustStoreError(TrustError):
    """A store operation was refused, or the store is structurally invalid."""
