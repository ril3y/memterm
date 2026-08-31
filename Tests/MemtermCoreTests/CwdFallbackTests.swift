import XCTest
@testable import MemtermCore

final class CwdFallbackTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExistingDirectoryPassesThrough() throws {
        let dir = tempDir.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = CwdFallback.resolve(dir.path)
        XCTAssertEqual(result.path, dir.path)
        XCTAssertFalse(result.fellBack)
    }

    func testMissingDirectoryWalksToNearestExistingAncestor() throws {
        let existing = tempDir.appendingPathComponent("repo/worktree")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let vanished = existing.appendingPathComponent("deleted/branch/dir")
        let result = CwdFallback.resolve(vanished.path)
        XCTAssertEqual(result.path, existing.path)
        XCTAssertTrue(result.fellBack)
    }

    func testFileInsteadOfDirectoryFallsBackToParent() throws {
        let file = tempDir.appendingPathComponent("notes.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let result = CwdFallback.resolve(file.path)
        XCTAssertEqual(result.path, tempDir.path)
        XCTAssertTrue(result.fellBack)
    }

    func testFullyVanishedPathLandsOnHome() {
        let gone = "/memterm-gone-\(UUID().uuidString)/x/y"
        let result = CwdFallback.resolve(gone, home: "/custom-home")
        XCTAssertEqual(result.path, "/custom-home")
        XCTAssertTrue(result.fellBack)

        // Default home parameter is the real home directory.
        let real = CwdFallback.resolve(gone)
        XCTAssertEqual(real.path, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertTrue(real.fellBack)
    }

    func testNilAndRelativePathsLandOnHome() {
        let nilResult = CwdFallback.resolve(nil, home: "/h")
        XCTAssertEqual(nilResult.path, "/h")
        XCTAssertFalse(nilResult.fellBack)

        let relative = CwdFallback.resolve("not/absolute", home: "/h")
        XCTAssertEqual(relative.path, "/h")
        XCTAssertFalse(relative.fellBack)
    }
}
