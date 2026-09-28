import Foundation

// Remote-attach outer envelope (decision doc 2026-09-19): the Node relay
// routes purely on `to`/`from` and never inspects `payload` (an
// end-to-end-encrypted RemoteMessage). The relay's own JSON uses these exact
// key names, so this type mirrors that contract rather than defining its own.
public struct RemoteEnvelope: Equatable {
    public var to: String
    public var from: String
    public var payload: Data

    public init(to: String, from: String, payload: Data) {
        self.to = to
        self.from = from
        self.payload = payload
    }

    // JSONEncoder/JSONDecoder's default Data strategy is base64, matching
    // the relay's `payload` field.
    private struct Wire: Codable {
        var type: String
        var to: String?
        var from: String?
        var payload: Data?
    }

    public func encode() -> Data {
        let wire = Wire(type: "env", to: to, from: from, payload: payload)
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }

    public static func decode(_ data: Data) -> RemoteEnvelope? {
        guard
            let wire = try? JSONDecoder().decode(Wire.self, from: data),
            wire.type == "env",
            let to = wire.to,
            let from = wire.from,
            let payload = wire.payload
        else { return nil }
        return RemoteEnvelope(to: to, from: from, payload: payload)
    }
}
