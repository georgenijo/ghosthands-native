import CoreGraphics
import Foundation

/// The PURE shaping layer: every `*Outcome` / `*Result` / verdict → a `JSONResult`
/// envelope, with the SAME status the human one-liner reports. These are the
/// honesty-preserving mappers — each reads `verified` / `passed` / a verdict OFF
/// the already-decided outcome and never re-decides it, so a `--json` envelope
/// can NEVER claim `verified` where the human line says dispatched. Hermetically
/// testable: fabricate an outcome, shape it, assert the envelope.
///
/// Every mapper here is a static factory on `JSONResult`. The CLI wiring is then
/// mechanical: one `JSONResult.from<verb>(outcome).emit()` per runner.
extension JSONResult {

    // MARK: act-tier (verified | dispatched)

    public static func fromClick(_ o: ClickOutcome, name: String) -> JSONResult {
        var fields: [(String, GHJSONValue)] = [("role", .string(o.role))]
        fields += GHJSONValue.optString("before", o.valueBefore)
        fields += GHJSONValue.optString("after", o.valueAfter)
        fields += GHJSONValue.optString("witness", o.witnessName)
        return JSONResult(
            verb: "click",
            status: o.verified ? .verified : .dispatched,
            app: o.app, target: name,
            evidence: o.verified ? (o.evidence ?? "changed") : nil,
            fields: fields)
    }

    /// `verb` is the CLI verb ("type" | "set-value") — passed explicitly so the
    /// envelope's `verb` always matches the command the user ran (both call sites
    /// produce a `ValueOutcome`). `o.verb` is the human phrasing ("typed"/"set"),
    /// carried in `fields` rather than reused as the verb.
    public static func fromValue(_ o: ValueOutcome, verb: String) -> JSONResult {
        var fields: [(String, GHJSONValue)] = [("role", .string(o.role)),
                                             ("intended", .string(o.intended)),
                                             ("exact", .bool(o.exact)),
                                             ("phrasing", .string(o.verb))]
        fields += GHJSONValue.optString("before", o.valueBefore)
        fields += GHJSONValue.optString("after", o.valueAfter)
        return JSONResult(
            verb: verb,
            status: o.verified ? .verified : .dispatched,
            app: o.app, target: o.name,
            evidence: o.verified ? (o.evidence ?? "changed") : nil,
            value: o.valueAfter,
            fields: fields)
    }

    public static func fromAct(_ o: ActOutcome, verb: String) -> JSONResult {
        var fields: [(String, GHJSONValue)] = [("role", .string(o.role)),
                                             ("action", .string(o.action))]
        fields += GHJSONValue.optString("before", o.valueBefore)
        fields += GHJSONValue.optString("after", o.valueAfter)
        fields += GHJSONValue.optString("witness", o.witnessName)
        return JSONResult(
            verb: verb,
            status: o.verified ? .verified : .dispatched,
            app: o.app, target: o.name,
            evidence: o.verified ? (o.evidence ?? "changed") : nil,
            fields: fields)
    }

    public static func fromFocus(_ o: FocusOutcome) -> JSONResult {
        var fields: [(String, GHJSONValue)] = [("role", .string(o.role))]
        fields += GHJSONValue.optBool("focusedAfter", o.focusedAfter)
        return JSONResult(
            verb: "focus",
            status: o.verified ? .verified : .dispatched,
            app: o.app, target: o.name,
            evidence: o.verified ? (o.evidence ?? "AXFocused → true") : nil,
            fields: fields)
    }

    public static func fromRightClick(_ o: RightClickOutcome) -> JSONResult {
        let route: String
        switch o.route {
        case .axShowMenu: route = "axShowMenu"
        case .pixel: route = "pixel"
        }
        let fields: [(String, GHJSONValue)] = [("role", .string(o.role)),
                                             ("route", .string(route)),
                                             ("mode", .string(modeLabel(o.mode)))]
        return JSONResult(
            verb: "right-click",
            status: o.verified ? .verified : .dispatched,
            app: o.app, target: o.name,
            evidence: o.verified ? (o.evidence ?? "context menu appeared") : nil,
            fields: fields)
    }

