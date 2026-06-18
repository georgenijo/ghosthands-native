import Foundation

// GhostHands WEB WAIT tier — page-side condition waits for browser surfaces (CDP),
// the web analogue of the AX `wait` verb (issue #10). Replaces the hand-rolled
// `curl` / `web eval` poll loops the stress test needed to sequence a navigation
// + content-appearance flow.
//
//   web wait --text "<substr>"                  — until body text contains substr
//   web wait --url  "<glob>"                     — until location.href matches a glob
//   web wait --selector "<css>" [--gone]         — until an element is present / absent
//   web wait --load domcontentloaded|networkidle — until a load state is reached
//
// HONESTY CONTRACT (identical to AX `wait`): a timeout is a REFUSE
// (`waitTimeout` thrown, nonzero exit), NEVER a fabricated "met". The verb only
// returns once the condition is OBSERVED to hold AT OR BEFORE the deadline; it
// reports the elapsed time + poll count as auditable evidence.
//
// PURITY: the per-poll observation (a single `Runtime.evaluate`) is the only
// impure step. The condition model — which JS each kind probes, and how a probe
// result decides met — plus the URL glob matcher are PURE and hermetically
// unit-tested over fabricated probe dictionaries, with no socket and no browser.

// MARK: - PURE: the load state

/// The two load states `web wait --load` understands. `domcontentloaded` is the
/// DOM-ready milestone (`readyState` ≥ interactive); `networkidle` is the
/// quiet-network milestone, approximated HONESTLY page-side (see
/// `WebWait.probeExpression`) since the CDP session here has no event stream.
public enum WebLoadState: String, Sendable, Equatable, CaseIterable {
    case domcontentloaded
    case networkidle
}

// MARK: - PURE: the condition kind

/// What a `web wait` is waiting for. Exactly one per invocation (the CLI enforces
/// mutual exclusion). `selector` carries the `--gone` sense; the others don't use it.
public enum WebWaitKind: Sendable, Equatable {
    case text(String)
    case url(String)
    case selector(String, gone: Bool)
    case load(WebLoadState)
}

// MARK: - PURE: a glob matcher for --url

/// A minimal, PURE glob matcher for `web wait --url "<glob>"`. Supports `*`
/// (matches any run of characters, including empty); every other character is
/// literal. A glob with NO `*` is an exact match. This is the testable heart of the
/// url wait — kept independent of any clock or socket.
public enum WebGlob {
    /// True iff `text` matches `glob`, where `*` is the only wildcard. Implemented
    /// as a classic two-pointer wildcard match (no regex — a user's URL can contain
    /// regex metacharacters like `?`/`.`/`+` that must stay LITERAL).
    public static func matches(glob: String, text: String) -> Bool {
        let g = Array(glob), t = Array(text)
        var gi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if gi < g.count, g[gi] == "*" {
                star = gi; mark = ti; gi += 1
            } else if gi < g.count, g[gi] == t[ti] {
                gi += 1; ti += 1
            } else if star != -1 {
                gi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while gi < g.count, g[gi] == "*" { gi += 1 }
        return gi == g.count
    }
}

// MARK: - PURE: the condition model (probe + decide)

/// The pure condition logic: the per-kind JS probe, the met-decision over a
/// probe's `[String: Any]` result, and the human label / `--gone` sense for the
/// outcome + the timeout refuse. No IO — unit-tested over fabricated probes.
public enum WebWait {
    /// How long the network must be quiet (ms) before `--load networkidle` is met.
    /// Mirrors the common 500ms idle window used by page-automation tools.
    public static let networkIdleQuietMs = 500

    /// The JS each kind evaluates per poll. Each returns a SMALL object the pure
    /// `met` reads: `{ present: bool }` (text / selector), `{ href: string }` (url),
    /// `{ ready: bool }` (load). The needle/selector is embedded as a JSON string
    /// literal so it can never break out of the expression (never trusted as code).
    public static func probeExpression(for kind: WebWaitKind) -> String {
        switch kind {
        case let .text(needle):
            let n = WebActuate.jsonStringLiteral(needle)
            return """
            (() => {
              const t = (document.body && document.body.innerText) || '';
              return { present: t.indexOf(\(n)) !== -1 };
            })()
            """
        case let .selector(css, _):
            let c = WebActuate.jsonStringLiteral(css)
            return """
            (() => {
              let el = null;
              try { el = document.querySelector(\(c)); } catch (e) { el = null; }
              return { present: !!el };
            })()
            """
        case .url:
            // The glob is matched in Swift (WebGlob) — the page just reports href.
            return "(() => ({ href: document.location.href }))()"
        case let .load(state):
            switch state {
            case .domcontentloaded:
                return """
                (() => ({ ready: document.readyState === 'interactive'
                                 || document.readyState === 'complete' }))()
                """
            case .networkidle:
                // HONEST approximation (no CDP Network event stream here): idle iff
                // the document is fully loaded AND no resource-timing entry has
                // started or finished within the quiet window. Described as such.
                return """
                (() => {
                  if (document.readyState !== 'complete') return { ready: false };
                  const es = performance.getEntriesByType('resource');
                  let last = 0;
                  for (const e of es) {
                    last = Math.max(last, e.responseEnd || 0, e.startTime || 0);
                  }
                  const idle = performance.now() - last;
                  return { ready: idle >= \(networkIdleQuietMs) };
                })()
                """
            }
        }
    }

