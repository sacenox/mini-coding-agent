# Code/memory quality notes

- No leak detection: `gpa` is never `deinit`'d, so `DebugAllocator` leak reports never fire. Leaks would be silent.
- **libc `regcomp` into a `[512]u8` opaque buffer** for tree-sitter `match?` predicates — clever but fragile and ABI-shaped.
- `tools.json` / `filesystem.listDir` have deeply nested `catch return out.written()` / `catch &.{}` chains — hard to read.
- `platform.printErr` heap-allocates per message instead of a stack `[512]u8` buffer.

# Bugs

`opencode-go/claude-haiku-5-5 · low` fails to stream:

```json
{"type":"error","error":{"type":"invalid_request_error","message":"Upstream request failed: [invalid_request_error] \"thinking.type.enabled\" is not supported for this model. Use \"thinking.type.adaptive\" and \"output_config.effort\" to control thinking behavior."}}
```