    public static func fromDialogClick(_ o: DialogClickOutcome) -> JSONResult {
        return JSONResult(
            verb: "dialog",
            status: o.verified ? .verified : .dispatched,
            app: o.app, target: o.button,
            evidence: o.verified ? (o.evidence ?? "dialog dismissed") : nil,
            fields: [("role", .string(o.role))])
    }

    // MARK: navigate / web actuate

    public static func fromNavigate(_ o: GhostHands.NavigateOutcome) -> JSONResult {
        var fields: [(String, GHJSONValue)] = [("autoPicked", .bool(o.autoPicked))]
        fields += GHJSONValue.optString("landedURL", o.landedURL)
        fields += GHJSONValue.optString("landedTitle", o.landedTitle)
        return JSONResult(
            verb: "navigate",
            status: o.verified ? .verified : .dispatched,
            app: o.app, target: o.requestedURL,
            evidence: o.evidence,
            value: o.landedURL,
            fields: fields)
    }

    public static func fromWebActuate(_ r: GhostHands.WebActuateResult) -> JSONResult {
        let status: Status
        let evidence: String?
        switch r.verdict {
        case let .verified(ev): status = .verified; evidence = ev
        case let .dispatchedUnverified(reason): status = .dispatched; evidence = reason
        }
        return JSONResult(
            verb: r.verb == "filled" ? "web fill" : "web click",
            status: status,
            app: r.app, target: r.selector,
            // Both arms carry a human reason; surface it as evidence either way so
            // a consumer sees WHY a dispatch stayed unverified (it never upgrades
            // the status — status is decided by the verdict case above).
            evidence: evidence,
            fields: [("port", .int(r.port))])
    }

    // MARK: window mutate / raise

    public static func fromWindowMutate(_ o: WindowMutateOutcome) -> JSONResult {
        // CLAMPED is honest-dispatched (the OS constrained the set) — NOT verified.
        let status: Status = o.verified ? .verified : .dispatched
        var fields: [(String, GHJSONValue)] = [
            ("kind", .string(o.verb)),
            ("clamped", .bool(o.clamped)),
            ("before", .string(rectString(o.frameBefore))),
            ("after", .string(rectString(o.frameAfter))),
        ]
        fields += GHJSONValue.optString("windowTitle", o.windowTitle)
        fields += GHJSONValue.optInt("windowID", o.windowID.map { Int($0) })
        return JSONResult(
            verb: "window \(o.verb)",
            status: status,
            app: o.app, target: o.windowTitle,
            evidence: o.verified
                ? "\(rectString(o.frameBefore)) → \(rectString(o.frameAfter))" : nil,
            fields: fields)
    }

    public static func fromWindowRaise(_ o: WindowRaiseOutcome) -> JSONResult {
        // ALWAYS dispatched — z-order has no AX read-back (the human line too).
        var fields: [(String, GHJSONValue)] = []
        fields += GHJSONValue.optString("windowTitle", o.windowTitle)
        fields += GHJSONValue.optInt("windowID", o.windowID.map { Int($0) })
        return JSONResult(
            verb: "window raise",
            status: .dispatched,
            app: o.app, target: o.windowTitle,
            fields: fields)
    }

    // MARK: pixel / drag-element / scroll / key (verified | dispatched)

    public static func fromPixel(_ o: PixelOutcome) -> JSONResult {
        let fields: [(String, GHJSONValue)] = [
            ("x", .double(o.x)), ("y", .double(o.y)),
            ("mode", .string(modeLabel(o.mode))),
            ("observable", .bool(o.observable)),
            ("changedFraction", .double(o.changedFraction)),
        ]
        return JSONResult(
            verb: o.verb,
            status: o.verified ? .verified : .dispatched,
            app: o.app, target: "(\(Int(o.x)),\(Int(o.y)))",
            evidence: o.verified
                ? "pixel diff: \(String(format: "%.1f%%", o.changedFraction * 100)) changed"
                : nil,
            fields: fields)
    }

