# mini-coding-agent (`mini` for short)

A fast, transparent, config-first terminal coding agent for one user at a time.

This file holds intent, direction, and guardrails — not a description of the
code. The source is the source of truth for behavior. If a fact can be learned
by reading the code, it does not belong here; keep this file short.

## Verification

Verify against the real provider. **Do not stand up mock servers, fixture
endpoints, or replay files**; they stall and prove nothing. Use the
`OPENCODE_API_KEY` environment variable and a scratch `XDG_CONFIG_HOME` with a
`mini-coding-agent/config.json` that declares the provider under test.

Every Zen/Go request needs the `x-opencode-session` header; set it via the custom
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
