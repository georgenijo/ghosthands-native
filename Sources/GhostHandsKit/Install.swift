import Foundation

/// The `install` verb — drop a `.app` out of a `.dmg` onto `/Applications`
/// (or any `--dest`) the honest way: `hdiutil attach` → find the single top-level
/// `.app` → (force-gate the clobber) → `cp -R` → ALWAYS detach → VERIFY the
/// installed bundle's `Info.plist`.
///
/// This is the FIRST subprocess in the codebase. The native side (`hdiutil`,
/// `cp`, `PropertyListSerialization`) is the honesty-gated analogue of
/// `Shot.swift`'s ScreenCaptureKit: the OS does the work the pure core can't, and
/// every refuse/verify DECISION is hoisted into a pure, unit-testable function so
/// the gates are real code, not hardcoded literals behind a guard.
///
/// Honesty contract (mirrors `shot`/`click-at`):
/// - REFUSE (throw, exit 1, NOTHING copied) when: the DMG is missing, the mount
///   fails / exposes no mount-point, the mount has zero or >1 top-level `.app`,
///   the destination already holds `<App>.app` and `--force` was not given, or
///   `cp -R` returns nonzero.
/// - VERIFIED only when, AFTER a 0-status copy, the destination bundle exists as a
///   directory AND its `Contents/Info.plist` parses with a non-empty
///   `CFBundleIdentifier`. A 0-status `cp` NEVER auto-upgrades to verified.
/// - DISPATCHED-UNVERIFIED (exit 0, the word "unverified" in the line, never
///   "installed/success") when the copy returned 0 but the bundle can't be
///   confirmed.
///
/// Out of scope (NOT verified, by design): Gatekeeper/quarantine/notarization,
/// code-signature validity, first-launch TCC. We prove presence + a parseable
/// `Info.plist`, not trust.
public enum Install {

    // MARK: - Pure decision 1: mount-plist → mount-point

    /// Parse `hdiutil attach -plist` STDOUT (as `Data`) and pull out the volume
    /// mount point. `hdiutil` lists several `system-entities` (the whole disk plus
    /// its slices); only the slice that was actually mounted carries a non-empty
    /// `mount-point` string. PURE: takes `Data`, no real mount — unit-testable on
    /// a fabricated plist. Returns `nil` on malformed/empty data or when no entity
    /// advertises a mount-point (honest no-evidence).
    public static func mountPoint(fromAttachPlist data: Data) -> String? {
        guard
            let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let dict = root as? [String: Any],
            let entities = dict["system-entities"] as? [[String: Any]]
        else { return nil }
        for entity in entities {
            if let mp = entity["mount-point"] as? String, !mp.isEmpty {
                return mp
            }
        }
        return nil
    }

    // MARK: - Pure decision 2: directory listing → chosen .app

    /// The single-`.app` choice over a FABRICATED list of top-level entry names
    /// (NOT a real directory read). Zero `.app` → `.none`; exactly one → `.one`;
    /// more than one → `.ambiguous` (NEVER guess which app to install). The live
    /// `install()` maps these to `.noAppInDMG` / the chosen app / `.ambiguousAppInDMG`.
    public enum AppChoice: Equatable, Sendable {
        case none
        case one(String)
        case ambiguous([String])
    }

    public static func chooseApp(in entries: [String]) -> AppChoice {
        // Case-insensitive `.app` suffix; ignore dotfiles / non-app entries.
        let apps = entries.filter { $0.lowercased().hasSuffix(".app") }
        switch apps.count {
        case 0: return .none
        case 1: return .one(apps[0])
        default: return .ambiguous(apps.sorted())
        }
    }

    // MARK: - Pure decision 3: overwrite / --force gate

    /// The don't-clobber gate. `allow` = nothing in the way; `refuseExists` = a
    /// bundle is already at the destination and `--force` was NOT given (REFUSE —
    /// never silently overwrite the user's installed app); `allowOverwrite` = it
    /// exists but `--force` was given. PURE: two booleans.
    public enum OverwriteDecision: Equatable, Sendable {
        case allow            // dest free
        case refuseExists     // dest occupied, no --force → refuse
        case allowOverwrite   // dest occupied, --force → proceed
    }

