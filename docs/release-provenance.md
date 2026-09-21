# Release provenance

Ampersand release DMGs are bound to reviewed source in several independent layers.

## Producer contract

The GitHub release workflow:

1. runs from an immutable `v*` tag ref;
2. checks out that exact tag and proves the tagged commit is reachable from reviewed `main`;
3. requires the app version to match the tag;
4. verifies the app code signature and DMG integrity;
5. writes a SHA-256 sidecar;
6. creates a GitHub artifact attestation for the verified DMG **before** GitHub Release mutation;
7. publishes the DMG/checksum and then reads the release identity back.

The attestation supplements the tag, signature, DMG, checksum, and ancestry controls. It does not replace them.

Manual recovery must also execute the workflow from the exact immutable tag:

```bash
gh workflow run release.yml \
  --repo luceat-lux-vestra/crossinput \
  --ref vX.Y.Z \
  -f tag=vX.Y.Z
```

Running recovery from `main` or another branch is rejected even when the input tag is valid. This prevents the workflow/OIDC source identity from describing a different ref than the artifact source.

## Consumer verification

After downloading a release DMG, verify its GitHub/Sigstore build provenance:

```bash
gh attestation verify Ampersand-X.Y.Z.dmg \
  --repo luceat-lux-vestra/crossinput
```

Also verify the published checksum:

```bash
shasum -a 256 -c Ampersand-X.Y.Z.sha256
```

A successful attestation verifies the artifact digest and the GitHub-hosted provenance statement. It is not a Developer ID/notarization claim; current release signing limitations remain documented separately.

## Failure direction

Missing attestation authority, OIDC failure, artifact-attestation failure, tag/ref mismatch, signature/integrity failure, ambiguous release lookup, or published-identity mismatch fails the release workflow. The release path must not bypass attestation merely to recover publication.
