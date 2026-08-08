"""Exception types for the Fabric Runtime.

Messages never contain a credential, a secret, or a rejected value. These
messages land in logs, and a refusal that echoes what it objected to has
published it.
"""


class FabricError(Exception):
    """A fabric operation was refused."""
