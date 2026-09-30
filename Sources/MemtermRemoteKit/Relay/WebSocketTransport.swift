import Foundation

/// One WebSocket, as the relay client uses it. `receive` delivers ONE frame
/// and must be re-armed by the caller — exactly URLSessionWebSocketTask's
/// contract, which keeps the production wrapper trivial and the fake honest.
public protocol WebSocketTransport: AnyObject {
    func resume()
    func send(_ text: String, completion: @escaping (Error?) -> Void)
    func sendPing(_ completion: @escaping (Error?) -> Void)
    func receive(_ handler: @escaping (Result<String, Error>) -> Void)
    func cancel()
}

public protocol WebSocketTransportFactory {
    func makeTransport(url: URL) -> WebSocketTransport
}

public final class URLSessionWebSocketTransport: WebSocketTransport {
    private let task: URLSessionWebSocketTask
    public init(url: URL) { task = URLSession.shared.webSocketTask(with: url) }
    public func resume() { task.resume() }
    public func send(_ text: String, completion: @escaping (Error?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }
    public func sendPing(_ completion: @escaping (Error?) -> Void) { task.sendPing(pongReceiveHandler: completion) }
    public func receive(_ handler: @escaping (Result<String, Error>) -> Void) {
        task.receive { result in
            switch result {
            case .failure(let error): handler(.failure(error))
            case .success(.string(let text)): handler(.success(text))
            case .success(.data(let data)): handler(.success(String(decoding: data, as: UTF8.self)))
            case .success: handler(.success(""))
            }
        }
    }
    public func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

public struct URLSessionTransportFactory: WebSocketTransportFactory {
    public init() {}
    public func makeTransport(url: URL) -> WebSocketTransport { URLSessionWebSocketTransport(url: url) }
}
