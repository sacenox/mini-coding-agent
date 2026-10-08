# mini-coding-agent (`mini` for short)

A fast, transparent, config-first terminal coding agent written in Zig.

The source code is the source of truth for behavior. If a fact can be learned
by reading the code, it does not belong here; keep this file short.

## Guardrails

- Minimalist by design.
- Lightweight! Single binary, fast to boot and low memory usage.
- No sandbox or permission layer. Tools run with the user's permissions;
  isolation is an environment concern (`nono`), not the agent's.
- No loop limits. No max turns, tool calls, token budgets, or agent-imposed
  timeouts. The user's ability to interrupt is the limit.
- Config-first. Every user-facing behavior that can vary comes from config with
  a sane default. Global config only — no project-local config, no
  config-override flags — and never duplicate `pi-ai`'s catalog or env vars.
- Minimal context. The model sees the configured system prompt plus explicitly
  opted-in resource files — never reminders, hidden blocks, or harness
  meta-text.
- The agent never imports the TUI. Headless and TUI are two projections of the
  same agent events; the TUI owns no agent or provider semantics.
- Sessions are append-only JSONL, one message per line, fsynced on write. Never
  rewrite or delete committed lines. A persistence failure stops the turn.
- The loop has no compaction, no retries, and no meta-messages between steps.
  Provider errors surface as-is, never masked or summarized.
- `edit`, `read`, and `bash` only. Tool arguments are untrusted and validated
  once at the boundary. `read` returns image blocks only for models that declare
  image input.
- Interruption: ESC politely pauses at the next step boundary; Ctrl+C cancels
  the turn (abort the request, kill the tool's process group, persist the
  aborted message); Ctrl+D exits on an empty draft. Completed side effects are
  never undone.
- Trace the real data flow before designing; apply guards at the narrowest
  boundary.
- Validate untrusted input once at the boundary, then keep internal code
  plain-typed.
- Ask before adding a dependency.
- Do not add tests unless explicitly asked; verify manually.
- We are the maintainers of this codebase, treat it with care and attention to detail.

## Verification

**Do not stand up mock servers, fixture endpoints, replay files, throwaway scripts, or mock
terminals**; they prove nothing.

Use a real bash call for headless runs, and the `tools/stress.sh` script for TUI
runs.

### Provider

Verify against the real provider. Use the `OPENCODE_API_KEY` environment
variable and a `config.json` that declares the provider under test.

Use these models:

- `openai-completions` -> `opencode-go/deepseek-v4.1-flash`
- `openai-responses` -> `opencode-go/gpt-6-luna`
- `anthropic-messages` -> `opencode-go/minimax-m3`
- `google-generative-ai` -> `opencode/gemini-3.8-flash`

### Driving the TUI with kitty

There is no `tmux` here. `tools/stress.sh` drives the TUI in a real kitty
window over remote control on a private socket, one window per run: it launches
the app in a scratch cwd, waits for the banner, types the prompt, and
screenshots the window at 15fps until the capture window ends or the app exits.

    tools/stress.sh -C <scratch cwd> -o /tmp/mini-runs/<name> -d 60 -p '<prompt>'

Frames land in `frame-NNNNN.png`. At the end of a run the pane is written with
its truecolor SGR to `final.txt` (scrollback) and `final-screen.txt` (live
screen). The last line reports frames, wall time, and achieved fps; an
`ended early: MINI-EXIT <n>` line means the app died, and `final.txt` holds the
dump.
Make sure to review both images and text, so you can inspect the TUI themeing.
