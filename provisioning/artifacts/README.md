# Governed artifact authority — operator runbook

The ceremony in this directory publishes the reviewed verification package and
its executable manifest into `/var/lib/kyri/artifacts`, and this file records
the values an operator must supply to use what it publishes.

Those values have **no defaults anywhere in the runtime, and that is deliberate**.
Each one names a trust boundary. A default would be the runtime deciding for
itself whose bytes to trust, on the one code path where being wrong means
resolving the wrong package.

---

## The four load-bearing values

| Value | Setting | Supplied as |
|---|---|---|
| approved artifact root | `/var/lib/kyri/artifacts` | `--approved-artifact-root` |
| trusted source UID | `0` | `--trusted-source-uid` |
| Fabric store expected UID | `1000` (`cschott`) | `--expected-uid` |
| Fabric store expected GID | `1000` (`cschott`) | `--expected-gid` |

Decision inputs are read from `/etc/kyri/fabric`, supplied as
`--approved-directory`.

### approved artifact root — `/var/lib/kyri/artifacts`

The trusted filesystem authority `resolve_and_stage_package` reads before
anything is content-addressed. It is **not** the repository checkout, the Fabric
governance store, the Capability Runtime's evidence, the installed Python
library, or staging.

The checkout cannot serve as this root, and no amount of committing can make it:
git records `100644`/`100755` for blobs, stores no directory objects at all, and
carries no uid or gid anywhere in a tree object, so directory ownership and mode
come from whoever checked the tree out and from their umask. Verified
mechanically — `open_trusted_directory` refuses `/opt/schott-platform/packages`
as *"writable beyond its owner"*.

### trusted source UID — `0`

Every component of the resolved path, plus the manifest and the artefact, must
be owned by this UID and be neither group- nor world-writable. The artifact
authority is published `root:root`, directories `0755` and files `0444`, so the
value is `0`.

**It must never be inferred.** Not from `geteuid()`, not from the invoking
shell's user, not from the file's own owner, and not by observing the filesystem
and using whatever is there. Design §7 states this as a MUST, and the reason is
plain: a UID inferred from the running process is a check that agrees with
whoever is running, which is exactly the assumption the check exists to remove.
`open_trusted_regular_file` and `open_trusted_directory` refuse outright when it
is absent — there is no fallback to argue with.

### Fabric store expected UID/GID — `1000:1000`

The Fabric governance store at `/var/lib/kyri/fabric` is `cschott:cschott 0700`,
and `FabricStore` refuses to open a root whose owner disagrees with the supplied
values. It never calls `chown`: repairing ownership would erase the evidence
that it was wrong.

### Why the two planes have different owners

They answer different questions, and one identity owning both would collapse the
separation.

- The **artifact authority** is what the coordinator *reads and must not be able
  to change*. Root-owned means the coordinator can traverse and read it and can
  neither write, rename, chmod, nor replace anything in it. Trust sits in the
  operator's control of the directory, enforced by ownership and mode.
- The **Fabric governance store** is what the coordinator *writes*. It records
  the operator's governed decisions and is therefore owned by the identity that
  makes them.

A coordinator that owned the artifact root could substitute the bytes it is
about to certify. A root-owned Fabric store would mean governed writes needed
privilege, putting every declaration behind root. Neither is acceptable, so the
planes are split and the parameters are stated explicitly at every call.

---

## Invocations

Read-only rehearsal of a package declaration. Creates no store, allocates no
identifier, writes nothing:

```
python3 -m tools.fabric.cli declare-package --preflight \
  --store-root /var/lib/kyri/fabric \
  --expected-uid 1000 --expected-gid 1000 \
  --input-file cpkg-0001.json \
  --approved-directory /etc/kyri/fabric
```

The governed declaration is the same command **without** `--preflight`. It
allocates an identifier and writes an immutable record; run the rehearsal
immediately before it and confirm `predicted_record_id` and `request_digest`
still match what the frozen inputs were built against. A decision body carrying
`expected_capability_package_id` refuses as `predicted-identity-moved` if the
prediction has since been taken, before the sequence moves.

Package resolution, when that phase arrives — this one needs the artifact root
and the trusted UID:

```
python3 -m tools.capability.cli invoke \
  --fabric-root /var/lib/kyri/fabric \
  --fabric-expected-uid 1000 --fabric-expected-gid 1000 \
  --approved-artifact-root /var/lib/kyri/artifacts \
  --trusted-source-uid 0 \
  --staging-root <coordinator-owned staging root> \
  --coordinator-uid 1000 \
  ...
```

`--staging-root` is the coordinator's own directory and is a separate decision;
it is not part of the artifact authority and is not published by this ceremony.

---

## Publishing and verifying the authority

```
sudo provisioning/artifacts/install-verification-package.sh --verify
sudo provisioning/artifacts/install-verification-package.sh --install
sudo provisioning/artifacts/install-verification-package.sh --verify-installed
```

`--install` is idempotent where the bytes already agree and refuses where they
do not. It repairs nothing: a published object that disagrees with its pinned
digest is reported and left exactly as it is, because silently correcting
authority somebody else wrote is how a ceremony becomes an attack.

### Two pinned commits, and why

The package tree and the manifest are reviewed at **different** commits, and the
ceremony pins each to its own:

| Object | Pinned commit | Reason |
|---|---|---|
| `1.0.0/main.py` | `49c27fb6…` | the commit that introduced the package |
| `1.0.0.manifest.json` | `2575c042…` | the manifest names `CPKG-0001`, so it could not exist until that identity was predicted |

Collapsing them into one pin would be a pin that never held. The question *which
Git object authorised these bytes* has exactly one answer per object.

The manifest is published **beside** the tree, never inside it: it carries the
tree commitment, so a manifest within the tree would have to contain a digest
taken over its own bytes.
