# ADR-0014: Product Brand and Technical Naming

> Status: **accepted**
> Date: 2026-09-04
> Supersedes: ADR-0002 where it defines the current product/tagline relationship or relies on future Android → macOS input as naming rationale

## Context

The repository historically used a two-name model:

- **Ampersand** as the user-facing product/application brand;
- **CrossInput** as a descriptive tagline plus the repository/technical name.

ADR-0002 also treated possible future Android → macOS keyboard/touch support as part of the rationale for a broad cross-input identity.

The product scope was later rebaselined by ADR-0013. Pointer and keyboard control are now intentionally one-way **macOS → Android**, with Android → macOS pointer/keyboard control explicitly out of scope. Clipboard/data sharing is a separate capability and may be bidirectional without changing the input-control direction.

At the same time, the shipped macOS product is already consistently named **Ampersand**: the Swift package/executable, application bundle, icon, release name, and DMG all use that brand.

Using CrossInput as the primary README/product name therefore creates an unnecessary split between the product users install and the project name they see first in the repository.

## Decision

1. **Ampersand is the user-facing product and application name.**
2. The repository remains named **`crossinput`**.
3. `crossinput` remains the technical/project namespace where renaming would create churn without user benefit.
4. The wire protocol continues to use the **CXI** prefix.
5. README and user-facing product documentation should lead with **Ampersand**, not CrossInput.
6. CrossInput may still be used descriptively for the repository/technical identity, but it is not a second product brand.
7. The naming rationale does **not** depend on future Android → macOS pointer or keyboard input.
8. Pointer and keyboard remain one-way **macOS → Android** under ADR-0013.
9. Bidirectional clipboard/data sharing remains separate from input-control direction and does not imply bidirectional pointer/keyboard control.

## Why keep the `crossinput` repository and technical namespace?

Renaming the repository, Android helper package structure, scripts, protocol references, and related technical identifiers would create migration and compatibility churn without improving the installed product experience. `crossinput` remains an accurate description of the technical domain: input crosses device boundaries from the Mac host to an Android target.

The existing **CXI** protocol prefix is concise and already established in fixtures, implementation, and documentation. It remains stable.

## Why keep Ampersand as the product brand?

Ampersand is already the concrete artifact users encounter:

- `Ampersand.app`;
- `Ampersand-<version>.dmg`;
- the Swift package/executable;
- application iconography and release naming.

The ampersand also works as a connection/joining metaphor between Mac and Android; it does not require symmetric input direction.

## Consequences

Positive:

- Repository landing pages match the actual installed product name.
- Product scope no longer appears to promise bidirectional input because of historical naming rationale.
- Existing repository/protocol identifiers remain stable.
- Release artifacts and documentation use one clear user-facing brand.

Negative:

- Repository URL and technical identifiers do not exactly match the product brand.
- Contributors must understand that `Ampersand` is the product while `crossinput`/`CXI` are technical names.

This distinction is intentional and should be explained once in the README rather than creating competing brands.

## Validation

- README leads with `# Ampersand`.
- README states that pointer/keyboard input is macOS → Android.
- README states that `crossinput` is the repository/technical namespace and CXI is the protocol prefix.
- Release artifacts remain named Ampersand.
- ADR-0013 remains authoritative for product direction and input topology.
- Documentation must not cite hypothetical Android → macOS input as a current naming or architecture requirement.
