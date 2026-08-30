import AppKit
import Darwin
import Foundation

// One-shot, public metadata lookup used at capture start. It identifies the
// currently running Ampersand application without reading input or changing
// application, cursor, or window state.

let expectedBundleIdentifier = "com.crossinput.Ampersand"
let candidates = NSWorkspace.shared.runningApplications.filter { application in
    application.bundleIdentifier == expectedBundleIdentifier
        || application.localizedName == "Ampersand"
        || application.executableURL?.lastPathComponent == "Ampersand"
}
let uniqueCandidates = Dictionary(grouping: candidates, by: { $0.processIdentifier })
    .compactMap { $0.value.first }
guard uniqueCandidates.count == 1,
      let application = uniqueCandidates.first,
      let bundleURL = application.bundleURL,
      let executableURL = application.executableURL else {
    fputs("expected exactly one running Ampersand application\n", stderr)
    exit(2)
}

let info = Bundle(url: bundleURL)?.infoDictionary ?? [:]
func infoString(_ keys: [String]) -> String? {
    for key in keys {
        if let value = info[key] as? String, !value.isEmpty {
            return value
        }
    }
    return nil
}

let bundleIdentifier = application.bundleIdentifier
    ?? infoString(["CFBundleIdentifier"])
let shortVersion = infoString(["CFBundleShortVersionString"])
let bundleVersion = infoString(["CFBundleVersion"])
guard let bundleIdentifier, !bundleIdentifier.isEmpty,
      let shortVersion, !shortVersion.isEmpty,
      let bundleVersion, !bundleVersion.isEmpty else {
    fputs("running Ampersand is missing required bundle identity fields\n", stderr)
    exit(2)
}

// The packaged app may contain the build-time candidate identifier generated
// by scripts/package-macos.sh. Extract only a full SHA-shaped token from the
// executable; arbitrary binary contents are never written to evidence.
var embeddedSourceSHA = infoString([
    "CrossInputSourceSHA", "CandidateIdentifier", "SCMRevision", "GitCommit",
])
if embeddedSourceSHA == nil,
   let executableData = try? Data(contentsOf: executableURL),
   let executableText = Optional(String(decoding: executableData, as: UTF8.self)),
   let expression = try? NSRegularExpression(pattern: "\\b[0-9a-fA-F]{40}(?:-dirty)?\\b") {
    let range = NSRange(executableText.startIndex..<executableText.endIndex, in: executableText)
    embeddedSourceSHA = expression.firstMatch(in: executableText, range: range).flatMap {
        Range($0.range, in: executableText).map { String(executableText[$0]) }
    }
}

let value: [String: Any] = [
    "schema": 1,
    "resolved": true,
    "pid": application.processIdentifier,
    "process_name": application.localizedName ?? "Ampersand",
    "bundle_identifier": bundleIdentifier,
    "bundle_short_version": shortVersion,
    "bundle_version": bundleVersion,
    "bundle_path": bundleURL.path,
    "executable_path": executableURL.path,
    "crossinput_source_sha": embeddedSourceSHA ?? "unknown",
    "crossinput_build_identifier": infoString([
        "CrossInputBuildIdentifier", "BuildIdentifier",
    ]) ?? "unknown",
]
guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      let output = String(data: data, encoding: .utf8) else {
    exit(3)
}
print(output)