    public static func fromDragElement(_ o: DragElementOutcome) -> JSONResult {
        let fields: [(String, GHJSONValue)] = [
            ("from", .string(o.from)), ("to", .string(o.to)),
            ("mode", .string(modeLabel(o.mode))),
        ]
        return JSONResult(
            verb: "drag",
            status: o.verified ? .verified : .dispatched,
            app: o.app, target: "\(o.from) → \(o.to)",
            evidence: o.verified ? (o.evidence ?? "from-element moved") : nil,
            fields: fields)
    }

    public static func fromScroll(_ o: ScrollOutcome) -> JSONResult {
        var fields: [(String, GHJSONValue)] = [
            ("direction", .string(o.direction.rawValue)),
            ("container", .string(o.container)),
            ("amount", .double(o.amount)),
            ("via", .string(o.via)),
            ("mode", .string(modeLabel(o.mode))),
            ("observable", .bool(o.observable)),
        ]
        fields += GHJSONValue.optDouble("before", o.positionBefore)
        fields += GHJSONValue.optDouble("after", o.positionAfter)
        return JSONResult(
            verb: "scroll",
            status: o.verified ? .verified : .dispatched,
            app: o.app, target: o.direction.rawValue,
            evidence: o.verified
                ? "position \(positionStr(o.positionBefore)) → \(positionStr(o.positionAfter))"
                : nil,
            fields: fields)
    }

    public static func fromKey(_ o: KeyOutcome) -> JSONResult {
        // ALWAYS dispatched — a key has no built-in observable (the human line too).
        // KeyMode is a typealias for PixelMode, so `modeLabel` applies directly.
        return JSONResult(
            verb: "key",
            status: .dispatched,
            app: o.app, target: o.spec,
            fields: [("mode", .string(modeLabel(o.mode)))])
    }

    public static func fromClipboard(_ o: ClipboardOutcome) -> JSONResult {
        var fields: [(String, GHJSONValue)] = [("intendedChars", .int(o.intended.count))]
        fields += GHJSONValue.optInt("readbackChars", o.readback.map { $0.count })
        return JSONResult(
            verb: "clipboard",
            status: o.verified ? .verified : .dispatched,
            target: "write",
            evidence: o.verified ? "read-back matches (\(o.intended.count) chars)" : nil,
            value: o.readback,
            fields: fields)
    }

    public static func fromInstall(_ o: GhostHands.InstallOutcome) -> JSONResult {
        var fields: [(String, GHJSONValue)] = [("dest", .string(o.dest)),
                                             ("installedPath", .string(o.installedPath))]
        fields += GHJSONValue.optString("bundleIdentifier", o.bundleIdentifier)
        return JSONResult(
            verb: "install",
            status: o.verified ? .verified : .dispatched,
            target: o.appName,
            evidence: o.verified
                ? "CFBundleIdentifier \(o.bundleIdentifier ?? "?") present" : nil,
            value: o.bundleIdentifier,
            fields: fields)
    }

    // MARK: read verbs (ok) — data lives in fields

    public static func fromSnapshot(_ r: GhostHands.SnapshotResult) -> JSONResult {
        JSONResult(verb: "snapshot", status: .ok, app: r.app,
                   fields: [("count", .int(r.count)),
                            ("tree", snapshotForest(r.forest))])
    }

