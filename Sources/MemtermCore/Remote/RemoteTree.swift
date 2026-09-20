import Foundation

// Remote-attach wire model (decision doc 2026-09-19): the workspace tree
// shape sent to a phone client over RemoteMessage.tree. Task 5 stubs the
// full field set now (matching the controller's pre-flight scan) so Task 7's
// tree builder only adds construction logic, never a field.

public struct RemotePane: Codable, Equatable {
    public var id: String
    public var adapter: String
    public var cwd: String?

    public init(id: String, adapter: String, cwd: String?) {
        self.id = id
        self.adapter = adapter
        self.cwd = cwd
    }
}

public struct RemoteTab: Codable, Equatable {
    public var id: String
    public var title: String
    public var panes: [RemotePane]

    public init(id: String, title: String, panes: [RemotePane]) {
        self.id = id
        self.title = title
        self.panes = panes
    }
}

public struct RemoteWindow: Codable, Equatable {
    public var id: String
    public var tabs: [RemoteTab]

    public init(id: String, tabs: [RemoteTab]) {
        self.id = id
        self.tabs = tabs
    }
}

public struct RemoteWorkspace: Codable, Equatable {
    public var id: String
    public var name: String
    public var color: String
    public var locked: Bool
    public var parked: Bool
    public var windows: [RemoteWindow]

    public init(id: String, name: String, color: String, locked: Bool, parked: Bool, windows: [RemoteWindow]) {
        self.id = id
        self.name = name
        self.color = color
        self.locked = locked
        self.parked = parked
        self.windows = windows
    }
}

public struct RemoteTree: Codable, Equatable {
    public var workspaces: [RemoteWorkspace]

    public init(workspaces: [RemoteWorkspace]) {
        self.workspaces = workspaces
    }
}
