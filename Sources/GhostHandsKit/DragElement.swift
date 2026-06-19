import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation

/// The ELEMENT-TO-ELEMENT drag verb — `drag <from-name> <to-name> <app>`.
///
/// This is the named cousin of the pixel `drag <x1> <y1> <x2> <y2>` verb. Instead
/// of caller-supplied coordinates it RESOLVES two named AX elements (reusing
/// `Finder.resolve` / `Finder.candidateMatches`, already depth-bounded against the
/// cyclic-subtree SIGSEGV), aims at each element's CENTER, and posts a pixel drag
/// from the from-center to the to-center via the SAME posting helpers as the
/// pixel verbs (`postMouseSequence`: invisible `postToPid` by default, the
/// labelled `--visible` `cghidEventTap` cursor-move exception).
///
/// HONESTY (the hard part). A pixel drag has NO self-observable the way an
/// AXPress's value flip is — the WindowServer routes the synthetic mouse events
/// and returns no signal. So the verb is ALWAYS dispatched-unverified UNLESS we
/// can WITNESS a real world-change: we re-resolve the FROM-element after the drag
/// and compare its AX frame. If it MOVED (its center shifted past a small floor)
/// or it VANISHED (a drag that consumed/relocated it out of the matchable set),
/// that is an independently-observable effect → VERIFIED, quoting the before →
/// after geometry. If the from-element is still sitting where it was (or AX could
/// not read its frame back), the drag is honestly DISPATCHED-UNVERIFIED: we acted,
/// we have no proof. Default and safe is dispatched-unverified — VERIFIED is only
/// ever the observed move, never a fabricated success.
///
/// The witness only UNDER-claims: a drag that moved its target but whose target
/// re-renders at a stable AX frame (a list reorder that keeps the row index, a
/// drop into a container that does not move the source) reads as
/// dispatched-unverified — honest, never a false VERIFIED. It also cannot
/// over-claim from an unrelated reflow: we re-resolve the SAME named element and
/// compare ITS frame, not the window's.
public struct DragElementOutcome: Sendable, Equatable {
    public let app: String
    public let from: String
    public let to: String
    /// The from-element's center at dispatch time (global screen point).
    public let fromX: Double
    public let fromY: Double
    /// The to-element's center — the drop point (global screen point).
    public let toX: Double
    public let toY: Double
    /// The events were SENT (the mouse-down/drag/up posted). Never proof of
    /// effect on its own — see `verified`.
    public let dispatched: Bool
    /// The from-element was OBSERVED to move (or vanish) after the drag — the only
    /// honest VERIFIED a pixel drag has.
    public let verified: Bool
    /// Human evidence string for the VERIFIED case (e.g. "'icon.png' moved
    /// (120,80) → (300,80)"), nil when dispatched-unverified.
    public let evidence: String?
    /// The delivery mode used. `.visible` is surfaced so a moved / flickered
    /// cursor + possible focus steal is LABELLED, never silent.
    public let mode: PixelMode

    public init(app: String, from: String, to: String,
                fromX: Double, fromY: Double, toX: Double, toY: Double,
                dispatched: Bool, verified: Bool, evidence: String?,
                mode: PixelMode = .invisible) {
        self.app = app
        self.from = from
        self.to = to
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.dispatched = dispatched
        self.verified = verified
        self.evidence = evidence
        self.mode = mode
    }
}

/// The PURE geometry core — compute an element's CENTER from its AX frame, with
/// NO AX, NO CGEvent, NO live app. Fed fabricated `CGRect`s in tests; the live
/// verb feeds it the two resolved elements' real frames.
public enum DragGeometry {
    /// The CENTER of a frame (its mid-point), the point a drag aims at. A frame's
    /// center is the honest "where the element is" — the same midX/midY the
    /// pixel right-click uses.
    public static func center(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Both endpoints in one call: the from-center (press point) and the to-center
    /// (drop point). Returned in screen coordinates, ready to hand to the pixel
    /// posting helpers.
    public static func centers(from: CGRect, to: CGRect) -> (from: CGPoint, to: CGPoint) {
        (center(of: from), center(of: to))
    }
}

/// The PURE honesty core of the element-to-element drag — fabricated frames in,
/// honest verdict out. NO AX, NO capture, NO live app, so the
/// witnessed-move / vanished / no-move arms are hermetically unit-testable.
///
/// A pixel drag has no self-signal, so the ONLY honest witness is an OBSERVED
/// change to the FROM-element after the drag:
///   - the from-element re-resolved at a frame whose center MOVED past a small
///     floor (sub-pixel AX jitter must not fabricate a move)   → VERIFIED,
///   - the from-element VANISHED (no longer matchable — a drag that consumed or
///     relocated it out of the set)                            → VERIFIED,
///   - the from-element is still at (≈) the same center        → DISPATCHED,
///   - AX could not read the from-frame back at all (nil)      → DISPATCHED
///     (we acted, we could not observe — honest under-claim, never a guess).
public enum DragVerdict {
    /// The observed state of the FROM-element after the drag, distilled from AX so
    /// the verdict stays pure.
    public enum Readback: Sendable, Equatable {
        /// Re-resolved; carries its center NOW (compared to the before-center).
        case present(center: CGPoint)
        /// Re-resolved but AX exposed no readable frame on the read-back — we
        /// cannot measure a move, so this is NOT evidence (honest under-claim).
        case frameUnreadable
        /// No longer matchable on a fresh resolve — the drag relocated/consumed it
        /// out of the candidate set (an observed disappearance).
        case vanished
    }