    public static func fromFind(_ o: GhostHands.FindOutcome) -> JSONResult {
        let hits = GHJSONValue.array(o.hits.map { facts in
            GHJSONValue.object(factsFields(facts))
        })
        return JSONResult(
            // A find HIT is an "ok" read; the MISS path never reaches here (the CLI
            // routes a no-hit find through the refuse path — exit 1 — exactly as
            // the human path does). `found` is always true in this envelope.
            verb: "find", status: .ok,
            app: o.app, target: o.query,
            fields: [("found", .bool(o.found)),
                     ("count", .int(o.hits.count)),
                     ("hits", hits)])
    }

    public static func fromWebRead(_ r: GhostHands.WebReadResult,
                                   served: GhostHands.ServedLens) -> JSONResult {
        let entries = GHJSONValue.array(r.entries.map { e in
            var fields: [(String, GHJSONValue)] = [("text", .string(WebDigest.line(e)))]
            // Surface the `@eN` ref explicitly so a machine consumer can address by
            // it without re-parsing the rendered line (omitted when there is none).
            if let ref = e.ref { fields.append(("ref", .string(ref))) }
            // Form-control state (#8) as discrete fields — each present only when set.
            if let st = e.state {
                if let checked = st.checked { fields.append(("checked", .bool(checked))) }
                if let selected = st.selected { fields.append(("selected", .string(selected))) }
                if let expanded = st.expanded { fields.append(("expanded", .bool(expanded))) }
            }
            return GHJSONValue.object(fields)
        })
        return JSONResult(
            verb: "web read", status: .ok, app: r.app,
            fields: [("hasWebArea", .bool(r.hasWebArea)),
                     ("count", .int(r.count)),
                     ("lens", .string(lensLabel(served))),
                     ("entries", entries)])
    }

    public static func fromWebOpen(_ info: WebSessionInfo) -> JSONResult {
        JSONResult(
            verb: "web open", status: .ok, app: info.browser, target: info.url,
            fields: [("port", .int(info.port)),
                     ("pid", .int(Int(info.pid))),
                     ("profileDir", .string(info.profileDir)),
                     ("binaryPath", .string(info.binaryPath))])
    }

    public static func fromWebClose(_ info: WebSessionInfo) -> JSONResult {
        JSONResult(
            verb: "web close", status: .ok, app: info.browser, target: info.url,
            fields: [("port", .int(info.port)),
                     ("pid", .int(Int(info.pid))),
                     ("profileDir", .string(info.profileDir))])
    }

    public static func fromWebTabs(_ r: GhostHands.WebTabsResult,
                                   served: GhostHands.ServedLens) -> JSONResult {
        let tabs = GHJSONValue.array(r.tabs.map { t in
            GHJSONValue.object([("title", .string(t.title)), ("selected", .bool(t.selected))])
        })
        return JSONResult(
            verb: "web tabs", status: .ok, app: r.app,
            fields: [("count", .int(r.tabs.count)),
                     ("lens", .string(lensLabel(served))),
                     ("tabs", tabs)])
    }

    public static func fromWebHtml(_ r: GhostHands.WebHtmlResult) -> JSONResult {
        let attrs = GHJSONValue.array(r.shaped.attributes.map {
            GHJSONValue.object([("name", .string($0.name)), ("value", .string($0.value))])
        })
        let computed = GHJSONValue.array(r.shaped.computed.map {
            GHJSONValue.object([("name", .string($0.name)), ("value", .string($0.value))])
        })
        return JSONResult(
            verb: "web html", status: .ok, app: r.app, target: r.selector,
            value: r.shaped.outerHTML,
            fields: [("port", .int(r.port)),
                     ("tag", .string(r.shaped.tag)),
                     ("truncated", .bool(r.shaped.truncated)),
                     ("attributes", attrs),
                     ("computed", computed)])
    }

    public static func fromWebEval(_ r: GhostHands.WebEvalResult) -> JSONResult {
        JSONResult(verb: "web eval", status: .ok, app: r.app,
                   value: r.value,
                   fields: [("port", .int(r.port))])
    }

