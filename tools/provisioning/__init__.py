"""Offline provisioning tooling for the Kyri platform.

**Nothing here is runtime authority, and nothing here is installed.** The
execution matrix installs `tools/capability` and `tools/common` into the
root-owned runtime library; this package is deliberately outside it, because
the primitives beneath allocate governed identifiers and publish immutable
authority, and no identity on the execution path may reach them.

The coordinator reads published authority and never writes it, the worker holds
none of it, and the root transition helper understands one launch record and
nothing else. Keeping the writer out of the installed tree makes that a
property of what exists on the host rather than a rule someone has to follow.
"""
