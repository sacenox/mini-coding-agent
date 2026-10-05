# Some notes from reading the code.

> Context: I'm mostly a web engineer, with some backend experience with python, node and go.

Some of my notes might be because of lack of Zig experience.

## Notes

`src/session.zig` - I was surprised to see such an awkward syntax format to creating/encoding json. Is this normal for zig? It's hard to read. Is there no `toJSON` type of thing? So we could then write that?

`src/json.zig` -  Similar to the session comment, I'm surprised at how cumbersome it is to deal with JSON.

`src/main.zig` - has some headless concerns mixed into the entry point of the app. Worth considering extracting headless into `src/headless.zig`. Single concern files are easier to make a mental model around.

`src/diff.zig` - We are rendering a whole header with index and divider, just to strip it in the TUI. Seems counter productive.

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


*Issues with pausing and canceling being delayed* - When the user presses either pause or cancel in the TUI, there is no immediate feedback, the visible result only happens at the next step. This is correct for pause, but incorrect for cancel. Cancel means stop right now, pause means pause at the next turn boundary. At some point the two got merged into both waiting for a turn boundary to act. And neither is properly displayed in the TUI status (no `pausing` state, canceling shouldn't exist, it should be immediate, not a state).
**Comment on line 142 of `src/agent.zig`** - Completely wrong about cancellation and shouldn't be there. Pausing and steering land at turn boundaries, canceling is immediate!
`src/agent.zig` - cancel needs to be checked more often, between each phase. once and before tool calls is not responsive enough.

`src/api.zig` and `src/config.zig` (possibly more) - I keep seeing the same helpers everywhere, `numField`, `stringField/strField`, `objField`. These exist in multiple files, it's ridiculous, it's an affront to the golden rule of less code. Just grepping the pattern shows the abuse of copy paste like approach.

```bash
❯ rg "fn .+Field"
src/api.zig
308:pub fn optNumField(obj: std.json.ObjectMap, key: []const u8) ?u64 {
317:pub fn numField(obj: std.json.ObjectMap, key: []const u8) u64 {
322:pub fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
331:pub fn objField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
340:pub fn firstObjField(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
365:pub fn boolField(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {

src/config.zig
77:fn strField(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, path: []const u8) !?[]const u8 {
85:fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
```

**Comments** - Being used randomly without thought, most of them re-state the code they near and add absolutely no value. As we saw above with canceling, they are introducing bugs and having a negative impact. We have a rule about comments, it's time to enforce it repo-wide, before these low quality comments cause more damage.

`src/snapshot.zig` - the list of ignored paths is meant to come from the config, not this incomplete hardcoded list.

`src/tui/editor.zig` - `pub fn render2` seriously? Where is render1? Naming is important and this is unacceptable.

`src/tui/tui.zig` - This file has a lot of responsibilities, making it very big. Token estimation and commands at least, could be extracted. 

`src/tui/theme.zig` - will eventually grow too much, each theme we add will make that file worse. A refactor for later, since it's ok right now.
