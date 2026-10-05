# Some notes from reading the code.

> Context: I'm mostly a web engineer, with some backend experience with python, node and go.

Some of my notes might be because of lack of Zig experience.

## Notes

*Issues with pausing and canceling being delayed* - When the user presses either pause or cancel in the TUI, there is no immediate feedback, the visible result only happens at the next step. This is correct for pause, but incorrect for cancel. Cancel means stop right now, pause means pause at the next turn boundary. At some point the two got merged into both waiting for a turn boundary to act. And neither is properly displayed in the TUI status (no `pausing` state, canceling shouldn't exist, it should be immediate, not a state).
~**Comment on line 142 of `src/agent.zig`** - Completely wrong about cancellation and shouldn't be there. Pausing and steering land at turn boundaries, canceling is immediate!~ Comment is gone!
`src/agent.zig` - cancel needs to be checked more often, between each phase. once and before tool calls is not responsive enough.

**resize, width measurements, line wrapping** -  these still behave in suprising ways sometimes, breaking highligting, wrapping at weird limits, stange states after resize.
A definite research about the best approach to a clean rendering method is required.

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

`src/snapshot.zig` - the list of ignored paths is meant to come from the config, not this incomplete hardcoded list.

```json
{
    // ... other fields
    snapshotIgnoreDirs: ["./zig-out", "./.zig-cache"] // list of paths, each line like a gitignore line.
    snapshotUsesGitignore: true, // merges the list above with gitignore, no dupes!
}
```

`src/main.zig` - has some headless concerns mixed into the entry point of the app. Worth considering extracting headless into `src/headless.zig`. Single concern files are easier to make a mental model around.

`src/diff.zig` - We are rendering a whole header with index and divider, just to strip it in the TUI. Seems counter productive.

`src/tui/tui.zig` - This file has a lot of responsibilities, making it very big. Token estimation and commands at least, could be extracted. 

`src/tui/theme.zig` - will eventually grow too much, each theme we add will make that file worse. A refactor for later, since it's ok right now.

# Actions post review

- Address the JSON issues, and it's helpers. Zig does have a good JSON support, we just ignored it and hand rolled ours. We loose some data to show on error messages.

- No more comments, any new comment needs to be worth it's salt.
