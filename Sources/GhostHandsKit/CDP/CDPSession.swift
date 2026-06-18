import Foundation

/// The IMPURE CDP session spine + its test seam. The pure heart (encode +
/// id-match classify) lives in `CDPMessage`; this file is the I/O loop over a
/// WebSocket and the loopback security gate.
///
/// The session ports the Python `_CDPSession.call` deadline-loop onto
/// `URLSessionWebSocketTask`. The RFC 6455 layer is GONE: URLSession owns the
/// handshake, masking, framing, and ping/pong, so `receive()` already hands back
/// ONE complete text message — the per-message granularity the classifier expects
/// is automatic, and there is no frame codec to test. Slice 1's hermetic surface
/// is therefore just (a) `/json/list` decode, (b) the classifier, (c) this
/// deadline-loop over a FAKE transport.

// MARK: - Transport seam

/// The test seam — the message-granularity socket the session drives. The real
/// impl wraps `URLSessionWebSocketTask`; tests supply a `FakeTransport` that
/// replays scripted frames (replacing the Python `_FakeSocket`, but at the
/// message layer, not the byte layer).
public protocol WebSocketTransport: Sendable {
    /// Send one CDP text message.
    func send(_ text: String) async throws
    /// Receive the NEXT complete CDP text message.
    func receive() async throws -> String
}

/// The real transport: a thin wrapper over `URLSessionWebSocketTask`. `send`
/// pushes a text frame; `receive` unwraps `.string` (a binary `.data` frame or a
/// closed socket throws `cdpTransport` — CDP is a text protocol, so a data frame
/// is unexpected, never silently dropped).
///
/// NOT unit-tested (it opens a real socket); exercised only in manual live-verify
/// against an already-open debug port, per the design doc.
public struct URLSessionWSTransport: WebSocketTransport {
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession = .shared) {
        self.task = session.webSocketTask(with: url)
        self.task.resume()
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        let message = try await task.receive()
        switch message {
        case let .string(s):
            return s
        case .data:
            throw GhostHandsError.cdpTransport(
                reason: "received a binary frame on a text CDP socket")
        @unknown default:
            throw GhostHandsError.cdpTransport(
                reason: "received an unknown WebSocket frame type")
        }
    }

    /// Close the underlying task (best-effort; a CDP session is short-lived).
    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Session

/// An `actor` so the `nextID` counter is isolated — the Python global `_next_id`
/// was single-threaded, but Swift concurrency needs the actor to keep concurrent
/// `call`s from racing the id. Holds a `WebSocketTransport` and pre-increments
/// `nextID` so the first call's id is 1 (matching the Python `{"id":1}` fixtures).
public actor CDPSession {
    private let transport: WebSocketTransport
    private var nextID = 0

    /// Direct init over any transport — used by `open(wsURL:)` (real socket) and
    /// by hermetic tests (fake transport). `open(wsURL:)` is the security-gated
    /// entry; this init trusts its caller to have gated.
    public init(transport: WebSocketTransport) {
        self.transport = transport
    }

    /// The SECURITY-gated factory: enforce loopback-only BEFORE creating a real
    /// `URLSessionWebSocketTask`, so a non-loopback `webSocketDebuggerUrl` THROWS
    /// `cdpTransport` and never reaches a socket. Slice 1 connects to an
    /// already-open port only — there is no launch/relaunch here.
    public static func open(wsURL: String) throws -> CDPSession {
        guard CDPTarget.isLoopback(wsURL) else {
            throw GhostHandsError.cdpTransport(
                reason: "refusing a non-loopback CDP socket: \(wsURL) "
                    + "(only 127.0.0.1/::1/localhost allowed)")
        }
        guard let url = URL(string: wsURL) else {
            throw GhostHandsError.cdpTransport(
                reason: "unparseable webSocketDebuggerUrl: \(wsURL)")
        }
        return CDPSession(transport: URLSessionWSTransport(url: url))
    }

    /// Issue one CDP call and return its `result`, skipping foreign events and
    /// foreign-id replies. The deadline is checked at the TOP of every iteration,
    /// so a never-arriving reply RAISES `cdpTransport("no response…")` instead of
    /// hanging — even against an endless foreign-event stream (the single most
    /// important behavior, per the design doc). An `errorReply` throws the CDP
    /// error message.
    public func call(_ method: String, params: [String: Any] = [:],
                     deadline: Duration = .seconds(10)) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let data = try CDPMessage.encodeRequest(id: id, method: method, params: params)
        try await transport.send(String(decoding: data, as: UTF8.self))

        let end = ContinuousClock.now + deadline
        while true {
            if ContinuousClock.now >= end {
                throw GhostHandsError.cdpTransport(
                    reason: "\(method): no response id=\(id) within \(deadline)")
            }
            let text = try await transport.receive()
            switch CDPMessage.classify(text, expecting: id) {
            case .event, .other:
                continue // skip a foreign event / foreign-id reply / junk
            case let .errorReply(_, message):
                throw GhostHandsError.cdpTransport(reason: "\(method): \(message)")
            case let .reply(_, result):
                return result ?? [:]
            }
        }
    }
}
