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
    /// A `--nth <i>` locator pinned an index outside the matching-control range
    /// (after any --role/--text filter). REFUSE — the disambiguators never make
    /// the tool guess; an out-of-range index is a wrong-target signal, not a clamp.
    case locatorIndexOutOfRange(name: String, requested: Int, count: Int)
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
    /// `navigate` was given a URL that, after trimming + https-prefixing, has no
    /// parseable host — the refuse-on-malformed gate. We REFUSE rather than hand a
    /// garbage string to `open`.
    case malformedURL(String)
    /// `navigate` could not even LAUNCH `/usr/bin/open` (a Process.run() failure).
    /// REFUSE — the load was never issued. (A nonzero `open` EXIT is NOT this — it
    /// is at most a hint and never a refuse; honesty comes from the read-back.)
    case openFailed(reason: String)
    /// A FORCED `web read --cdp` / `web tabs --cdp` found no DevTools port open on
    /// loopback. We REFUSE rather than silently enable a debug surface; the `auto`
    /// lens never throws this (it falls back to the AX path unchanged). This is the
    /// ONLY place the no-port refuse is raised.
    case cdpPortClosed(app: String, port: Int)
    /// A generic CDP transport / decode / deadline / non-loopback failure: a
    /// malformed `/json/list` body, a never-arriving reply that hit its deadline,
    /// a CDP error reply, or a refused non-loopback `webSocketDebuggerUrl`.
    case cdpTransport(reason: String)
    /// A consent-gated `--relaunch` could not spawn the isolated automation
    /// instance — the throwaway profile dir could not be created, or the browser
    /// binary failed to launch. REFUSE — nothing debuggable came up.
    case relaunchFailed(reason: String)
    /// The relaunched browser's `DevToolsActivePort` sidecar could not be read — it
    /// never appeared within the deadline, or its content was malformed. We REFUSE
    /// rather than guess a port (the security rule: never connect to a fabricated
    /// debug port).
    case devToolsPortUnreadable(reason: String)
    /// A `web click` / `web fill` CSS selector matched NO element in the page DOM.
    /// We REFUSE rather than actuate an arbitrary or fabricated target — a missing
    /// selector is a wrong-target signal, never a silent no-op.
    case selectorNotFound(selector: String, app: String)
    /// A `web click` target is OCCLUDED — another element overlays its center
    /// point, so `document.elementFromPoint` returns the cover, not the target. We
    /// REFUSE rather than dispatch a click that would land on the covering element
    /// (the agent-browser-mined refuse: never click through an overlay).
    case elementCovered(selector: String, coveredBy: String)
    /// A `web click` / `web fill` was forced onto the `--ax` lens, but a CSS
    /// selector has no AX equivalent — these selector verbs REQUIRE CDP. A
    /// usage-class refuse, surfaced before any work.
    case selectorNeedsCDP
    /// A `web click`/`web fill`/`web html` was given an `@eN` ref whose stamped
    /// `data-gh-ref` element is no longer in the DOM — the page navigated or
    /// re-rendered since the `web read` that minted the ref. We REFUSE rather than
    /// act on a moved element (the ref-addressing honesty boundary: a stale handle
    /// never silently retargets), telling the caller to re-read for fresh refs.
    case staleRef(ref: String)
    /// `web select` resolved its target, but the element is NOT a `<select>` — a
    /// dropdown selection has no meaning on a text input or a div. We REFUSE rather
    /// than guess (e.g. silently fall back to a fill), naming the actual role.
    case notASelect(selector: String, role: String)
    /// `menu` could not read the app's menu bar (`AXMenuBar` absent). A faceless /
    /// agent process with no menu bar, or an app that doesn't expose one — we
    /// REFUSE rather than pretend a menu path exists.
    case menuBarUnavailable(app: String)
    /// `menu` found no item matching a path segment at its level. We REFUSE and list
    /// the real items at that level so the caller can pick one — never guesses.
    case menuItemNotFound(segment: String, app: String, available: [String])
    /// `menu` was given more path segments after an item that has no submenu — the
    /// path walked past a leaf. We REFUSE rather than press a leaf as if it opened.
    case notASubmenu(segment: String, app: String)
    /// `web select` found the `<select>`, but NO option's value or visible text
    /// matched the request. We REFUSE rather than leave the prior selection and
    /// claim a no-op succeeded — the available options are listed so the caller can
    /// pick a real one.
    case optionNotFound(value: String, selector: String, options: [String])
    /// `web open` was called while a LIVE managed session already exists — we
    /// REFUSE rather than spawn a second throwaway and orphan the first. The caller
    /// should `web close` it (or pass an explicit `--debug-port` to drive it).
    case sessionAlreadyOpen(port: Int, pid: Int32)
    /// `web close` was called with no managed session recorded — nothing to tear
    /// down (the honest refuse: we don't fabricate a teardown that did nothing).
    case noSession
    /// A `right-click` fell to the PIXEL route (the element advertises no
    /// AXShowMenu) but the element exposes NO readable AX frame to aim at. We
    /// REFUSE rather than right-click a guessed point — a blind poke has no
    /// element geometry to vouch for it.
    case noElementFrame(name: String)
    /// `scroll` found no scrollable area to act on — no `AXScrollArea` matched the
    /// `--in <name>` selector, or the app's frontmost window exposes none. We
    /// REFUSE rather than post a wheel into the void (the scroll tier's honesty
    /// boundary: nothing to move, nothing to witness).
    case noScrollArea(app: String, named: String?)
    /// `extract` found no tabular container to read — no `AXTable`/`AXOutline`/
    /// `AXList` matched the `--in <name>` selector, or the app's frontmost window
    /// exposes none. We REFUSE rather than emit a fabricated row (the extract
    /// tier's honesty boundary: a MISSING table is a refuse, distinct from a
    /// present-but-empty table, which is honest empty output).
    case noTabularData(app: String, named: String?)
    /// `dialog` found no modal sheet / alert / dialog in the app to detect or
    /// respond to. We REFUSE rather than fabricate a popup — there is nothing to
    /// read and nothing to dismiss (the dialog tier's honesty boundary).
    case noDialog(app: String)
    /// `wait` polled to its deadline without ever OBSERVING the condition — the
    /// element never appeared (or, with `--gone`, never disappeared). A timeout is
    /// a REFUSE (nonzero exit), never a fabricated success: we only report met when
    /// the condition is observed met (the wait tier's honesty boundary).
    case waitTimeout(name: String, app: String, wantedGone: Bool, seconds: TimeInterval)

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
                + "use a more specific name (or --role/--text to narrow, --nth to pick)"
        case let .locatorIndexOutOfRange(name, requested, count):
            return "--nth \(requested) is out of range for \(name.debugDescription) — "
                + "only \(count) control(s) match (valid indices 0…\(max(count - 1, 0))) "
                + "— refusing to guess a control"
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
        case let .malformedURL(raw):
            return "\(raw.debugDescription) is not a valid URL (no host after "
                + "normalizing) — refusing to navigate to a malformed address"
        case let .openFailed(reason):
            return "could not launch the browser via open: \(reason)"
        case let .cdpPortClosed(app, port):
            return "no DevTools port on 127.0.0.1:\(port) for \(app) — relaunch "
                + "with --remote-debugging-port=\(port), or use `web read` (AX); "
                + "refusing to enable a debug surface silently"
        case let .cdpTransport(reason):
            return "CDP transport error: \(reason)"
        case let .relaunchFailed(reason):
            return "could not relaunch an isolated browser for automation: \(reason)"
        case let .devToolsPortUnreadable(reason):
            return "could not read the relaunched browser's debug port: \(reason) "
                + "— refusing to guess a port"
        case let .selectorNotFound(selector, app):
            return "no element matching selector \(selector.debugDescription) in "
                + "\(app)'s page — refusing to actuate a target that is not in the DOM"
        case let .elementCovered(selector, coveredBy):
            return "\(selector.debugDescription) is covered by a <\(coveredBy)> at its "
                + "center point — refusing to click through an overlay (the click "
                + "would land on the covering element, not the target)"
        case .selectorNeedsCDP:
            return "a CSS selector has no AX equivalent — `web click`/`web fill` "
                + "REQUIRE CDP; drop --ax (default is --cdp, port 9222)"
        case let .staleRef(ref):
            return "\(ref) is a stale ref — the page navigated or re-rendered since "
                + "the last `web read` (the stamped element is gone); re-read to get "
                + "fresh refs, then address by the new @eN"
        case let .notASelect(selector, role):
            return "\(selector.debugDescription) is a <\(role)>, not a <select> — "
                + "`web select` only drives dropdowns; use `web fill`/`web click` for "
                + "other controls"
        case let .menuBarUnavailable(app):
            return "\(app) exposes no menu bar (AXMenuBar absent) — nothing to drive"
        case let .menuItemNotFound(segment, app, available):
            let list = available.isEmpty ? "(none)" : available.map { $0.debugDescription }.joined(separator: ", ")
            let seg = segment.isEmpty ? "(empty path)" : segment.debugDescription
            return "no menu item matching \(seg) in \(app) at this level — "
                + "refusing to guess; items here: \(list)"
        case let .notASubmenu(segment, app):
            return "menu item \(segment.debugDescription) in \(app) has no submenu — "
                + "the menu path continues past a leaf item"
        case let .optionNotFound(value, selector, options):
            let list = options.isEmpty ? "(none)" : options.map { $0.debugDescription }.joined(separator: ", ")
            return "no option matching \(value.debugDescription) in "
                + "\(selector.debugDescription) — refusing to leave the selection "
                + "unchanged and claim success; available options: \(list)"
        case let .sessionAlreadyOpen(port, pid):
            return "a managed web session is already open (pid \(pid), port \(port)) "
                + "— `web close` it first, or drive it with --debug-port \(port)"
        case .noSession:
            return "no managed web session is open — nothing to close (open one with "
                + "`web open <url>`)"
        case let .noElementFrame(name):
            return "\(name.debugDescription) advertises no AXShowMenu and exposes "
                + "no readable frame — refusing to right-click a guessed point "
                + "(no element geometry to aim at)"
        case let .noScrollArea(app, named):
            if let named {
                return "no scroll area named \(named.debugDescription) in \(app) — "
                    + "refusing to scroll (nothing scrollable matched --in)"
            }
            return "no scroll area found in \(app)'s frontmost window — refusing to "
                + "scroll (the window exposes no AXScrollArea to move)"
        case let .noTabularData(app, named):
            if let named {
                return "no table/outline/list named \(named.debugDescription) in "
                    + "\(app) — refusing to extract (nothing tabular matched --in)"
            }
            return "no table/outline/list found in \(app)'s frontmost window — "
                + "refusing to extract (the window exposes no AXTable/AXOutline/AXList)"
        case let .noDialog(app):
            return "no modal sheet / alert / dialog found in \(app) — refusing to "
                + "fabricate a popup (nothing to detect or dismiss)"
        case let .waitTimeout(name, app, wantedGone, seconds):
            let cond = wantedGone ? "to disappear" : "to appear"
            return "timed out after \(String(format: "%g", seconds))s waiting for "
                + "\(name.debugDescription) \(cond) in \(app) — condition never "
                + "observed (refusing to report a met that did not happen)"
        }
    }
}
