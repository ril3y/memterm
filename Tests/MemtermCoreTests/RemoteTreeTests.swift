import XCTest
@testable import MemtermCore

// Remote-attach wire model (decision doc 2026-09-19): pins the JSON shape of
// RemoteTree sent to a phone client over RemoteMessage.tree. A locked
// workspace and a parked workspace are both exercised since those two
// booleans gate client-side affordances (unlock prompt, hidden-from-list).
final class RemoteTreeTests: XCTestCase {
    func testTreeRoundTripsThroughJSONWithLockedAndParkedWorkspaces() throws {
        let pane1 = RemotePane(id: "pane-1", adapter: "zsh", cwd: "/Users/riley/project")
        let pane2 = RemotePane(id: "pane-2", adapter: "ssh", cwd: nil)
        let tab1 = RemoteTab(id: "tab-1", title: "main", panes: [pane1, pane2])
        let window1 = RemoteWindow(id: "window-1", tabs: [tab1])

        let pane3 = RemotePane(id: "pane-3", adapter: "zsh", cwd: "/tmp")
        let tab2 = RemoteTab(id: "tab-2", title: "scratch", panes: [pane3])
        let window2 = RemoteWindow(id: "window-2", tabs: [tab2])

        let lockedWorkspace = RemoteWorkspace(
            id: "ws-locked",
            name: "Vault",
            color: "red",
            locked: true,
            parked: false,
            windows: [window1]
        )
        let parkedWorkspace = RemoteWorkspace(
            id: "ws-parked",
            name: "Archive",
            color: "gray",
            locked: false,
            parked: true,
            windows: [window2]
        )

        let tree = RemoteTree(workspaces: [lockedWorkspace, parkedWorkspace])

        let encoder = JSONEncoder()
        let data = try encoder.encode(tree)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RemoteTree.self, from: data)

        XCTAssertEqual(decoded, tree)

        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"locked\":true"), "expected locked:true in \(json)")
    }

    func testEmptyTreeRoundTrips() throws {
        let tree = RemoteTree(workspaces: [])
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(RemoteTree.self, from: data)
        XCTAssertEqual(decoded, tree)
    }
}
