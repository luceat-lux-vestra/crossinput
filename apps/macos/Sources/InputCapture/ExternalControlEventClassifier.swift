import Foundation

/// Metadata resolved from a CGEvent source. It intentionally carries identity
/// only; event payloads, key codes, coordinates, and clipboard data never enter
/// the classifier.
public struct ExternalControlEventSource: Sendable, Equatable, Hashable {
    public let processID: Int32
    public let bundleIdentifier: String?
    public let executablePath: String?
    public let processName: String?

    public init(processID: Int32,
                bundleIdentifier: String? = nil,
                executablePath: String? = nil,
                processName: String? = nil) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.processName = processName
    }
}

/// Exact process identities which are allowed to request local control.
/// Matching is deliberately strict: a process must match a configured bundle
/// identifier or executable path. Process names and substring heuristics are
/// never used as authority.
public struct RecognizedExternalControlSource: Sendable, Equatable {
    public let provider: String
    public let bundleIdentifier: String?
    public let executablePath: String?

    public init(provider: String,
                bundleIdentifier: String? = nil,
                executablePath: String? = nil) {
        self.provider = provider
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }
}

/// Pure identity classifier for external-control takeover events.
public struct ExternalControlEventClassifier: Sendable {
    public static let defaultSources: [RecognizedExternalControlSource] = [
        // Exact bundle identity from the installed RustDesk application. The
        // CGEvent source matrix is still required during physical verification.
        RecognizedExternalControlSource(
            provider: "rustdesk",
            bundleIdentifier: "com.carriez.rustdesk"
        )
    ]

    private let ownProcessID: Int32
    private let recognizedSources: [RecognizedExternalControlSource]

    public init(ownProcessID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
                recognizedSources: [RecognizedExternalControlSource] = Self.defaultSources) {
        self.ownProcessID = ownProcessID
        self.recognizedSources = recognizedSources
    }

    public func provider(for source: ExternalControlEventSource) -> String? {
        guard source.processID > 0, source.processID != ownProcessID else { return nil }

        return recognizedSources.first { candidate in
            if let bundleIdentifier = candidate.bundleIdentifier,
               source.bundleIdentifier == bundleIdentifier {
                return true
            }
            if let executablePath = candidate.executablePath,
               source.executablePath == executablePath {
                return true
            }
            return false
        }?.provider
    }

    public func isExternalControl(_ source: ExternalControlEventSource) -> Bool {
        provider(for: source) != nil
    }
}
