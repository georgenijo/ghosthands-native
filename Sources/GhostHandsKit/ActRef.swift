import AXorcist
import Foundation

// GhostHands ACT-REF tier (A3) — the UNIFIED actuator. `act "@ref" <app>` resolves
// a ref from the LAST `see` and AUTO-PICKS the hand by the row's source: an
// ax-sourced ref → the invisible AX press/type; a cdp-sourced ref → the precise CDP
// click/type (by its @eN handle); an ocr-only ref → the visible HID click. The
// second half of "drive any app in two calls" (see → act), with no per-app recipe.
//
// HONESTY: `act` never invents an outcome — it delegates to the EXISTING per-tier
// verb (click / type / webClick / webType / ocrClick), each of which verifies by
// its own witness (AX read-back/effect-witness, CDP navigation/value read-back,
// pixel-diff) or reports dispatched-unverified. The ref layer ADDS only staleness
// refuses: no snapshot, a snapshot for a different app, an app relaunched since the
// see (PID changed), or an unknown/now-gone ref → REFUSE "re-see", never a guess.
// The pure plan (staleness decision + hand selection) is hermetically tested.

// MARK: - Pure: staleness decision

/// What `act "@ref"` decides from the persisted snapshot + the live app, BEFORE
/// touching any control. Pure over fabricated inputs.
public enum ActRefDecision: Sendable, Equatable {
    /// No `see` snapshot persisted → REFUSE `seeRequired`.
    case noSnapshot
    /// The snapshot is for a different app than the one being acted on → REFUSE.
    case appMismatch(snapshotApp: String, requested: String)
    /// The app was relaunched since the see (PID changed) → the whole snapshot's
    /// identities are stale → REFUSE.
    case relaunched
    /// The ref isn't in the snapshot → REFUSE.
    case unknownRef
    /// Good to go — act on this record.
    case proceed(SeeRecord)
}

public enum ActRefPlan {
    /// Decide whether a `@ref` is safe to act on. `livePID` is the resolved app's
    /// current PID; `snapshot.pid` (when present) must match — a relaunch (same
    /// name, new process) invalidates every stored AX identity, so we refuse rather
    /// than act on a guess. App-name match is required too (the snapshot is per-app).
    /// A nil snapshot PID (older snapshot) skips the relaunch guard but keeps the
    /// app-name + ref checks.
    public static func decide(snapshot: SeeSnapshot?, ref: String,
                              appName: String, livePID: Int32) -> ActRefDecision {
        guard let snap = snapshot else { return .noSnapshot }
        if snap.app != appName {
            return .appMismatch(snapshotApp: snap.app, requested: appName)
        }
        if let pid = snap.pid, pid != livePID { return .relaunched }
        guard let record = snap.record(for: ref) else { return .unknownRef }
        return .proceed(record)
    }
}

// MARK: - Pure: hand selection by source

/// Which hand `act` will use — derived from the row's source + whether the caller
/// asked to TYPE (`--type "<text>"`) vs the default click/press.
public enum ActHand: String, Sendable, Equatable {
    case axPress = "ax-press"
    case axType = "ax-type"
    case cdpClick = "cdp-click"
    case cdpType = "cdp-type"
    case hidClick = "hid-click"
}

public enum ActHandChoice: Sendable, Equatable {
    case hand(ActHand)
    /// The request can't be honoured (e.g. type into an OCR-only row) → REFUSE.
    case refuse(reason: String)
}

public enum ActHandPicker {
    /// Auto-pick the hand for a record. `typing` = the caller passed `--type`.
    /// An OCR-only row can be CLICKED (HID) but not TYPED into (no field handle),
    /// so ocr+typing REFUSES rather than blind-type. A cdp row that somehow carries
    /// no `@eN` ref also can't be CDP-actuated → refuse (re-see), never a guess.
    public static func pick(_ record: SeeRecord, typing: Bool) -> ActHandChoice {
        switch record.source {
        case .ax:
            return .hand(typing ? .axType : .axPress)
        case .cdp:
            guard record.cdpRef != nil else {
                return .refuse(reason: "cdp row carries no @eN handle")
            }
            return .hand(typing ? .cdpType : .cdpClick)
        case .ocr:
            return typing ? .refuse(reason: "ocr-only") : .hand(.hidClick)
        }
    }
}

// MARK: - Unified result

/// One `act "@ref"` outcome — the tier that acted + the honest verdict, surfaced to
/// the CLI/MCP. `verified` is true ONLY when the underlying per-tier witness proved
/// an effect; otherwise the evidence states plainly that the action was dispatched
/// but unproven (never a success claim).
public struct RefActResult: Sendable {
    public let ref: String
    public let app: String
    public let source: SeeSource
    /// The hand that acted ("ax-press" / "cdp-click" / "hid-click" / …).
    public let tier: String
    /// What the row was, for the report.
    public let role: String
    public let name: String
    public let verified: Bool
    /// The verified evidence, or the honest dispatched-unverified reason.
    public let evidence: String

    public init(ref: String, app: String, source: SeeSource, tier: String,
                role: String, name: String, verified: Bool, evidence: String) {
        self.ref = ref
        self.app = app
        self.source = source
        self.tier = tier
        self.role = role
        self.name = name
        self.verified = verified
        self.evidence = evidence
    }
}

// MARK: - Impure: the actuator