    public static func fromExtract(_ r: GhostHands.ExtractResult) -> JSONResult {
        var fields: [(String, GHJSONValue)] = [
            ("container", .string(r.container)),
            ("rowCount", .int(r.rowCount)),
        ]
        if let header = r.model.header {
            fields.append(("header", .array(header.map { GHJSONValue.string($0) })))
        }
        fields.append(("rows", .array(r.model.rows.map { row in
            GHJSONValue.array(row.map { GHJSONValue.string($0) })
        })))
        return JSONResult(verb: "extract", status: .ok, app: r.app, fields: fields)
    }

    public static func fromWindows(_ r: WindowsResult) -> JSONResult {
        let wins = GHJSONValue.array(r.windows.map { w in
            var f: [(String, GHJSONValue)] = []
            f += GHJSONValue.optInt("id", w.id.map { Int($0) })
            f += GHJSONValue.optString("title", w.title)
            f.append(("frame", .string(rectString(w.frame))))
            f += GHJSONValue.optInt("display", w.screenIndex)
            f.append(("main", .bool(w.isMain)))
            f.append(("focused", .bool(w.isFocused)))
            f.append(("minimized", .bool(w.minimized)))
            return GHJSONValue.object(f)
        })
        return JSONResult(verb: "windows", status: .ok, app: r.app,
                          fields: [("count", .int(r.count)), ("windows", wins)])
    }

    public static func fromDialogReport(_ r: DialogReport) -> JSONResult {
        let buttons = GHJSONValue.array(r.buttons.map { b in
            GHJSONValue.object([("name", .string(b.name)), ("enabled", .bool(b.enabled))])
        })
        var fields: [(String, GHJSONValue)] = []
        fields += GHJSONValue.optString("title", r.title)
        fields.append(("messageLines", .array(r.messageLines.map { GHJSONValue.string($0) })))
        fields.append(("buttonCount", .int(r.buttons.count)))
        fields.append(("buttons", buttons))
        return JSONResult(verb: "dialog", status: .ok, app: r.app,
                          target: r.title, fields: fields)
    }

    public static func fromClipboardRead(_ value: String?) -> JSONResult {
        // A blank clipboard is a REAL state (exit 0) — `ok`, with a value that may
        // be empty/absent. NEVER fabricated.
        JSONResult(verb: "clipboard", status: .ok, target: "read",
                   value: (value?.isEmpty == false) ? value : nil,
                   fields: [("empty", .bool(value?.isEmpty != false))])
    }

    // MARK: shot (ok — wrote real pixels)

    public static func fromShot(_ o: GhostHands.ShotOutcome) -> JSONResult {
        JSONResult(verb: "shot", status: .ok, app: o.app,
                   value: o.path,
                   fields: [("path", .string(o.path)),
                            ("width", .int(o.width)),
                            ("height", .int(o.height))])
    }

    // MARK: wait (ok — condition observed met; a timeout is a refuse, never here)

    public static func fromWait(_ o: WaitOutcome) -> JSONResult {
        JSONResult(verb: "wait", status: .ok, app: o.app, target: o.name,
                   evidence: "\(o.wantedGone ? "gone" : "present") after "
                       + "\(String(format: "%.2f", o.elapsed))s",
                   fields: [("wantedGone", .bool(o.wantedGone)),
                            ("elapsed", .double(o.elapsed)),
                            ("polls", .int(o.polls))])
    }

    public static func fromWebWait(_ o: WaitOutcome, port: Int) -> JSONResult {
        JSONResult(verb: "web wait", status: .ok, app: o.app, target: o.name,
                   evidence: "\(o.wantedGone ? "met (gone)" : "met") after "
                       + "\(String(format: "%.2f", o.elapsed))s",
                   fields: [("wantedGone", .bool(o.wantedGone)),
                            ("elapsed", .double(o.elapsed)),
                            ("polls", .int(o.polls)),
                            ("port", .int(port))])
    }

    // MARK: assert (pass | fail)

