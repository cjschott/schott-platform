"""Exception types for the Capability Runtime.

Messages never contain a credential, a secret, a payload, or a rejected value.
These messages land in logs, and a refusal that echoes what it objected to has
published it.
"""


class CapabilityError(Exception):
    """A capability runtime operation was refused."""