extension GhostHands {
    /// `act "@ref" <app> [--type "<text>"] [--submit]` — resolve the ref from the
    /// last `see`, validate staleness, auto-pick the hand, and delegate to the
    /// existing per-tier verb (which verifies or honestly under-claims).
    @MainActor
    public static func actRef(ref: String, appSpec: String,
                              typeText: String? = nil, submit: Bool = false)
        async throws -> RefActResult {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)
        let snapshot = SeeStore.load()

        // 1. Staleness gate (pure decision).
        let record: SeeRecord
        switch ActRefPlan.decide(snapshot: snapshot, ref: ref,
                                 appName: target.name, livePID: target.pid) {
        case .noSnapshot:
            throw GhostHandsError.seeRequired(app: target.name)
        case let .appMismatch(snapApp, requested):
            throw GhostHandsError.refStale(
                ref: ref, reason: "last see was for \(snapApp), not \(requested)")
        case .relaunched:
            throw GhostHandsError.refStale(
                ref: ref, reason: "\(target.name) was relaunched since the see")
        case .unknownRef:
            throw GhostHandsError.refStale(ref: ref, reason: "no such ref in the last see")
        case let .proceed(rec):
            record = rec
        }

        // 2. Hand selection (pure), then delegate to the existing per-tier verb.
        let typing = typeText != nil
        switch ActHandPicker.pick(record, typing: typing) {
        case let .refuse(reason):
            if reason == "ocr-only" { throw GhostHandsError.refNotTypeable(ref: ref) }
            throw GhostHandsError.refStale(ref: ref, reason: reason)

        case .hand(.axPress):
            // Re-find by NAME on a FRESH tree (never trust the stored rect); the
            // click path refuses on not-found (stale) or ambiguity.
            let o = try click(name: record.name, appSpec: target.name)
            return result(record, ref: ref, app: target.name, tier: ActHand.axPress,
                          verified: o.verified,
                          evidence: o.verified ? (o.evidence ?? "changed")
                              : "AXPress accepted; effect unverified")

        case .hand(.axType):
            let o = try type(text: typeText!, field: record.name, appSpec: target.name)
            return result(record, ref: ref, app: target.name, tier: ActHand.axType,
                          verified: o.verified,
                          evidence: o.verified
                              ? "value → \((o.valueAfter ?? typeText!).debugDescription)"
                              : "set accepted; read-back did not confirm "
                                  + "\(typeText!.debugDescription) — effect unverified")

        case .hand(.cdpClick):
            let o = try await webClick(
                selector: record.cdpRef!, browser: target.name, lens: .auto,
                debugPort: try cdpPort(snapshot, ref: ref), pick: cdpPick(snapshot))
            return result(record, ref: ref, app: target.name, tier: ActHand.cdpClick,
                          verified: o.verified, evidence: verdictText(o.verdict))

        case .hand(.cdpType):
            let o = try await webType(
                selector: record.cdpRef!, text: typeText!, submit: submit,
                browser: target.name, lens: .auto,
                debugPort: try cdpPort(snapshot, ref: ref), pick: cdpPick(snapshot))
            return result(record, ref: ref, app: target.name, tier: ActHand.cdpType,
                          verified: o.verified, evidence: verdictText(o.verdict))

        case .hand(.hidClick):
            // Re-OCR + match the stored text + HID-click; ocrClick refuses
            // (`ocrTextNotFound`) when the text is gone (stale) and verifies by
            // pixel-diff.
            let o = try await ocrClick(text: record.name, appSpec: target.name)
            let pct = Int((o.changedFraction * 100).rounded())
            return result(record, ref: ref, app: target.name, tier: ActHand.hidClick,
                          verified: o.verified,
                          evidence: o.verified ? "pixel-diff \(pct)% of the region changed"
                              : "HID click dispatched; no observable pixel change — unverified")
        }
    }

    /// Build the unified result from a record + the per-tier verdict.
    private static func result(_ record: SeeRecord, ref: String, app: String,
                               tier: ActHand, verified: Bool, evidence: String)
        -> RefActResult {
        RefActResult(ref: ref, app: app, source: record.source, tier: tier.rawValue,
                     role: record.role, name: record.name, verified: verified,
                     evidence: evidence)
    }

    /// The CDP renderer to reattach to: the EXACT target id `see` pinned, so a
    /// `@ref` stamped on a non-default page (multi-window Electron / `see --target N`)
    /// is found on its own renderer rather than falsely refused as stale on page 0.
    /// Nil (older snapshot / single-page) → the historical first-page default.
    private static func cdpPick(_ snapshot: SeeSnapshot?) -> CDPTargetPick.Selector? {
        snapshot?.cdpTargetId.map { .id($0) }
    }

    /// The CDP port a cdp `@ref` must reattach on. A cdp record implies `see` read
    /// over CDP, so a port WAS recorded; if it somehow isn't (a hand-edited / older
    /// snapshot), REFUSE rather than guess 9222 — which could attach to an unrelated
    /// debug target (CodeRabbit).
    private static func cdpPort(_ snapshot: SeeSnapshot?, ref: String) throws -> Int {
        guard let port = snapshot?.port else {
            throw GhostHandsError.refStale(
                ref: ref, reason: "the see recorded no CDP port for this ref")
        }
        return port
    }

    /// Flatten a `WebActuate.Verdict` to (verified flag already read) its text.
    private static func verdictText(_ v: WebActuate.Verdict) -> String {
        switch v {
        case let .verified(evidence): return evidence
        case let .dispatchedUnverified(reason): return reason
        }
    }
}