    public enum Result: Sendable, Equatable {
        /// The from-element was observed to move or vanish — quote the evidence.
        case verified(evidence: String)
        /// The events were sent but the from-element did not observably change —
        /// honest under-claim, NEVER reported as success.
        case dispatched
    }

    /// The minimum center displacement (in points) that counts as a real MOVE.
    /// Below this we under-claim: AX frame reads carry sub-pixel jitter and a
    /// scroll-area repaint can nudge a reported origin by a point, so a tiny delta
    /// is not proof a drag relocated the element. A genuine drag-and-drop moves an
    /// icon/thumb far past this floor.
    public static let moveFloor = 4.0

    /// Decide the verdict from the from-element's before-center and its read-back.
    /// `dispatched` is whether the mouse events were actually posted (the live verb
    /// always posts before deciding; a non-dispatched input is defensively
    /// DISPATCHED — never VERIFIED).
    public static func decide(dispatched: Bool, fromBefore: CGPoint,
                              readback: Readback,
                              moveFloor: Double = moveFloor) -> Result {
        guard dispatched else { return .dispatched }
        switch readback {
        case .vanished:
            return .verified(evidence: "\(pointString(fromBefore)) → (gone) "
                + "— from-element no longer present after drag")
        case .frameUnreadable:
            return .dispatched
        case let .present(after):
            let dx = after.x - fromBefore.x
            let dy = after.y - fromBefore.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance >= moveFloor {
                return .verified(evidence: "from-element moved "
                    + "\(pointString(fromBefore)) → \(pointString(after))")
            }
            return .dispatched
        }
    }