    public static func overwriteDecision(destExists: Bool, force: Bool) -> OverwriteDecision {
        if !destExists { return .allow }
        return force ? .allowOverwrite : .refuseExists
    }

    // MARK: - Pure decision 4: post-copy verify

    /// The honesty core: AFTER a 0-status `cp`, decide verified vs
    /// dispatched-unverified from REAL booleans. `verified` ONLY when the bundle
    /// exists as a directory at the destination AND a non-empty
    /// `CFBundleIdentifier` was read from its `Info.plist`. An empty id, a `nil`
    /// id, or a missing bundle is NOT proof — a 0-status copy never auto-upgrades.
    public enum VerifyDecision: Equatable, Sendable {
        case verified(id: String)
        case dispatchedUnverified
    }

    public static func verifyDecision(bundleExists: Bool, bundleIdentifier: String?) -> VerifyDecision {
        guard bundleExists,
              let id = bundleIdentifier,
              !id.isEmpty
        else { return .dispatchedUnverified }
        return .verified(id: id)
    }

    // MARK: - Pure helper: default dest + destination path join

    /// The default install destination when `--dest` is omitted.
    public static let defaultDest = "/Applications"

    /// `dest/<App>.app` — pure path join used by the live install for both the
    /// existence/force gate and the copy target.
    public static func destinationPath(dest: String, appName: String) -> String {
        (dest as NSString).appendingPathComponent(appName)
    }

    /// Pull a non-empty `CFBundleIdentifier` out of an `Info.plist`'s `Data`. PURE:
    /// the same plist machinery as the mount parse, isolated from IO so the live
    /// verify can be exercised on fabricated plist data too. Returns `nil` when the
    /// data is malformed or the key is missing/empty.
    public static func bundleIdentifier(fromInfoPlist data: Data) -> String? {
        guard
            let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let dict = root as? [String: Any],
            let id = dict["CFBundleIdentifier"] as? String,
            !id.isEmpty
        else { return nil }
        return id
    }
}

extension GhostHands {
    /// The result of a successful (verified OR dispatched-unverified) install. A
    /// REFUSE never produces an outcome — it throws before/without copying.
    public struct InstallOutcome: Sendable {
        public let appName: String        // "Foo.app"
        public let dest: String           // resolved destination directory
        public let installedPath: String  // dest/<App>.app
        public let verified: Bool
        /// The proven `CFBundleIdentifier` — present ONLY when `verified`.
        public let bundleIdentifier: String?
    }

    /// Install the single `.app` inside `dmgPath` into `dest` (default
    /// `/Applications`) via `cp -R`, then verify the installed bundle.
    ///
    /// Mount lifecycle: the volume is detached in a `defer` so EVERY later throw
    /// (no `.app`, ambiguous, force-refuse, copy fail) still unmounts — no leaked
    /// mounts, ever.
    @MainActor
    public static func install(dmgPath: String,
                               dest: String?,
                               force: Bool) async throws -> InstallOutcome {
        let dmg = (dmgPath as NSString).expandingTildeInPath
        let destDir = ((dest ?? Install.defaultDest) as NSString).expandingTildeInPath
        let fm = FileManager.default

        // REFUSE early: the DMG must exist on disk before we touch hdiutil.
        guard fm.fileExists(atPath: dmg) else {
            throw GhostHandsError.dmgNotFound(dmg)
        }

        // --- hdiutil attach -plist (the first subprocess in the codebase) ---
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", "-nobrowse", "-noverify", "-plist", dmg]
        let attachOut = Pipe()
        let attachErr = Pipe()
        attach.standardOutput = attachOut
        attach.standardError = attachErr
        do {
            try attach.run()
        } catch {
            throw GhostHandsError.mountFailed(reason: "could not run hdiutil: \(error.localizedDescription)")
        }
        // Drain stdout BEFORE waitUntilExit — a full pipe would deadlock the child.
        let attachData = attachOut.fileHandleForReading.readDataToEndOfFile()
        let attachErrData = attachErr.fileHandleForReading.readDataToEndOfFile()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else {
            let msg = String(data: attachErrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GhostHandsError.mountFailed(
                reason: (msg?.isEmpty == false ? msg! : "hdiutil exited \(attach.terminationStatus)"))
        }

        // PURE parse of the attach plist → mount point.
        guard let mountPoint = Install.mountPoint(fromAttachPlist: attachData) else {
            throw GhostHandsError.mountFailed(reason: "no mount-point in hdiutil output")
        }

        // ALWAYS detach (RAILS): set up the cleanup IMMEDIATELY so every throw
        // below still unmounts. Detach failure does not change the verdict, but we
        // never skip the attempt.
        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPoint, "-quiet"]
            // CRASH-SAFE: only wait when the launch actually succeeded. Calling
            // waitUntilExit() on a Process whose run() threw touches
            // terminationStatus on a never-launched task → NSInvalidArgumentException
            // ('task not launched') → SIGABRT. If hdiutil ever fails to LAUNCH on
            // detach we must NOT abort (that would also leak the mount): swallow the
            // launch error best-effort and skip the wait.
            do {
                try detach.run()
                detach.waitUntilExit()
            } catch {
                // best-effort unmount; never crash the verdict on a detach-launch failure
            }
        }

