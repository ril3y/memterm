import Foundation

// Remote-attach inner protocol (decision doc 2026-09-19): the end-to-end
// encrypted message a phone client and this host exchange, carried inside a
// RemoteEnvelope's payload. A Node relay and a future TypeScript web client
// speak the same JSON, so the "t" tag values and field names below are a
// cross-language contract, not an implementation detail — do not rename
// without updating relay/ and the web client in lockstep.
public enum RemoteMessage: Equatable {
    case list
    case attach(paneId: String)
    case detach
    case input(Data)
    case resize(cols: Int, rows: Int)
    case newTab(workspaceId: String)
    case unlock(workspaceId: String, passphrase: String)
    case tree(RemoteTree)
    case screen(cols: Int, rows: Int, bytes: Data)
    case output(Data)
    case treeChanged
    case refused(reason: String)
    case resized(cols: Int, rows: Int)

    // JSONEncoder/JSONDecoder's default Data strategy is base64, which is
    // exactly the wire contract ("b" fields are base64 strings) — so the
    // wire struct's `b: Data?` gets the encoding for free.
    private struct Wire: Codable {
        var t: String
        var paneId: String?
        var b: Data?
        var cols: Int?
        var rows: Int?
        var workspaceId: String?
        var passphrase: String?
        var tree: RemoteTree?
        var reason: String?

        init(
            t: String,
            paneId: String? = nil,
            b: Data? = nil,
            cols: Int? = nil,
            rows: Int? = nil,
            workspaceId: String? = nil,
            passphrase: String? = nil,
            tree: RemoteTree? = nil,
            reason: String? = nil
        ) {
            self.t = t
            self.paneId = paneId
            self.b = b
            self.cols = cols
            self.rows = rows
            self.workspaceId = workspaceId
            self.passphrase = passphrase
            self.tree = tree
            self.reason = reason
        }
    }

    public func encode() -> Data {
        let wire: Wire
        switch self {
        case .list:
            wire = Wire(t: "list")
        case .attach(let paneId):
            wire = Wire(t: "attach", paneId: paneId)
        case .detach:
            wire = Wire(t: "detach")
        case .input(let data):
            wire = Wire(t: "input", b: data)
        case .resize(let cols, let rows):
            wire = Wire(t: "resize", cols: cols, rows: rows)
        case .newTab(let workspaceId):
            wire = Wire(t: "newTab", workspaceId: workspaceId)
        case .unlock(let workspaceId, let passphrase):
            wire = Wire(t: "unlock", workspaceId: workspaceId, passphrase: passphrase)
        case .tree(let tree):
            wire = Wire(t: "tree", tree: tree)
        case .screen(let cols, let rows, let bytes):
            wire = Wire(t: "screen", b: bytes, cols: cols, rows: rows)
        case .output(let data):
            wire = Wire(t: "output", b: data)
        case .treeChanged:
            wire = Wire(t: "tree-changed")
        case .refused(let reason):
            wire = Wire(t: "refused", reason: reason)
        case .resized(let cols, let rows):
            wire = Wire(t: "resized", cols: cols, rows: rows)
        }
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }

    public static func decode(_ data: Data) -> RemoteMessage? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch wire.t {
        case "list":
            return .list
        case "attach":
            guard let paneId = wire.paneId else { return nil }
            return .attach(paneId: paneId)
        case "detach":
            return .detach
        case "input":
            guard let b = wire.b else { return nil }
            return .input(b)
        case "resize":
            guard let cols = wire.cols, let rows = wire.rows else { return nil }
            return .resize(cols: cols, rows: rows)
        case "newTab":
            guard let workspaceId = wire.workspaceId else { return nil }
            return .newTab(workspaceId: workspaceId)
        case "unlock":
            guard let workspaceId = wire.workspaceId, let passphrase = wire.passphrase else { return nil }
            return .unlock(workspaceId: workspaceId, passphrase: passphrase)
        case "tree":
            guard let tree = wire.tree else { return nil }
            return .tree(tree)
        case "screen":
            guard let cols = wire.cols, let rows = wire.rows, let b = wire.b else { return nil }
            return .screen(cols: cols, rows: rows, bytes: b)
        case "output":
            guard let b = wire.b else { return nil }
            return .output(b)
        case "tree-changed":
            return .treeChanged
        case "refused":
            guard let reason = wire.reason else { return nil }
            return .refused(reason: reason)
        case "resized":
            guard let cols = wire.cols, let rows = wire.rows else { return nil }
            return .resized(cols: cols, rows: rows)
        default:
            return nil
        }
    }
}
