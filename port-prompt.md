# Task: port mini-coder to Zig as `mini-z-agent`

You are starting `mini-z-agent` (`mza`), a Zig port of `mini-coder`. Read
`AGENTS.md` in this directory first and follow it. It is the law. This document
is the work order; `AGENTS.md` governs every decision.

## Context you need

`mini-coder` (`../mini-coder/`) is a TypeScript terminal coding agent that works.
It is the behavior specification. Below it in this conversation there is a
history: two earlier ports of it exist.

- `../tiny-c-agent/` — a careful C port. It translated the design faithfully and
  is the best low-level detail reference available: the four wire protocols,
  streaming reassembly, diff capture, UTF-8 and base64 handling, session
  durability. It is also the cautionary tale. Moving to C meant reimplementing,
  by hand, everything the TypeScript version got from its runtime and from
  `pi-ai`: HTTP, JSON, an SSE parser, a diff engine, a UTF-8 validator, base64.
  That produced 10,207 lines against the reference's 3,575, 552 `free()` calls,
  33 `abort()` calls, and a commit titled `fix: memory fixes`.
- `../zig-agent-kanso/` — an experimental, one-shot Zig port. It proves the
  language fit: one `zig build`, four hash-pinned tree-sitter dependencies, no
  `pkg-config` on the host, 6,745 lines, nine deinit sites, zero `abort()`.
  `std.http.Client` replaced libcurl, `std.json` replaced a C JSON library, and
  one startup allocator replaced the manual free bookkeeping entirely. It is
  also incomplete and less careful than tiny: the provider layer has gaps, and it
  silently swallows errors in several places (`catch {}` on message and session
  appends).

Your job is to combine them: mini's behavior, tiny's care, and kanso's Zig.

## The goal, stated plainly

One static binary with no runtime, no interpreter, no `node_modules`, no
post-install scripts, and a dependency surface only as large as the work needs.
Small in all aspects. This is the reason the project exists. Weigh every decision
against it.

## What is fixed

These are inherited and are not open for redesign. Port them as they are:

- Three tools: `read`, `edit`, `bash`.
- The four wire protocols: `openai-completions`, `openai-responses`,
  `anthropic-messages`, `google-generative-ai`.
- Append-only JSONL sessions, fsynced, one message per line, plus a request
  record per model step. Never rewrite a committed line.
- The agent loop's shape: no compaction, no retries, no meta-messages. Steering
  lands at a step boundary, never between an assistant turn and its tool results.
- Interruption: ESC pauses politely at the next boundary, Ctrl+C cancels the turn
  and kills the tool's process group, Ctrl+D exits on an empty draft.
- The event stream as the single seam between the agent and its two projections,
  headless and TUI. The agent never imports the TUI.
- Config-first, global config only.
- The TUI's appearance and behavior: append-only scrollback, a bounded live
  region, truecolor with an explicit palette for every cell, no resets that fall
  back to the host terminal, untrusted text sanitized of every non-SGR escape.

## What you must decide and own

### Memory

This is the point of the port, so treat it as a design decision, not a detail.

- Choose the allocator strategy at startup and thread it explicitly. Long-lived
  state and per-turn scratch are different lifetimes.
- Do not copy kanso's single global pool. It avoids `free()` by never releasing,
  which is not the same as being correct.
- Per-turn transient objects — stream accumulators, tool result text, images,
  diffs, serialization buffers — should die with the turn. Arena or explicit
  lifetime, your choice, but the code must show the lifetime.
- **Never swallow an allocation failure.** `catch {}` on a message or session
  append loses a turn silently. Every such failure reaches the event stream as a
  visible error. This is a hard rule in `AGENTS.md` and it is the specific
  mistake kanso made.

### Provider layer

This is the largest and highest-risk part. Port the encoders and the streaming
reassembly from tiny's structure, because tiny's comments encode decisions that
are not visible in mini's behavior and are easy to reintroduce as bugs:

- Untrusted stream indices are hints, never sizes. Bound them.
- Image blocks among a run of tool results are placed so a user message never
  lands between an assistant turn and its tool results.
- Provider errors surface as-is, never masked or summarized.
- Provider-specific continuation data is kept intact.

Validate the wire formats against reality, not against your reading of them.

### Dependencies

Keep the set small and justified. `std` replaces most of what tiny needed C
libraries for. tree-sitter and its grammars are the known external need. Any
addition beyond that is a decision to raise, not to take.

## Order of work

Do not port wide. This is a port of a working product, and the risk is breadth.

Build one vertical slice first and make it work end to end:

1. `zig build` skeleton: `build.zig`, `build.zig.zon`, one binary named `mza`,
   the allocator chosen at startup, config loading, the `--print` headless path,
   and the `read` tool. Prove a single turn streams text and persists a session
   with `openai-completions`, because opencode-go uses it and it is the daily
   path (Key is available to use in env `OPENCODE_API_KEY`, and a suggested
   config in `~/.config/mini-coder`).
2. Add `edit` and `bash`, the filesystem snapshot diff, and the headless event
   projection.
3. Build the TUI on the same event stream: append-only scrollback, bounded live
   region, themes, syntax highlighting via tree-sitter, diff rendering.
4. Add the remaining three wire protocols, one at a time, each verified on its
   own before the next.

Each step must build, run, and be usable at its end. Do not land a step that is
half-done.

## Verification

The oracle discipline is what made the C port careful, and it is load-bearing
here because you will read Zig less fluently than TypeScript. Use it.

- `../mini-coder/` is the behavioral oracle. Run the same prompt through both and
  compare the session JSONL and the visible output.
- For the provider layer, `../tiny-c-agent/` is a second oracle. Its four API
  modules are the careful translation; compare request bodies and assembled
  messages where you can.
- Verify the TUI with the kitty remote-control procedure in `../mini-coder/AGENTS.md`.
- Tests and CI are deferred by standing rule. Verify manually. Do not add a test
  suite.

## Non-goals

Do not build these; they are deferred by explicit decision in `AGENTS.md`:
compaction, resume, prompt templates, subagents, plugins, a settings TUI,
OAuth, MCP, sandboxing, macOS/Windows support, tests, CI.

## Report

When you finish a step, report:

- The files you added or changed and the shape of each.
- The memory strategy you chose and why it fits the lifetimes.
- Any place you made a judgment call between mini's behavior and tiny's
  structure, and which you followed.
- Any requirement in `AGENTS.md` or this document you could not satisfy.
