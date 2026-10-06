```
mini-coding-agent on  main via ↯ took 43s
❯ zig build
./build.zig.zon:24:20: error: unable to unpack git files: NotACommit
            .url = "git+https://github.com/tree-sitter/tree-sitter-python?ref=v0.25.0#d326e4cad262cf681656e130960e49dfc04c03ea",
                   ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
./build.zig.zon:28:20: error: unable to unpack git files: NotACommit
            .url = "git+https://github.com/tree-sitter/tree-sitter-go?ref=v0.25.0#6048bfc6e5238eaf062c2221bd934489c39fbb61",
                   ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

mini-coding-agent on  main via ↯ v0.17.0 took 37s
```
Seems like zig 0.17.x on mac is not building.
