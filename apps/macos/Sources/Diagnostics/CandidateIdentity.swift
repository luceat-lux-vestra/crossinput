import Foundation

/// Build-time candidate identity for ADR-0012 Level-3 evidence attribution.
///
/// `injectedCandidateIdentifier` / `injectedBuildIdentifier` are defined by
/// the packaging path (`scripts/package-macos.sh`), which generates
/// `CandidateIdentity+Generated.swift` into this target before compiling.
/// They are immutable after build and never read from `.git` at runtime
/// (AGENTS.md). When building without that step (bare `swift build`), a
/// build-settings-free default is required — see below.
///
/// Empty values mean "not attributable": the Level-3 analyzer fails closed
/// (INSUFFICIENT_EVIDENCE) on artifacts built without the canonical step.
public enum CandidateIdentity {
#if CANDIDATE_IDENTITY_GENERATED
    // Provided by CandidateIdentity+Generated.swift (packaging path).
#else
    /// Fallback so bare `swift build` compiles: not attributable.
    nonisolated(unsafe) internal static let injectedCandidateIdentifier: String = ""
    nonisolated(unsafe) internal static let injectedBuildIdentifier: String = ""
#endif

    /// Build-time injected candidate SHA (or "<sha>-dirty").
    public static var candidateIdentifier: String { injectedCandidateIdentifier }

    /// Build-time injected UTC build timestamp.
    public static var buildIdentifier: String { injectedBuildIdentifier }

    /// Human-readable app version (marketing version from Info.plist).
    public static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// True when all three identity fields are usable for attribution.
    public static var isAttributable: Bool {
        !candidateIdentifier.isEmpty && !buildIdentifier.isEmpty && appVersion != "unknown"
    }

    /// Single machine-parseable diagnostics line. The analyzer keys on the
    /// stable prefix and field names; values carry no private identifiers.
    public static var diagnosticMarker: String {
        "candidate identity app_version=\(appVersion) "
            + "build_identifier=\(buildIdentifier.isEmpty ? "none" : buildIdentifier) "
            + "candidate_identifier=\(candidateIdentifier.isEmpty ? "none" : candidateIdentifier)"
    }
}
