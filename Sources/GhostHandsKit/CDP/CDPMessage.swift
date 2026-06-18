import Foundation

/// The PURE wire layer of a CDP session: request ENCODE + reply CLASSIFY. This is
/// the id-match + event-skip heart, ported from the Python `_CDPSession.call`
/// inner loop, with NO socket and NO RFC 6455 framing (URLSession owns the
/// handshake/masking/framing/ping-pong now — so there is no frame codec to test;
/// the hermetic surface is just encode + classify).
///
/// Params travel as `[String:Any]` to stay Foundation-native like JSONRPC.swift,
/// and `Frame`'s `Equatable` is HAND-WRITTEN comparing id/method only (mirroring
/// `ValueVerdict.Result`'s hand-rolled `==`), since a `[String:Any]` payload is
/// not itself `Equatable`.
public enum CDPMessage {
    // MARK: - Request encode (PURE)

    /// Encode a CDP request `{"id":…,"method":…,"params":…}` to compact `Data`.
    /// Throws `cdpTransport` if the params are not a serialisable JSON object
    /// (refuse rather than send a malformed frame).
    public static func encodeRequest(id: Int, method: String,
                                     params: [String: Any]) throws -> Data {
        let obj: [String: Any] = ["id": id, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(obj) else {
            throw GhostHandsError.cdpTransport(
                reason: "\(method): params are not a valid JSON object")
        }
        do {
            return try JSONSerialization.data(withJSONObject: obj, options: [])
        } catch {
            throw GhostHandsError.cdpTransport(
                reason: "\(method): could not encode request")
        }
    }

    // MARK: - Reply classify (PURE — the id-match core)

    /// A decoded inbound CDP text frame, classified relative to the id we await.
    /// The `[String:Any]` result payload is carried for `.reply` but EXCLUDED from
    /// equality (hand-written `==`), since `[String:Any]` is not `Equatable`.
    ///
    /// NOT `Sendable`: it carries a `[String:Any]` (not provably Sendable), and it
    /// never crosses an isolation boundary — `classify` returns it and `CDPSession.
    /// call` switches on it synchronously, all within the actor. Declaring
    /// `Sendable` here would be a lie the compiler flags in Swift 6 language mode.
    public enum Frame {
        /// A success reply whose id matches the one we sent. `result` is the
        /// CDP method's result object (nil when the reply omits `result`).
        case reply(id: Int, result: [String: Any]?)
        /// An error reply whose id matches — carries the CDP error message.
        case errorReply(id: Int, message: String)
        /// An unsolicited event (`{"method":…}`) OR a reply for a DIFFERENT id —
        /// SKIP it and keep waiting for our reply.
        case event(method: String)
        /// Anything else (un-decodable / no id / no method) — also skipped.
        case other
    }

    /// Classify one inbound text frame against the id we are waiting for.
    ///
    /// - `id == expecting` and has an `error` → `.errorReply` (surface + throw).
    /// - `id == expecting` → `.reply` (our answer; return its `result`).
    /// - has a `method` (an event), OR an `id` that is NOT ours → `.event` (SKIP).
    /// - otherwise (no id, no method, or un-decodable) → `.other` (SKIP).
    ///
    /// This is the id-match + event-skip pure core: a foreign event stream or a
    /// reply addressed to another in-flight call is skipped so the caller's
    /// deadline-loop only returns OUR reply.
    public static func classify(_ text: String, expecting id: Int) -> Frame {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let obj = root as? [String: Any]
        else { return .other }

        // An `id` may decode as an NSNumber; normalise to Int for the match.
        let frameID: Int? = (obj["id"] as? NSNumber)?.intValue

        if let frameID, frameID == id {
            if let err = obj["error"] as? [String: Any] {
                let message = (err["message"] as? String) ?? "CDP error"
                return .errorReply(id: id, message: message)
            }
            return .reply(id: id, result: obj["result"] as? [String: Any])
        }

        // Not our reply. An event carries a `method`; a foreign-id reply has an
        // id but no method — both are skipped, but we tag an event distinctly so
        // a reader can see WHY it was skipped.
        if let method = obj["method"] as? String {
            return .event(method: method)
        }
        if frameID != nil {
            // A reply addressed to a different in-flight id — skip like an event.
            return .event(method: "")
        }
        return .other
    }
}

// Hand-written Equatable: compare the discriminant + id/method only, IGNORING the
// `[String:Any]` result payload (which is not Equatable). Mirrors
// `ValueVerdict.Result`'s hand-rolled `==`.
extension CDPMessage.Frame: Equatable {
    public static func == (lhs: CDPMessage.Frame, rhs: CDPMessage.Frame) -> Bool {
        switch (lhs, rhs) {
        case let (.reply(l, _), .reply(r, _)):
            return l == r
        case let (.errorReply(li, lm), .errorReply(ri, rm)):
            return li == ri && lm == rm
        case let (.event(lm), .event(rm)):
            return lm == rm
        case (.other, .other):
            return true
        default:
            return false
        }
    }
}
