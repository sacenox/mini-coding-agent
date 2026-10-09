# User reports

These come from other people using mini. Each report keeps its text and carries
the state we last verified it in.

---

> `waiting for provider` state takes longer and longer as a session progresses

Something is greatly affecting performance, and it gets worse each subsequent turn.
Testes with a fresh session + small prompt and the models answers in miliseconds.

At the same time, same model, same provider, same build, with a context of 6%, turns stay in waiting for provider for over 30 seconds at a time.

using `btop` to monitor usage during these longs waiting for provider show almost no network activity, 0 cpu and 30mb of memory, seems like the process is just idle. But a curl to the same provider/model/key responds immediatly.

Open, not ours. `waiting for provider` covers body build, connect and the
provider's time to first token; the counter next to it keeps running, so the
process is idle on the socket, not stuck in the agent. curl to
opencode-go/deepseek-v4.1-flash: 68k uncached prompt tokens, first token at 2.7s.
The same request in the TUI at 75k tokens (8% of 1M) leaves that state in ~2s.
A curl that "responds immediately" and a fresh session both carry a small prompt.
Pre-fill time at a given context is the provider's, and it grows with the context.

> Ocasional TUI freeze during bash calls.

Several reports of the TUI freezing on some bash calls not all.

Open, not reproduced. Tool output is read with poll() on the turn thread and
streamed to the event queue, so the frame loop keeps running while a command is
alive: a 4M line `seq`, and snapshots of a 71MB tree, both stayed animated at the
capture rate with peak RSS at 61MB. The status line does distinguish the call from
the snapshot that brackets it. A report with the command and cwd would help.
