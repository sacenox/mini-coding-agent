# mini-coding-agent

A fast, transparent, config-first terminal coding agent.

## Build

Requires Zig 0.17.0.

    zig build

The binary lands at `zig-out/bin/mini`. `zig build run -- <args>` builds and
runs it. Provider model metadata is embedded from `src/models_dev.json`; refresh
it with `python3 tools/gen_models_dev.py`.

## Run

    mini                 # interactive TUI
    mini -p '<prompt>'   # one turn, print the reply, exit
    mini -c <file>       # overlay a config file for this run

Arguments:

| Flag | Meaning |
|---|---|
| `-p <prompt>`, `--print <prompt>` | run one prompt non-interactively and print the assistant text |
| `-c <file>`, `--config <file>` | read a config file after the global one; its keys win |

`-p=<prompt>`, `--print=<prompt>`, `-c=<file>`, and `--config=<file>` work too.
Any other argument exits 1.

`-p` requires a model in the config. Without one it exits 1 and prints where
the config lives. Interactive mode requires a TTY. In `-p` mode tool calls and
tool output go to stderr, the assistant text to stdout; a failed turn exits 1.
`SIGINT` and `SIGTERM` cancel the turn and then re-raise, so the exit status is
the signal.

## TUI commands

| Command | Meaning |
|---|---|
| `/help` | list commands and keybindings |
| `/new` | start a new session |
| `/provider` | choose the provider, then its model |
| `/model` | choose a model for the current provider |
| `/thinking` | set the thinking level |

`/provider` lists only providers whose API key is present. `/model` needs a
configured model and asks the provider for its model list over the wire. A
custom provider lists what it declares. Choosing a model writes `provider` and
`model` back to the config file, then opens the thinking picker; `/thinking`
writes `thinkingEffort`. The file written is the one `-c` named, when given.

## Keybindings

| Key | Meaning |
|---|---|
| `Enter` | submit; on an empty draft after a failure, retry it |
| `Shift+Enter`, `Alt+Enter`, `Ctrl+J` | newline |
| `Shift+Up`, `Shift+Down` | walk past input |
| `Ctrl+R` | reverse search past input |
| `Esc` | pause the turn at the next step boundary; close a picker |
| `Ctrl+C` | cancel the turn; otherwise close a picker or clear the draft |
| `Ctrl+D` | exit on an empty draft |
| `Tab` | complete command or path |
| `Ctrl+Left`, `Ctrl+Right` | move by word |
| `Ctrl+W`, `Ctrl+Backspace`, `Alt+B` | delete the word before the cursor |
| `Home`, `Ctrl+A` / `End`, `Ctrl+E` | line start / line end |
| `Ctrl+Home`, `Ctrl+End` | draft start / draft end |
| `Delete` | delete forward |

While a turn is paused (`Esc`), submitting a message steers the running turn.

The status line shows the phase, the elapsed time, the estimated context use
against the model's window, and the cache-read share of the last prompt.

## Tools

The model sees only the tools listed in `tools`; a call to any other name is an
error.

| Tool | Behavior |
|---|---|
| `read` | returns a file's text; `offset` (1-based) and `range` give a line window; text is cut at 100k characters; binary files are refused; `png`/`jpg`/`jpeg`/`webp` are returned as an image only when the model accepts image input, and only if the base64 form stays under 5 MiB |
| `edit` | replaces `oldText`, which must occur exactly once; an empty `oldText` creates a new file and fails if it exists; prints a unified diff |
| `bash` | runs `bash -c` in the cwd with a 120s default `timeout`; output keeps the first 10k and last 6k bytes around a truncation marker and ends with an `exit code:` line; a before/after snapshot of the cwd reports changed files as diffs |

Both `read` and `edit` expand a leading `~/`. Tool arguments are parsed once at
the boundary and validated there; a bad shape fails the call with a message.

The TUI renders a summary line per call (the command for `bash`, the path for
`read`/`edit`), the output body, and a diff with `+added -removed` counts.
`exit code: 0` folds into a `└ exit 0` line.

## Configure

The config is one JSON object. It is read from
`$XDG_CONFIG_HOME/mini-coding-agent/config.json`, else
`$HOME/.config/mini-coding-agent/config.json`. A missing file means every
default. There is no project-local config. `-c` reads a second file over it.

A full example:

```json
{
  "provider": "opencode",
  "model": "deepseek-v4.1-flash",
  "thinkingEffort": "medium",
  "showImages": false,
  "systemPrompt": "Be terse.",
  "sessionsDir": "/home/me/.local/state/mini-coding-agent/sessions",
  "discoverAgentFiles": true,
  "skillsDirs": ["/home/me/.agents/skills"],
  "tools": ["edit", "read", "bash"],
  "programStatus": false,
  "herdr": false,
  "snapshotIgnoreDirs": [".git"],
  "snapshotUsesGitignore": true,
  "historySize": 100,
  "maxDiffLines": 2000,
  "customProviders": [
    {
      "id": "local",
      "name": "Local",
      "models": [
        {
          "id": "qwen3-coder",
          "name": "Qwen3 Coder",
          "api": "openai-completions",
          "baseUrl": "http://127.0.0.1:11434/v1",
          "context": 32768,
          "maxOutput": 8192,
          "images": false,
          "reasoning": true,
          "effort": ["low", "high"],
          "cost": [0, 0, 0]
        }
      ],
      "envKeys": ["LOCAL_API_KEY"],
      "headers": { "x-tenant": "mini" }
    }
  ]
}
```