        // --- find the single top-level .app on the mount ---
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: mountPoint)
        } catch {
            throw GhostHandsError.noAppInDMG(mount: mountPoint)
        }
        let appName: String
        switch Install.chooseApp(in: entries) {
        case .none:
            throw GhostHandsError.noAppInDMG(mount: mountPoint)
        case let .ambiguous(names):
            throw GhostHandsError.ambiguousAppInDMG(candidates: names)
        case let .one(name):
            appName = name
        }

        let appSrcPath = (mountPoint as NSString).appendingPathComponent(appName)
        let destAppPath = Install.destinationPath(dest: destDir, appName: appName)

        // --- force gate (PURE decision driven by REAL booleans) ---
        let destExists = fm.fileExists(atPath: destAppPath)
        switch Install.overwriteDecision(destExists: destExists, force: force) {
        case .allow:
            break
        case .refuseExists:
            throw GhostHandsError.destinationExists(path: destAppPath)
        case .allowOverwrite:
            // --force: remove the existing bundle first so `cp -R` lands cleanly
            // (cp -R onto an existing dir would copy INTO it, not replace it).
            do {
                try fm.removeItem(atPath: destAppPath)
            } catch {
                throw GhostHandsError.copyFailed(
                    reason: "could not remove existing \(appName) for --force: \(error.localizedDescription)")
            }
        }

        // --- cp -R (RAILS: cp -R, never a GUI drag — no cursor, no focus steal) ---
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-R", appSrcPath, destAppPath]
        let cpErr = Pipe()
        cp.standardError = cpErr
        do {
            try cp.run()
        } catch {
            throw GhostHandsError.copyFailed(reason: "could not run cp: \(error.localizedDescription)")
        }
        let cpErrData = cpErr.fileHandleForReading.readDataToEndOfFile()
        cp.waitUntilExit()
        guard cp.terminationStatus == 0 else {
            let msg = String(data: cpErrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GhostHandsError.copyFailed(
                reason: (msg?.isEmpty == false ? msg! : "cp exited \(cp.terminationStatus)"))
        }

        // --- VERIFY: presence + parseable Info.plist (NEVER fabricate verified) ---
        // Drive the unit-tested gate from REAL booleans (the Shot.decide pattern),
        // so the refuse/verify arms are the code that actually runs.
        var isDir: ObjCBool = false
        let bundleExists = fm.fileExists(atPath: destAppPath, isDirectory: &isDir) && isDir.boolValue

        var bundleID: String? = nil
        if bundleExists {
            let infoPlistPath = (destAppPath as NSString)
                .appendingPathComponent("Contents/Info.plist")
            if let plistData = fm.contents(atPath: infoPlistPath) {
                bundleID = Install.bundleIdentifier(fromInfoPlist: plistData)
            }
        }

        switch Install.verifyDecision(bundleExists: bundleExists, bundleIdentifier: bundleID) {
        case let .verified(id):
            return InstallOutcome(appName: appName, dest: destDir,
                                  installedPath: destAppPath,
                                  verified: true, bundleIdentifier: id)
        case .dispatchedUnverified:
            return InstallOutcome(appName: appName, dest: destDir,
                                  installedPath: destAppPath,
                                  verified: false, bundleIdentifier: nil)
        }
    }
}