    public static func fromAssert(_ o: GhostHands.AssertOutcome) -> JSONResult {
        var fields: [(String, GHJSONValue)] = [("count", .int(o.observed.count))]
        fields += GHJSONValue.optString("observedValue", o.observed.value)
        return JSONResult(
            verb: "assert",
            status: o.passed ? .pass : .fail,
            app: o.app, target: o.name,
            evidence: o.message,
            value: o.observed.value,
            fields: fields)
    }

    // MARK: refuse (refused — a thrown GhostHandsError; the SAME nonzero exit)

    /// The ONE refuse → envelope mapping. `app`/`target` are best-effort context
    /// the runner already has (often nil at the refuse point); `error` carries the
    /// SAME message the human stderr line prints, verbatim.
    public static func fromRefusal(verb: String, message: String,
                                   app: String? = nil, target: String? = nil)
        -> JSONResult {
        JSONResult(verb: verb, status: .refused, app: app, target: target,
                   error: message)
    }

    // MARK: replay (ok | refused — mirrors the exit policy)

    public static func fromReplay(_ run: GhostHands.ReplayRun) -> JSONResult { // ReplayRun is nested in GhostHands
        let s = run.summary
        // The exit policy is UNCHANGED: refused>0 ⇒ exit 1. The envelope status
        // mirrors it — `refused` when any step refused, else `ok`. We never claim
        // a clean run when a step refused.
        let status: Status = s.refused > 0 ? .refused : .ok
        return JSONResult(
            verb: "replay",
            status: status,
            fields: [("total", .int(run.total)),
                     ("executed", .int(s.executed)),
                     ("verified", .int(s.verified)),
                     ("dispatched", .int(s.dispatched)),
                     ("refused", .int(s.refused)),
                     ("stoppedEarly", .bool(s.stoppedEarly))],
            error: s.refused > 0 ? "\(s.refused) step(s) refused" : nil)
    }

    public static func fromRecord(_ run: GhostHands.RecordRun, flowPath: String) -> JSONResult {
        // A refused step is NOT appended and exits 1 (unchanged) — the envelope
        // mirrors it: `refused` when not appended, else `ok`.
        JSONResult(
            verb: "record",
            status: run.appended ? .ok : .refused,
            fields: [("flow", .string(flowPath)),
                     ("appended", .bool(run.appended)),
                     ("stepCount", .int(run.stepCount)),
                     ("line", .string(run.line))],
            error: run.appended ? nil : "step refused; not appended")
    }

    // MARK: - small shared label helpers (mirror the CLI's human labels)

    static func modeLabel(_ mode: PixelMode) -> String {
        mode == .visible ? "visible" : "invisible"
    }

    static func lensLabel(_ served: GhostHands.ServedLens) -> String {
        switch served {
        case let .cdp(port): return "cdp:\(port)"
        case .ax: return "ax"
        }
    }

    static func rectString(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }

    static func positionStr(_ p: Double?) -> String {
        p.map { String(format: "%.2f", $0) } ?? "?"
    }

    static func snapshotForest(_ forest: [SnapshotNode]) -> GHJSONValue {
        .array(forest.map { node in
            GHJSONValue.object([
                ("role", .string(node.facts.role ?? "AXUnknown")),
                ("name", .string(node.facts.title ?? node.facts.identifier
                    ?? node.facts.descriptionText ?? node.facts.value ?? "")),
                ("depth", .int(node.depth)),
                ("children", snapshotForest(node.children)),
            ])
        })
    }

    static func factsFields(_ f: ElementFacts) -> [(String, GHJSONValue)] {
        var out: [(String, GHJSONValue)] = [("role", .string(f.role ?? "AXUnknown"))]
        out += GHJSONValue.optString("title", f.title)
        out += GHJSONValue.optString("identifier", f.identifier)
        out += GHJSONValue.optString("value", f.value)
        out += GHJSONValue.optBool("enabled", f.enabled)
        return out
    }
}