    /// Decide whether ONE poll's probe result means the condition is MET. Pure —
    /// the live loop calls this each poll, and the hermetic tests replay fabricated
    /// probe dictionaries through it. A missing/garbage field reads as NOT met
    /// (honest: an unreadable probe is a `notYet`, never a fabricated success).
    public static func met(kind: WebWaitKind, observation obs: [String: Any]) -> Bool {
        switch kind {
        case .text:
            return WebActuate.boolValue(obs["present"])
        case let .selector(_, gone):
            let present = WebActuate.boolValue(obs["present"])
            return gone ? !present : present
        case let .url(glob):
            guard let href = obs["href"] as? String else { return false }
            return WebGlob.matches(glob: glob, text: href)
        case .load:
            return WebActuate.boolValue(obs["ready"])
        }
    }

    /// A human label for the condition — used in the met-report and the timeout
    /// refuse (`waitTimeout`'s `name`), so both read like the AX `wait` they mirror.
    public static func label(_ kind: WebWaitKind) -> String {
        switch kind {
        case let .text(s): return "text \(s.debugDescription)"
        case let .url(g): return "url \(g.debugDescription)"
        case let .selector(c, gone):
            return "selector \(c.debugDescription)\(gone ? " (gone)" : "")"
        case let .load(state): return "load \(state.rawValue)"
        }
    }

    /// The `--gone` sense for the outcome / timeout bookkeeping — only a
    /// `--selector --gone` wait is an absence wait; every other kind is presence.
    public static func isGone(_ kind: WebWaitKind) -> Bool {
        if case let .selector(_, gone) = kind { return gone }
        return false
    }
}

// MARK: - Live web wait (impure thin — pure decisions above)

extension GhostHands {
    /// `web wait <condition> [browser] [--timeout s] [--interval ms]` — poll the
    /// page over CDP until the condition is OBSERVED met, or REFUSE on timeout.
    /// Mirrors AX `wait`: a hard wall-clock deadline, the deadline FENCE (a poll
    /// that completes after the deadline can't satisfy the wait), elapsed + poll
    /// evidence, and a timeout that throws `waitTimeout` (never a fabricated met).
    ///
    /// A transient evaluate failure (e.g. the execution context destroyed by a
    /// navigation mid-poll) is swallowed as a `notYet`, so a URL/text wait that
    /// straddles a navigation keeps polling rather than aborting.
    @MainActor
    public static func webWait(kind: WebWaitKind, browser: String, lens: WebLens,
                               debugPort: Int = 9222, relaunch: Bool = false,
                               timeout: TimeInterval = 5, interval: TimeInterval = 0.2)
        async throws -> (outcome: WaitOutcome, port: Int) {
        let (target, port) = try await resolveForSelectorVerb(
            browser: browser, lens: lens, port: debugPort, relaunch: relaunch)
        let session = try await openPageSession(target: target, port: port)
        let expr = WebWait.probeExpression(for: kind)
        let label = WebWait.label(kind)
        let gone = WebWait.isGone(kind)

        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var polls = 0
        while true {
            polls += 1
            // ONE observation — a destroyed context (mid-navigation) or any
            // transient evaluate error reads as an empty probe → notYet, never abort.
            let obs = (try? await evaluateObject(session, expr)) ?? [:]
            let now = Date()
            let elapsed = now.timeIntervalSince(start)

            // THE DEADLINE FENCE (mirrors WaitVerdict): a poll only satisfies the
            // wait if it completed AT OR BEFORE the deadline — a met seen too late
            // can never flip a timeout into a dishonest success.
            if now <= deadline, WebWait.met(kind: kind, observation: obs) {
                let outcome = WaitOutcome(app: target.name, name: label,
                                          wantedGone: gone, elapsed: elapsed, polls: polls)
                return (outcome, port)
            }
            if now >= deadline {
                throw GhostHandsError.waitTimeout(name: label, app: target.name,
                                                  wantedGone: gone, seconds: timeout)
            }
            if interval > 0 {
                let remaining = deadline.timeIntervalSince(Date())
                if remaining <= 0 {
                    throw GhostHandsError.waitTimeout(name: label, app: target.name,
                                                      wantedGone: gone, seconds: timeout)
                }
                try? await Task.sleep(for: .seconds(min(interval, remaining)))
            }
        }
    }
}
