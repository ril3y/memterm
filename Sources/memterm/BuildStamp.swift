import Foundation

// Build identity (TESTING.md §3.1 / bug 5 regression): every binary must be
// able to say exactly which commit it was built from. This checked-in file is
// the DEV FALLBACK — plain `swift build` / `swift test` binaries identify as
// "dev-unstamped" and can never satisfy verify.sh's identity check.
//
// scripts/make-app.sh generates Sources/memterm/BuildStamp.generated.swift
// (gitignored) with the real git hash / build time and compiles with
// -DMEMTERM_STAMPED, which switches this enum over to the generated values.

#if MEMTERM_STAMPED
enum BuildStamp {
    static let version = GeneratedBuildStamp.version
    static let gitHash = GeneratedBuildStamp.gitHash
    static let buildTimeUTC = GeneratedBuildStamp.buildTimeUTC
}
#else
enum BuildStamp {
    static let version = "0.1"
    static let gitHash = "dev-unstamped"
    static let buildTimeUTC = ""
}
#endif

extension BuildStamp {
    /// The one-line self-identification every gate log leads with.
    static var describe: String {
        "memterm \(version) (\(gitHash))"
            + (buildTimeUTC.isEmpty ? "" : " built \(buildTimeUTC)")
    }
}
