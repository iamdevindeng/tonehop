import Foundation

/// Immutable provenance embedded by the shared Xcode build phase.
/// No Git or filesystem discovery runs in the application process.
struct BuildInfo: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let applicationVersion: String
    let buildNumber: String
    let configuration: String
    let gitCommit: String
    let gitWorkingTreeState: String
    let sourceDigestAlgorithm: String
    let sourceDigest: String
    let sourceFileCount: Int

    static let current = load(from: .main)

    static func load(from bundle: Bundle) -> BuildInfo {
        let data = bundle.url(forResource: "BuildInfo", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        return decode(data) ?? unknown(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func decode(_ data: Data?) -> BuildInfo? {
        guard let data, let result = try? JSONDecoder().decode(Self.self, from: data),
              result.schemaVersion == 1,
              ["clean", "dirty", "unknown"].contains(result.gitWorkingTreeState),
              result.sourceDigestAlgorithm == "sha256-manifest-v1",
              result.sourceDigest.utf8.count == 64,
              result.sourceDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              result.sourceFileCount > 0 else { return nil }
        return result
    }

    static func unknown(version: String? = nil, buildNumber: String? = nil) -> BuildInfo {
        BuildInfo(schemaVersion: 1, applicationVersion: version ?? "unknown",
                  buildNumber: buildNumber ?? "unknown", configuration: "unknown",
                  gitCommit: "unknown", gitWorkingTreeState: "unknown",
                  sourceDigestAlgorithm: "unknown", sourceDigest: "unknown", sourceFileCount: 0)
    }

    var diagnosticFields: [String: Any] {
        ["schemaVersion": schemaVersion, "applicationVersion": applicationVersion,
         "buildNumber": buildNumber, "configuration": configuration,
         "gitCommit": gitCommit, "gitWorkingTreeState": gitWorkingTreeState,
         "sourceDigestAlgorithm": sourceDigestAlgorithm, "sourceDigest": sourceDigest,
         "sourceFileCount": sourceFileCount]
    }
}
