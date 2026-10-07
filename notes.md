# Some notes from reading the code.

> Context: I'm mostly a web engineer, with some backend experience with python, node and go.

Some of my notes might be because of lack of Zig experience.

## Notes

`src/config.zig` - When we fixed the issue with the model specific api being at provider level for opencode in a recent commit, apparently we didn't do it for custom providers. Again, the models need to carry the metadata, the provider is just a label grouping.

```jsonc
// Example custom provider **correct**
{
    "id": "local",
    "name": "Local",
    "models": [{
        "id": "qwen3-coder",
        "api": "openai-completions",
        "baseUrl": "http://127.0.0.1:11434/v1"
    }],
    "envKeys": ["LOCAL_API_KEY"],
    "headers": { "x-tenant": "mini" }
}
```

I suggest the above structure, so we match the work we did for opencode. Basically the mistake here is assuming all providers use the same api for all models, which is not true. Not even for local envs.
Another note here is that again, I'm shocked at how cumbersome it is to read and validate JSON.

**resize, width measurements, line wrapping** -  these still behave in suprising ways sometimes, breaking highligting, wrapping at weird limits, stange states after resize.
A definite research about the best approach to a clean rendering method is required, instead of trial and error. This is not breakthrough, many TUIs have these issues and address them. Use github to learn. Once you've applied the fixes, do exhaustive testing with the stress script or the techniques described there.

**`src/main.zig` - has some headless concerns mixed into the entry point of the app. Worth considering extracting headless into `src/headless.zig`. Single concern files are easier to make a mental model around.

`src/diff.zig` - We are rendering a whole header with index and divider, just to strip it in the TUI. Seems counter productive.

`src/tui/tui.zig` - This file has a lot of responsibilities, making it very big. Token estimation and commands at least, could be extracted. 

`src/tui/theme.zig` - will eventually grow too much, each theme we add will make that file worse. A refactor for later, since it's ok right now.

## Rendering defects reproduced (real kitty, real provider)

Measured against a real kitty window via `kitty @` remote control
(`get-text`, `resize-os-window`) and a real turn against the live provider.

1. **Width model is per-codepoint.** `render.charWidth` sums codepoints; a
   grapheme cluster is not a codepoint. Kitty-measured vs app:
   `🏳️‍🌈` 2 vs 4, `👨‍👩‍👧‍👦` 2 vs 8, `🇩🇪` 2 vs 4, `👍🏽` 2 vs 4,
   `✅` 2 vs 1, `☀️`/`™️`/`0️⃣` 2 vs 1, `🇺🇸` 2 vs 4, `🔟` 2 vs 1.
   Wide chars (`日 한 ａ`) and ambiguous (`∵ ∴`) are right.
2. **Highlighting breaks across a soft wrap.** `wrapLine` splits bytes at a
   width boundary; a tree-sitter span that crosses the boundary loses its SGR
   on the continuation row (the opening sequence stays on the previous row).
   Narrowing a fenced python block to 50 shows the continuation rows in the
   normal fg.
3. **Reflow does not rejoin on widen.** `history` stores already-wrapped
   physical rows; `reflow` re-wraps them, so a paragraph wrapped at 100 stays
   broken at 100 after widening to 120. Confirmed: after 100→120 the rows still
   end at the old 100-col boundary.
4. **Reflow loses style.** `reflow` repaints every history row with
   `paintRow` (which prepends `SGR_PLAIN`), so styled rows come back unstyled.
   Confirmed: teal/comment rows repaint as `[197,201,197]`.
5. **`3J` on every resize drops native scrollback** (`\x1b[2J\x1b[3J\x1b[H`).
6. **Live-region accounting after resize** is a heuristic
   (`reanchor = live.rows >= height-1`), and `reflow` resets `live` without
   reconciling the cursor.

Reference implementations studied: bubbletea `cursed_renderer.go` (inline
`Erase`+redraw on width change, cursor parked off the last column, cells owned
by the app), Ink/`wrap-ansi` and lipgloss SGR-balanced wrap, Ghostty/uucode
grapheme-cluster width, `unicode-display_width` precedence rules.

### Resolved approach

Validated against real kitty by driving the terminal over remote control and
reading back `get-text`/`get-cell-colors` and DSR replies (prototypes in
`/tmp/proto`), so the design comes from measured terminal behavior, not trial
and error.

- **Committed transcript is written as logical lines once.** kitty soft-wraps
  logical lines, repeats the active SGR on every wrapped row, and *reflows and
  rejoins* them on resize; it neither rejoins nor restyles hard (CRLF) rows.
  So the app must not pre-wrap or re-emit committed content, and must not send
  `ED2`/`ED3` on resize.
- **The live region is pre-wrapped by the app** (status, queue, body, editor),
  because the editor needs to own its cursor. It is redrawn every frame.
- **Erase uses the caret.** The cursor is parked on the caret cell. To erase,
  move up by the caret's physical row offset *recomputed at the current width
  from the previous frame's live rows* (`sum ceil(cells_i/W) + col/W`), CR,
  SGR, `ED0`. The terminal keeps the cursor attached to its character across
  reflow, so that offset is exact.
- **Width** comes from generated UCD tables and a UAX#29 grapheme-cluster
  walk (`src/tui/width.zig`); it matches kitty cell-for-cell.
