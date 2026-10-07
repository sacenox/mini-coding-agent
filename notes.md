# Some notes from reading the code.

> Context: I'm mostly a web engineer, with some backend experience with python, node and go.

Some of my notes might be because of lack of Zig experience.
These are **my** notes. Use your own file for your notes...

## Notes

**weird rendering when deleting characters** in the editor when line wrapping/multiline is involved. Hard to repro consistently, but when a editor is multiline deleting a word across lines, breaks in weird ways.

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

**`src/main.zig` - has some headless concerns mixed into the entry point of the app. Worth considering extracting headless into `src/headless.zig`. Single concern files are easier to make a mental model around.

`src/diff.zig` - We are rendering a whole header with index and divider, just to strip it in the TUI. Seems counter productive.

`src/tui/tui.zig` - This file has a lot of responsibilities, making it very big. Token estimation and commands at least, could be extracted. 

`src/tui/theme.zig` - will eventually grow too much, each theme we add will make that file worse. A refactor for later, since it's ok right now.
