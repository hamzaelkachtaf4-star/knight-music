import Foundation
import XCTest
#if canImport(KnightMusic)
@testable import KnightMusic
#endif

/// Loads files from `KnightMusicTests/Fixtures`: from the test bundle in CI, from `KM_FIXTURES` when the
/// Foundation-only tests run locally through `scripts/core-tests.sh`.
enum Fixture {
    private final class Token {}

    static func url(_ name: String) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let url = Bundle(for: Token.self).url(forResource: base, withExtension: ext) { return url }
        if let dir = ProcessInfo.processInfo.environment["KM_FIXTURES"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing fixture \(name)"])
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func string(_ name: String) throws -> String {
        try XCTUnwrap(String(data: data(name), encoding: .utf8))
    }

    static func json(_ name: String) throws -> JSONObject {
        try XCTUnwrap(InnertubeJSON.parse(data(name)), "\(name) is not a JSON object")
    }
}
