import AppKit
import ApplicationServices
import AXorcist
import Foundation

/// The `find` verb — an existence PROBE, not a click-target resolver.
///
/// Unlike `click` (which filters to pressable controls and refuses on
/// ambiguity), `find` answers a different question: does ANYTHING named this
/// exist on screen — including static labels and disabled controls? So multiple
/// matches is EXPECTED and is a success, not a refuse. The role is always
/// reported so a reader sees `AXStaticText` vs `AXButton` and never assumes a
/// found name is clickable.
public enum FindResult {
    /// Pure rendering of a deduped hit list. Input is fabricated-or-real facts,
    /// so this is hermetically testable.
    public static func dedup(_ facts: [ElementFacts]) -> [ElementFacts] {
        var seen = Set<String>()
        var out: [ElementFacts] = []
        for f in facts where seen.insert(NameMatch.identityKey(f)).inserted {
            out.append(f)
        }
        return out
    }

    /// One hit rendered as e.g. `AXButton "7" value=nil`.
    public static func line(_ f: ElementFacts) -> String {
        let role = f.role ?? "AXUnknown"
        let name = f.title ?? f.identifier ?? f.descriptionText ?? f.value ?? "?"
        var s = "\(role) \(name.debugDescription)"
        if let v = f.value, !v.isEmpty, v != name { s += " value=\(v.debugDescription)" }
        if f.enabled == false { s += " (disabled)" }
        return s
    }

    /// The human report: first hit + `(+N more)` when there are several. An
    /// empty list yields nil (the caller turns that into the not-found refuse).
    public static func report(_ deduped: [ElementFacts]) -> String? {
        guard let first = deduped.first else { return nil }
        if deduped.count == 1 { return line(first) }
        return line(first) + " (+\(deduped.count - 1) more)"
    }
}

extension GhostHands {
    public struct FindOutcome: Sendable {
        public let app: String
        public let query: String
        public let hits: [ElementFacts]   // deduped
        public var found: Bool { !hits.isEmpty }
    }

    /// Probe for an element named `query` across the ENTIRE tree, static text
    /// included. Pure read. Throws on app-resolution / permission failure;
    /// returns `found == false` (NOT a throw) when nothing matches — the CLI
    /// turns that into a clean exit 1 with a "not found" message.
    @MainActor
    public static func find(query: String, appSpec: String,
                            settle: TimeInterval = 0.4) throws -> FindOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        func search(under root: Element) -> [ElementFacts] {
            // The shared PRESENCE read (NOT Finder.options(): no enabledOnly, so
            // static labels and disabled controls still count; only menu noise
            // excluded). The same path `assert`'s `observe` uses, so the two
            // presence answers cannot drift. presenceMatches is cycle-safe
            // (Finder.descendants + visited-set).
            Finder.presenceMatches(named: query, under: root).map { $0.1 }
        }

        var hits = FindResult.dedup(search(under: target.element))
        if hits.isEmpty, settle > 0 {
            Thread.sleep(forTimeInterval: settle)
            let fresh = Element(AXUIElementCreateApplication(target.pid))
            hits = FindResult.dedup(search(under: fresh))
        }
        return FindOutcome(app: target.name, query: query, hits: hits)
    }
}
