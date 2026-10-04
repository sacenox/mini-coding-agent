# mini-coding-agent (`mini` for short)

A fast, transparent, config-first terminal coding agent for one user at a time.

This file holds intent, direction, and guardrails — not a description of the
code. The source is the source of truth for behavior. If a fact can be learned
by reading the code, it does not belong here; keep this file short.

## Intent

- A small, auditable core with no hidden machinery.
- A minimal system prompt with no injected meta-guidance.
- Provider work implemented in-tree over a small set of wire protocols.
- Durable, user-owned, readable session logs.
- An append-only TUI with a bounded live region and no full-screen buffer.
- Local models (Ollama / llama.cpp / vLLM) and hosted models treated as equals.
- One `zig build` produces one static binary. No runtime, no interpreter, no
  Node, no `node_modules`, no post-install scripts, no supply chain beyond what
  the code needs.

## Direction

Deferred, not rejected. Do not build unless explicitly promoted:

- context compaction / summarization / masking;
- reading or resuming sessions (the JSONL log is write-only today);
- prompt templates; custom agents / subagents / delegation;
- an extension or plugin system; a settings TUI; overlay editors;
- OAuth and any custom auth flow (environment keys and stored credentials only);
- MCP, image generation, multi-agent orchestration;
- sandboxing, approval prompts, permission policies;
- tests and CI (standing rule: no tests unless asked);
- macOS/Windows support and cross-platform abstractions. Target Linux first.

## Guardrails

Hard constraints. Do not cross these without explicit direction:

- **Zig only.** One `zig build` produces one binary. No Node, Bun, Deno, npm, or
  any JS/TS step. A C dependency is allowed only when explicitly approved.
- **No TUI library or framework.** Render with direct ANSI writes to stdout:
  append-only scrollback plus a bounded live region. No alternate screen, no
  full-screen cell grid.
- **The provider layer is in-tree.** Implement the wire protocols directly —
  `openai-completions`, `openai-responses`, `anthropic-messages`,
  `google-generative-ai`. Never depend on an external provider library.
- **Write original code.** Copy nothing from another project.
- **No sandbox or permission layer.** Tools run with the user's permissions;
  isolation is an environment concern, not the agent's.
- **No loop limits.** No max turns, tool calls, token budgets, or agent-imposed
  timeouts. The user's ability to interrupt is the limit.
- **Config-first.** Every user-facing behavior that can vary comes from config
  with a sane default. Global config only — no project-local config; a
  `-c`/`--config` file overrides the global one for a run — and never duplicate
  a provider's catalog or env vars.
- **Minimal context.** The model sees the configured system prompt plus
  explicitly opted-in resource files — never reminders, hidden blocks, or
  injected meta-text.
- **The agent never imports the TUI.** Headless and TUI are two projections of
  the same agent events; the TUI owns no agent or provider semantics.

## Invariants

- Sessions are append-only JSONL, one message per line, fsynced on write. Never
  rewrite or delete committed lines. A persistence failure stops the turn. Every
  model step also records the exact request: system prompt, tools, provider,
  model, api, and thinking effort.
- The loop has no compaction, no retries, and no meta-messages between steps.
  Provider errors surface as-is, never masked or summarized. Steering typed at a
  pause lands at the next step boundary, never between a turn and its results.
- `edit`, `read`, and `bash` only. Tool arguments are untrusted and validated
  once at the boundary. `read` returns image blocks only for models that declare
  image input.
- `bash` runs detached and kills its process group on cancel. Filesystem
  snapshots before and after produce diffs for display only; they never reach
  the model.
- Terminal output is fully specified: truecolor, an explicit palette for every
  cell, no resets that could fall back to the host terminal, and untrusted text
  sanitized of every escape sequence except SGR.
- Interruption: ESC politely pauses at the next step boundary; Ctrl+C cancels the
  turn (abort the request, kill the tool's process group, persist the aborted
  message); Ctrl+D exits on an empty draft. Completed side effects are never
  undone.
- Diagnostics are local only. No telemetry, no hidden stalls.

## Memory

Manual memory bookkeeping is the largest fragility a program of this shape can
carry. Do not reintroduce it.

- One allocator, chosen at startup, threaded explicitly. Long-lived state and
  per-turn scratch are separate lifetimes, not one global pool.
- A turn's transient objects — stream accumulators, tool result text, images,
  diffs, serialization buffers — die with the turn. Prefer arena or explicit
  lifetime over scattered frees.
- **Never swallow an allocation failure.** A dropped message, a silently
  truncated stream, or a `catch {}` on an append is a lost turn. Surface it
  through the event stream as an error the user can see.
- No hidden global mutable state beyond the process-wide allocator and IO
  handle, and those are set once at startup.

## Verification

Verify against the real provider. **Do not stand up mock servers, fixture
endpoints, or replay files**; they stall and prove nothing. Use the
`OPENCODE_API_KEY` environment variable and a scratch `XDG_CONFIG_HOME` with a
`mini-coding-agent/config.json` that declares the provider under test.

OpenCode Zen serves all four wire protocols. Base URLs and the working models:

- `openai-completions` — base `https://opencode.ai/zen/go/v1`, model
  `deepseek-v4.1-flash` (the daily path, also `opencode-go` in the config).
- `openai-responses` — base `https://opencode.ai/zen/go/v1`, model
  `gpt-6-luna`.
- `anthropic-messages` — base `https://opencode.ai/zen`, model
  `claude-haiku-4-5`.
- `google-generative-ai` — base `https://opencode.ai/zen/v1`, model
  `gemini-3.8-flash`.

Every Zen request needs the `x-opencode-session` header; set it via the custom
provider's `headers`. Not every catalog model is enabled for the account (for
example `claude-opus-5` is disabled and returns `Model access is disabled`), so
use the models above. Run a real tool call, not just a text turn.

## Driving the TUI with kitty

There is no `tmux` here. `tools/stress.sh` drives the TUI in a real kitty
window over remote control on a private socket, one window per run: it launches
the app in a scratch cwd, waits for the banner, types the prompt, and
screenshots the window at 15fps until the capture window ends or the app exits.

    tools/stress.sh -C <scratch cwd> -o /tmp/mini-runs/<name> -d 300 -p '<prompt>'

Frames land in `frame-NNNNN.png`. At the end of a run the pane is written with
its truecolor SGR to `final.txt` (scrollback) and `final-screen.txt` (live
screen). The last line reports frames, wall time, and achieved fps; an
`ended early: MINI-EXIT <n>` line means the app died, and `final.txt` holds the
dump. Read the pane text and the frames, not pixels.

## Working agreement

- Trace the real data flow before designing; apply guards at the narrowest
  boundary.
- Keep the diff small. Do not opportunistically refactor or harden adjacent code.
- Prefer plain functions and explicit allocators; keep exports minimal; define
  helpers near their use.
- Validate untrusted input once at the boundary, then keep internal code
  plain-typed with no runtime checks.
- Ask before adding a dependency.
- Do not add tests unless explicitly asked; verify manually.
- Before finishing, review the diff against the direction and guardrails, remove
  anything that added scope, and report any requirement you could not satisfy.
