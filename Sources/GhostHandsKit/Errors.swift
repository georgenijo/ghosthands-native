import Foundation

/// Every failure mode of the act tier, each a clean one-liner — never a
/// traceback, never a silent success. These are the honesty boundary: if we
/// can't prove the action happened, we raise instead of reporting "done".
public enum GhostHandsError: Error, CustomStringConvertible, Sendable {
    /// Accessibility (AX) permission not granted to this process.
    case accessibilityNotTrusted
    /// No running application matched the given spec (pid / bundle id / name).
    case appNotFound(String)
    /// The spec matched more than one distinct app — refuse rather than guess.
    case appAmbiguous(spec: String, candidates: [String])
    /// The named element is not on screen — the honest refuse-on-no-op.
    case elementNotFound(name: String, app: String)
    /// The name matched more than one distinct on-screen control — refuse
    /// rather than press an arbitrary (possibly destructive) one.
    case ambiguousMatch(name: String, candidates: [String])
    /// The element was found but rejected the AX action (no-op at the AX layer).
    case actionRejected(name: String, action: String)
    /// A `type` was requested into a secure (password) text field. Its value
    /// cannot be read back, so a successful set can NEVER be verified — we refuse
    /// to claim an unverifiable success rather than silently set a password.
    case secureFieldUnverifiable(name: String)
    /// A `set-value` requested a value the control's type cannot honestly hold —
    /// e.g. "banana" for a slider, or an arbitrary string for a checkbox. We
    /// refuse rather than coerce to a wrong value.
    case valueUncoercible(value: String, role: String)
    /// An `act` requested an action the control does not advertise. We refuse
    /// early (rather than throw-and-guess) and report what IS supported.
    case wrongActionForControl(name: String, action: String, supported: [String])
    /// An `act` was given a friendly action name that is not in the known set —
    /// a usage-class error (exit 2), distinct from a control that rejects a known
    /// action.
    case unknownAction(String)
    /// A `set-value`/`type` dispatched (AX accepted) but the read-back showed NO
    /// observable change — the no-op trap. We REFUSE to claim success on a no-op.
    /// (The CLI may instead choose to report this as dispatched-unverified; this
    /// case exists for verbs that treat an unverified set as a hard refuse.)
    case valueUnchanged(name: String, value: String?)
    /// Screen Recording permission not granted — `shot` REFUSES rather than
    /// write the black image the OS hands back without the grant.
    case screenRecordingNotTrusted
    /// The app has no on-screen windows to capture (nothing to shoot).
    case noWindows(app: String)
    /// Capture was attempted (with permission) but produced no usable pixels —
    /// e.g. an off-screen/occluded window. Honest REFUSE, no blank PNG written.
    case captureFailed(reason: String)
    /// A pixel poke (`click-at` / `drag`) targeted a global point that is NOT
    /// inside the resolved app's frontmost window. We REFUSE rather than poke a
    /// random screen location — a blind pixel mode has no element to vouch for
    /// the point, so an out-of-bounds coordinate is almost certainly a mistake.
    case pointOutsideWindow(point: String, window: String, app: String)
    /// A pixel coordinate argument did not parse as a number.
    case badCoordinate(String)
    /// A `key` was given a base key name that is not in the known set — a
    /// usage-class error (exit 2), mirroring `.unknownAction`. We refuse early
    /// (rather than post a guessed key) and report what IS supported.
    case unknownKey(String)
    /// A `key` spec did not parse — empty, no base key, or an unknown modifier
    /// token in a chord. We REFUSE rather than drop a modifier or post nothing.
    case badKeySpec(String)
    /// `web tabs` could not read a tab strip — the browser exposes no AXTabGroup
    /// (or it lists no tabs) on the AX tree. We REFUSE rather than guess a tab
    /// list (the web tier's honesty boundary for tab enumeration).
    case tabsNotExposed(app: String)
    /// `install` was pointed at a DMG path that does not exist on disk.
    case dmgNotFound(String)
    /// `hdiutil attach` failed (nonzero exit, or the plist exposed no mount-point).
    /// REFUSE — nothing was copied.
    case mountFailed(reason: String)
    /// The mounted DMG contains zero top-level `.app` bundles — nothing to install.
    case noAppInDMG(mount: String)
    /// The mounted DMG contains more than one top-level `.app` — REFUSE rather than
    /// guess which application the user meant.
    case ambiguousAppInDMG(candidates: [String])
    /// The destination already holds `<App>.app` and `--force` was not given. The
    /// don't-clobber gate: REFUSE rather than overwrite the user's installed app.
    case destinationExists(path: String)
    /// `cp -R` returned nonzero — the copy did not complete.
    case copyFailed(reason: String)
    /// A `window` verb had more than one candidate window and no `--window`
    /// selector (or a selector that matched >1) — REFUSE rather than mutate an
    /// arbitrary window. Mirrors `.ambiguousMatch` for controls.
    case windowAmbiguous(app: String, candidates: [String])
    /// A `window --window <id|title>` selector matched NO window — REFUSE rather
    /// than fall back to an arbitrary window.
    case windowNotFound(app: String, selector: String)
    /// The AX window-list ENUMERATION itself failed (`windows()` returned nil — the
    /// AXWindows attribute could not be read), as distinct from an app that has
    /// zero windows. We REFUSE rather than report "no windows" and mislead the
    /// caller into thinking the app is windowless when AX actually errored.
    case windowListUnreadable(app: String)

