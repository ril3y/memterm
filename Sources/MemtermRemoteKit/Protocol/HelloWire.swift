import Foundation

/// The handshake's clear-text wire form (decision doc 2026-09-19): a `Hello`
/// rides in the clear inside a `RemoteEnvelope`'s payload — there is no key
/// yet — tagged `"hs": "hello"` so it can never be confused with a sealed
/// `RemoteMessage` record. Every party that speaks this protocol (the Mac
/// host, the headless probe client, the phone's `HostSession`, and the
/// TypeScript web client) must agree on this exact shape byte-for-byte, so
/// there is exactly one Swift definition — this one.
public enum HelloWire {
    private struct Wire: Codable {
        var hs: String
        var eph: Data
        var sig: Data
    }

    public static func encode(_ hello: RemoteHandshake.Hello) -> Data {
        let wire = Wire(hs: "hello", eph: hello.ephemeralRaw, sig: hello.signature)
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }

    public static func decode(_ data: Data) -> RemoteHandshake.Hello? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.hs == "hello"
        else { return nil }
        return RemoteHandshake.Hello(ephemeralRaw: wire.eph, signature: wire.sig)
    }
}