    static func pointString(_ p: CGPoint) -> String {
        "(\(Int(p.x.rounded())),\(Int(p.y.rounded())))"
    }
}

extension GhostHands {
    /// `drag "<from-name>" "<to-name>" <app> [--visible]` — drag the FROM element
    /// onto the TO element, honestly, in honesty order:
    ///
    /// 1. RESOLVE both named elements (same refuse-on-not-found /
    ///    refuse-on-ambiguous rules as `click`, reusing `Finder.resolve`). Either a
    ///    miss or an ambiguity REFUSES (throws) — we never drag a guessed target.
    /// 2. REFUSE with `.noElementFrame` if EITHER element exposes no readable AX
    ///    frame — a blind drag has no element geometry to aim at, exactly as the
    ///    pixel right-click fallback refuses.
    /// 3. Compute each element's CENTER and post a pixel drag: mouse-down at the
    ///    from-center, interpolated drags to the to-center, mouse-up at the
    ///    to-center (REUSE `postMouseSequence`: invisible `postToPid` by default,
    ///    the labelled `--visible` HID cursor-move exception).
    /// 4. WITNESS: re-resolve the from-element off a FRESH app root and compare its
    ///    frame's center. A move past `DragVerdict.moveFloor`, or a vanish, →
    ///    VERIFIED; otherwise honestly DISPATCHED-UNVERIFIED.
    ///
    /// Nothing here hardcodes success: a not-found / ambiguous / frame-less target
    /// REFUSES; a sent drag with no observed move is honestly dispatched-unverified.
    @MainActor
    public static func dragElement(from fromName: String, to toName: String,
                                   appSpec: String, mode: PixelMode = .invisible,
                                   settle: TimeInterval = 0.15) throws -> DragElementOutcome {
        guard AXPermissionHelpers.hasAccessibilityPermissions() else {
            throw GhostHandsError.accessibilityNotTrusted
        }
        let target = try Target.resolve(appSpec)

        // Resolve BOTH endpoints. A drag onto an arbitrary control is a wrong-target
        // risk just like a click, so we reuse the widened openable gate (rows /
        // cells / files are prime drag sources & targets) and refuse on ambiguity.
        let fromFacts = try resolveDragEndpoint(named: fromName, under: target.element,
                                                app: target.name)
        let toFacts = try resolveDragEndpoint(named: toName, under: target.element,
                                              app: target.name)

        // REFUSE if either element exposes no readable frame to aim at — a blind
        // drag has no geometry to vouch for the point.
        guard let fromFrame = fromFacts.frame, fromFrame.width > 0, fromFrame.height > 0 else {
            throw GhostHandsError.noElementFrame(name: fromName)
        }
        guard let toFrame = toFacts.frame, toFrame.width > 0, toFrame.height > 0 else {
            throw GhostHandsError.noElementFrame(name: toName)
        }

        let (fromCenter, toCenter) = DragGeometry.centers(from: fromFrame, to: toFrame)

        // The stable (value-excluded) identity of the from-element so the witness
        // re-resolve reads the SAME logical control on a fresh tree — never the
        // stale handle we already aimed at.
        let fromIdentity = NameMatch.stableIdentityKey(fromFacts)

        // OPT-IN observability: flash the source then the destination so a human
        // SEES the drag's endpoints (no cursor move in invisible mode; the boxes are
        // overlays). Off by default = zero cost.
        if Highlight.isEnabled {
            Highlight.flash(fromFrame)
            Highlight.flash(toFrame)
        }

        // DISPATCH the drag: down at from-center, interpolated drags to to-center,
        // up at to-center. `.invisible` posts straight to the target pid
        // (cursor-less); `.visible` warps the real cursor and posts via the HID tap.
        postMouseSequence(start: fromCenter, end: toCenter, pid: target.pid,
                          isDrag: true, mode: mode)

        // Let the app settle, then WITNESS: re-resolve the from-element off a FRESH
        // application root and read its frame back.
        if settle > 0 { Thread.sleep(forTimeInterval: settle) }
        let readback = witnessFromElement(identity: fromIdentity, named: fromName,
                                          pid: target.pid)

        let verdict = DragVerdict.decide(dispatched: true, fromBefore: fromCenter,
                                         readback: readback)
        switch verdict {
        case let .verified(evidence):
            return DragElementOutcome(app: target.name, from: fromName, to: toName,
                                      fromX: fromCenter.x, fromY: fromCenter.y,
                                      toX: toCenter.x, toY: toCenter.y,
                                      dispatched: true, verified: true,
                                      evidence: evidence, mode: mode)
        case .dispatched:
            return DragElementOutcome(app: target.name, from: fromName, to: toName,
                                      fromX: fromCenter.x, fromY: fromCenter.y,
                                      toX: toCenter.x, toY: toCenter.y,
                                      dispatched: true, verified: false,
                                      evidence: nil, mode: mode)
        }
    }

    /// Resolve one drag endpoint over the widened openable gate (rows / cells /
    /// files / controls — the things a drag picks up or drops onto), refusing on
    /// not-found / ambiguous exactly like `click`.
    @MainActor
    private static func resolveDragEndpoint(named name: String, under root: Element,
                                            app: String) throws -> ElementFacts {
        switch Finder.resolve(named: name, under: root, accept: Finder.isOpenable) {
        case let .element(_, facts):
            return facts
        case let .ambiguous(candidates):
            throw GhostHandsError.ambiguousMatch(name: name, candidates: candidates)
        case let .indexOutOfRange(requested, count):
            // Unreachable today (drag passes no locator → .none can't tie-break),
            // but handled so the switch stays exhaustive and honest.
            throw GhostHandsError.locatorIndexOutOfRange(name: name, requested: requested, count: count)
        case .none:
            throw GhostHandsError.elementNotFound(name: name, app: app)
        }
    }

    /// Re-resolve the from-element off a FRESH application root and distil its AX
    /// frame into a `DragVerdict.Readback`. Reuses `Finder.candidateMatches` (the
    /// depth-bounded search) and matches on the value-excluded STABLE identity so a
    /// drag that changed the element's value does not read as a disappearance.
    @MainActor
    private static func witnessFromElement(identity key: String, named name: String,
                                           pid: pid_t) -> DragVerdict.Readback {
        let root = Element(AXUIElementCreateApplication(pid))
        for (_, facts) in Finder.candidateMatches(named: name, under: root,
                                                  accept: Finder.isOpenable)
        where NameMatch.stableIdentityKey(facts) == key {
            guard let frame = facts.frame, frame.width > 0, frame.height > 0 else {
                return .frameUnreadable
            }
            return .present(center: DragGeometry.center(of: frame))
        }
        return .vanished
    }
}