    public var description: String {
        switch self {
        case .accessibilityNotTrusted:
            return "accessibility permission not granted — enable 'ghosthands' "
                + "(or the launching terminal) in System Settings ▸ Privacy & "
                + "Security ▸ Accessibility"
        case let .appNotFound(spec):
            return "no running app matching \(spec.debugDescription)"
        case let .appAmbiguous(spec, candidates):
            return "\(spec.debugDescription) matches \(candidates.count) apps "
                + "(\(candidates.joined(separator: ", "))) — be more specific"
        case let .elementNotFound(name, app):
            return "no element named \(name.debugDescription) on screen in \(app)"
        case let .ambiguousMatch(name, candidates):
            return "\(name.debugDescription) is ambiguous — \(candidates.count) "
                + "controls match (\(candidates.joined(separator: ", "))) — "
                + "use a more specific name"
        case let .actionRejected(name, action):
            return "\(action) rejected by \(name.debugDescription) — element "
                + "found but did not accept the action"
        case let .secureFieldUnverifiable(name):
            return "\(name.debugDescription) is a secure text field — its value "
                + "cannot be read back, so a successful set cannot be verified "
                + "(refusing to claim an unverifiable success)"
        case let .valueUncoercible(value, role):
            return "\(value.debugDescription) cannot be set on a \(role) — the "
                + "value is not valid for this control's type"
        case let .wrongActionForControl(name, action, supported):
            let list = supported.isEmpty ? "none" : supported.joined(separator: ", ")
            return "\(name.debugDescription) does not support \(action) "
                + "(supported: \(list)) — wrong action for this control"
        case let .unknownAction(action):
            return "unknown action \(action.debugDescription) — use one of "
                + "\(ActionName.known)"
        case let .valueUnchanged(name, value):
            let was = value.map { $0.debugDescription } ?? "empty"
            return "set of \(name.debugDescription) was accepted by AX but the "
                + "value did not change (still \(was)) — no observable effect"
        case .screenRecordingNotTrusted:
            return "Screen Recording not granted — enable 'ghosthands' (or the "
                + "launching terminal) in System Settings ▸ Privacy & Security ▸ "
                + "Screen Recording. The AX tree still works: try ghosthands snapshot"
        case let .noWindows(app):
            return "no on-screen windows to capture in \(app)"
        case let .captureFailed(reason):
            return "screenshot capture failed: \(reason)"
        case let .pointOutsideWindow(point, window, app):
            return "point \(point) is outside \(app)'s window \(window) — refusing "
                + "to poke a location that is not on the target window"
        case let .badCoordinate(raw):
            return "\(raw.debugDescription) is not a valid coordinate (expected a number)"
        case let .unknownKey(key):
            return "unknown key \(key.debugDescription) — use one of "
                + "\(KeyName.known) (chords via '+', e.g. cmd+shift+t)"
        case let .badKeySpec(spec):
            return "\(spec.debugDescription) is not a valid key spec — expected "
                + "<key> or <mod>+<key> (mods: cmd|shift|alt|ctrl); no base key or "
                + "an unknown modifier token"
        case let .tabsNotExposed(app):
            return "no tab strip exposed on the AX tree in \(app) — the browser "
                + "does not advertise an AXTabGroup of tabs (refusing to guess a "
                + "tab list)"
        case let .dmgNotFound(path):
            return "no DMG at \(path.debugDescription)"
        case let .mountFailed(reason):
            return "could not mount the DMG: \(reason)"
        case let .noAppInDMG(mount):
            return "no .app found in the mounted DMG (\(mount)) — nothing to install"
        case let .ambiguousAppInDMG(candidates):
            return "\(candidates.count) apps in the DMG "
                + "(\(candidates.joined(separator: ", "))) — refusing to guess "
                + "which one to install"
        case let .destinationExists(path):
            return "\(path.debugDescription) already exists — refusing to "
                + "overwrite an installed app (pass --force to replace it)"
        case let .copyFailed(reason):
            return "copy failed: \(reason)"
        case let .windowAmbiguous(app, candidates):
            return "\(app) has \(candidates.count) windows "
                + "(\(candidates.joined(separator: ", "))) — pass --window <id|title> "
                + "to pick one (refusing to mutate an arbitrary window)"
        case let .windowNotFound(app, selector):
            return "no window matching \(selector) in \(app) — "
                + "refusing to fall back to an arbitrary window"
        case let .windowListUnreadable(app):
            return "could not read the window list of \(app) — the AXWindows "
                + "attribute returned an error (this is an AX read failure, NOT a "
                + "windowless app; refusing to report 'no windows')"
        }
    }
}
