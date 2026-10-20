#!/usr/bin/env python3
"""Fetches models.dev and writes src/models_dev.json.

The provider decides which models exist (we ask it at runtime); models.dev
decides the wire, base URL and metadata for each model id. Only the providers
this agent can talk to are kept. The output is committed, so a normal
`zig build` needs no network. Run `python3 tools/gen_models_dev.py` to refresh.
"""

import json
import sys
import urllib.request

MODELS_DEV = "https://models.dev/api.json"

PROVIDERS = ["opencode", "opencode-go", "openai"]

# models.dev omits `api` where the AI SDK default applies. Storing it here keeps
# the agent free of per-provider facts: it only ever reads the document.
API_DEFAULTS = {"openai": "https://api.openai.com/v1"}


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "src/models_dev.json"
    req = urllib.request.Request(MODELS_DEV, headers={"User-Agent": "mini-models-dev/1"})
    with urllib.request.urlopen(req) as r:
        data = json.loads(r.read())

    kept = {}
    for pid in PROVIDERS:
        if pid not in data:
            sys.exit("models.dev: provider %r missing" % pid)
        provider = dict(data[pid])
        if not provider.get("api") and pid in API_DEFAULTS:
            provider["api"] = API_DEFAULTS[pid]
        kept[pid] = provider

    with open(out, "w") as f:
        json.dump(kept, f, separators=(",", ":"))
        f.write("\n")
    print("wrote %s (%d providers, %d models)" % (
        out, len(kept), sum(len(p["models"]) for p in kept.values())))


if __name__ == "__main__":
    main()
