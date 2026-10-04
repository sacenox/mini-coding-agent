# Issues from QA/Live use

- ~~No user-agent is sent, this is explicit against Opencode Go and many other providers rules. Start sending `mini-coding-agent/VERSION`~~
- Audit statusline states, I never see "waiting for provider". Seems that we don't have that much granularity
- `authFile` in config is a fragment of mini-coder's functionality that we don't have, why was it ported without thinking?
- Agents use markdown tables in their replies, and usually with terrible whitespace, can we format them for readability?
- thinking effort selection doesn't trigger on model selection like it does in mini-coder. since we clamp thinking to the model's
  options, this is required, it's why mini-coder does it.

# Improvements

- Pending/Running bash tool calls: Currently the user only sees the status line "running bash...". The user only sees the arguments
  once the tool call completes. We need to add a new section to the live area when there are tool calls waiting for tool results,
  that display the arguments. This enables the user to see that a bad bash command was sent and can stop it, right now it's a guess
  when something is taking too long.
- Read tool bodies aren't useful. Instead we should show a single line body, with the read tool call arguments and the count of lines read.
  Users can already see the full path in the tool header. If it's an image we show the path twice, thats is not needed, let's just show the
  image metadata in the single line body to match the new behaviour suggested here.
- Add to the banner a second line, that shows the count of AGENTS.md files loaded and the SKILL.md files loaded.
- When we start a new session, print a blank line, the banner, and then the "new session" label but dimmed.
