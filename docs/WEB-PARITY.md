# Web ergonomics parity — ghosthands vs agent-browser

**One line:** on the web, ghosthands is already *more honest* and reaches further
(native apps, real-Brave Widevine, no focus steal) than agent-browser — the only
gap is how fast/clean it is to **drive**. This doc captures the comparison, the
locked design, and the work-list we loop over to close it.

---

## How the comparison was run

The same 11-task battery (HN reads, Wikipedia, DuckDuckGo, BBC, an httpbin pizza
form, the-internet dropdown/checkboxes, a cross-app TextEdit list, YouTube play,
Google Maps) was driven twice:

1. **ghosthands** via the CDP web path (`web read`/`web click`/`web fill`/`web eval`).
2. **agent-browser 0.27.0** using only its native verbs (`snapshot`/`get`/`find`/
   `click`/`fill`/`check`/`select`) — no JS.

Both cleared every **browser** task. The two agent-browser misses were
**structural, not skill**: it cannot drive a native macOS app (TextEdit), and its
bundled Chromium cannot play DRM/H.264 video (YouTube showed "Something went
wrong"). ghosthands did both — and every ghosthands verb stayed verify-or-refuse,
while agent-browser printed `✓ Done` even on a fill that silently did nothing.

So ghosthands **wins on capability + honesty**. It **loses on driving ergonomics**.
This doc is about closing that one gap without giving up the wins.

---

## Why agent-browser is fast to drive (plain)

1. It takes one quick **x-ray** of the page = a numbered list of everything you can
   touch: "①Sign-in button ②search box ③first result…".
2. You say **"click ③."** Done.

One look, then point by number. The number is a **handle** the tool remembers. No
describing, no guessing.

## Why ghosthands is clunky to drive (plain)

ghosthands has **two tools that don't speak the same language**:

- one to **look** (`web read`) → a menu of names + positions;
- one to **click** (`web click`) → which won't take a name off that menu; you must
  **describe the thing by hand** in its own private wording every time.

So each click = read the menu → hand-translate "the Sign-in button" → click → and
on a name collision it **gives up** ("ambiguous").

**Honest nuance:** ghosthands is *not* slow at the clicking — each action measured
~0.1s, **faster** than agent-browser's ~0.16s. The slow part is the **extra steps
to set up each click** (look → translate → retry on ties). It's slow to *drive*,
not slow to *run*. The fix is fewer steps, not faster code.

## The fix (Y)

Make **look and click share the same numbered handles.** When `web read` looks at
the page, stamp ①②③ on every touchable element and let `web click/fill` take those
numbers. One look, point by number — same as agent-browser, minus the translation
and the ambiguity refusals.

---

## Locked design — addressing (also "the best solution to semantic find")

**Primary = numbered handles (fast everyday path).** `web read` prints `@eN` per
interactive element; `web click @eN` / `web fill @eN` act on the element captured at
read time; CSS still works (refs are additive); a ref invalidated by navigation/
re-render REFUSES ("stale ref, re-read").

**Backup = find by what a human SEES** (only when refs don't fit — no prior read,
or a page that keeps re-rendering):
1. Resolve by **visible text / label / role**, never hidden code names.
2. **Re-resolve live** at action time (can't go stale like a number can).
3. **On a tie, rank** by visible + on-screen + top-most; act on the obvious one or
   report the short list and accept `first` / `nth N` — don't refuse by default.
4. **Stay honest** — report what was picked, then verify the effect.
5. Ship it **thin and after refs** (refs cover ~90% of clicks).

Numbered handles are the answer to "semantic find" — find is the backup, not the
primary. (Locked in issue **#7**.)

---

## The work-list (what we loop over)

P0 closes ~80% of the gap. All keep the honesty contract (verify-or-refuse).

| Issue | Title | Pri | One line |
|---|---|---|---|
| [#7](https://github.com/georgenijo/ghosthands-native/issues/7) | shared `@ref` addressing (+ see-the-words backup) | **P0** ✅ | **shipped** (ref primary; see-the-words backup = scheduled tail) — look and click share numbered handles |
| [#9](https://github.com/georgenijo/ghosthands-native/issues/9) | managed throwaway session (`web open --headed`/`web close`) | **P0** ✅ | **shipped** — one command, auto-port, ready-wait; later verbs auto-target it (no --debug-port) |
| [#10](https://github.com/georgenijo/ghosthands-native/issues/10) | page-side waits (`web wait --text/--url/--selector/--load`) | **P0** | no hand-rolled poll loops |
| [#8](https://github.com/georgenijo/ghosthands-native/issues/8) | form-control state in `web read` (`checked`/`selected`/`value`) | P1 | verify a toggle in one read, no `web eval` |
| [#11](https://github.com/georgenijo/ghosthands-native/issues/11) | no-JS extraction (`web text/attr/count` + scoped read) | P1 | routine reads without `eval` |

Already filed from the first (ghosthands-only) stress test — keep, don't dupe:

| Issue | Title |
|---|---|
| [#5](https://github.com/georgenijo/ghosthands-native/issues/5) | `type`/`set-value` accept `--nth`/`--role`/`--text` (the TextEdit 4-window ambiguity) |
| [#6](https://github.com/georgenijo/ghosthands-native/issues/6) | `web click` post-click DOM read-back so in-page (non-navigating) toggles earn VERIFIED |

**Loop order:** #7 → #9 → #10 → #8 → #11, then the #7 see-the-words backup, with
#5/#6 slotted where they touch the same files.

---

## What NOT to lose while closing the gap

The reasons to bet on ghosthands over agent-browser — keep every one:

- **Honesty enforced** — every `web` verb stays verify-or-refuse; never an
  agent-browser-style `✓ Done` that masks a no-op.
- **Native-AppKit reach** — TextEdit/Finder/Settings, which agent-browser can't touch.
- **Real browser** — Widevine/H.264, so real video plays.
- **Invisible** — background windows, no cursor move, no focus steal.

Land #7 + #9 + #10 and ghosthands has agent-browser's web *feel* **plus** the
honesty and native reach agent-browser structurally lacks. That's a win, not a tie.
