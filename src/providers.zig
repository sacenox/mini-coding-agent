// Built-in providers. Adding a provider is adding an entry here.

const std = @import("std");

pub const OAuth = struct {
    // The dynamic-registration entrypoint, used until an issued client id is
    // returned by the callback and stored.
    client_id: []const u8,
    app_name: []const u8,
    authorize_url: []const u8,
    token_url: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
    resource: []const u8,
    // The granted scope without which the plan usage flow cannot infer.
    required_scope: ?[]const u8 = null,
};

pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    api: []const u8,
    base_url: []const u8,
    env_keys: []const []const u8 = &.{},
    session_header: ?[]const u8 = null,
    listing: ?[]const u8 = null,
    // Appended to the listing request as `client_version` when set.
    client_version: ?[]const u8 = null,
    models_dev_id: ?[]const u8 = null,
    // Whether the request may carry a max-output-tokens parameter.
    sends_max_output: bool = true,
    oauth: ?OAuth = null,
};

pub const builtins = [_]Provider{
    .{
        .id = "opencode",
        .name = "OpenCode Zen",
        .api = "openai-completions",
        .base_url = "https://opencode.ai/zen/v1",
        .env_keys = &.{"OPENCODE_API_KEY"},
        .session_header = "x-opencode-session",
        .listing = "https://opencode.ai/zen/v1/models",
        .models_dev_id = "opencode",
    },
    .{
        .id = "opencode-go",
        .name = "OpenCode Go",
        .api = "openai-completions",
        .base_url = "https://opencode.ai/zen/go/v1",
        .env_keys = &.{"OPENCODE_API_KEY"},
        .session_header = "x-opencode-session",
        .listing = "https://opencode.ai/zen/go/v1/models",
        .models_dev_id = "opencode-go",
    },
    .{
        .id = "chatgpt",
        .name = "ChatGPT",
        .api = "openai-responses",
        .base_url = "https://api.openai.com/v1",
        .listing = "https://api.openai.com/v1/models",
        .models_dev_id = "openai",
        .sends_max_output = false,
        .oauth = .{
            .client_id = "dynamic_agent_client",
            .app_name = "mini",
            .authorize_url = "https://auth.openai.com/api/accounts/authorize",
            .token_url = "https://auth.openai.com/api/accounts/oauth/token",
            .redirect_uri = "http://127.0.0.1:1455/auth/callback",
            .scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            .resource = "https://api.openai.com/v1",
            .required_scope = "chatgpt.tokens.use.direct",
        },
    },
};

pub fn find(id: []const u8) ?*const Provider {
    for (&builtins) |*p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}