Keys:

| Key | Default | Meaning |
|---|---|---|
| `provider` | unset | provider id; built-ins are `opencode` and `opencode-go`, or a `customProviders` id |
| `model` | unset | model id |
| `thinkingEffort` | unset | one of `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`; unset sends no reasoning parameter; a level the model does not accept clamps up to the next accepted one, else down |
| `showImages` | `false` | draw the images the `read` tool returns inline using the kitty graphics protocol; requires kitty 0.28+ |
| `systemPrompt` | `""` | prepended to the system prompt |
| `sessionsDir` | `$XDG_STATE_HOME/mini-coding-agent/sessions`, else `$HOME/.local/state/mini-coding-agent/sessions`, else `sessions` | where JSONL session logs go |
| `discoverAgentFiles` | `true` | load `AGENTS.md`/`CLAUDE.md` from `$HOME/.agents` and the cwd, deduplicated by real path |
| `skillsDirs` | `[]` | directories holding `<name>/SKILL.md` skills; each `SKILL.md` needs a `name` in its frontmatter (optional `description`) |
| `tools` | `["edit", "read", "bash"]` | which tools the model sees |
| `customProviders` | `[]` | in-tree provider definitions |
| `programStatus` | `false` | report agent state to the terminal with OSC 7501 |
| `herdr` | `false` | report agent state to a Herdr pane; only active inside one (`HERDR_ENV=1` with `HERDR_BIN_PATH` and `HERDR_PANE_ID`) |
| `snapshotIgnoreDirs` | `[]` | directory names skipped when the `bash` tool snapshots the cwd for diffs |
| `snapshotUsesGitignore` | `true` | also skip paths matched by the `.gitignore` files under the cwd when snapshotting |
| `historySize` | `100` | past inputs kept in `<state dir>/mini-coding-agent/history` for `Shift+Up`/`Shift+Down` and `Ctrl+R` |
| `maxDiffLines` | `2000` | diffs longer than this render as a "too large" notice instead of highlighting every line |

Unknown keys are rejected. `provider` and `model` must both be set to make a
request; a custom provider must list the model in its `models`. Config errors
name the file and the parser message, then exit 1. A `-c` file must exist.
Saving rewrites the file through a `.tmp` sibling and a rename.

A `customProvider` field:

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | the id `provider` selects |
| `name` | no | display name; falls back to `id` |
| `models` | yes | non-empty list of model objects |
| `envKeys` | no | environment variables searched, in order, for the API key; with none the provider is always usable |
| `headers` | no | extra request headers |

A `customProvider` model object; every model carries its own wire and metadata,
so one provider may mix APIs and base URLs:

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | the id `model` selects |
| `name` | no | display name; falls back to `id` |
| `api` | yes | one of `openai-completions`, `openai-responses`, `anthropic-messages`, `google-generative-ai` |
| `baseUrl` | yes | request base URL |
| `context` | yes | context window in tokens |
| `maxOutput` | yes | maximum output tokens |
| `images` | yes | whether the model accepts image input |
| `reasoning` | yes | whether the model reasons |
| `effort` | no | accepted thinking levels; empty means the full ladder |
| `cost` | yes | `[input, output, cache-read]` USD per million tokens |

## Environment

The built-in providers are named, keyed and described by the embedded models.dev
document. `opencode` and `opencode-go` read the first present variable in their
`env` list (`OPENCODE_API_KEY`), and send the session id as
`x-opencode-session`.

Each wire carries its own key header:

| API | Key header | Path |
|---|---|---|
| `openai-completions` | `Authorization: Bearer <key>` | `/chat/completions` |
| `openai-responses` | `Authorization: Bearer <key>` | `/responses` |
| `anthropic-messages` | `x-api-key: <key>`, plus `anthropic-version: 2023-06-01` | `/messages` |
| `google-generative-ai` | `x-goog-api-key: <key>` | `/{model}:streamGenerateContent?alt=sse` under `baseUrl` |

All requests ask for an SSE stream. A built-in provider with no key is left out
of `/provider`, and so is a custom one whose `envKeys` are all unset.

## Sessions

Each session is a directory under `sessionsDir` named
`<timestamp>-<title>-<id>` with a `session.jsonl` inside it. The title is the
first user message slugified to at most 40 characters, else `session`. A header
line opens the log; every message and every model request is then appended and
fsynced. The log is write-only; a write failure stops the turn. `/new` closes
the current log and opens the next one.

A failed model request is never appended: the attempt stays a request line with
no message, so the context holds no error and the next turn resends the same
request instead of a `continue`.
