# User reports

These come from other people using mini

---

> `waiting for provider` state takes longer and longer as a session progresses

Something is greatly affecting performance, and it gets worse each subsequent turn.
Testes with a fresh session + small prompt and the models answers in miliseconds.

At the same time, same model, same provider, same build, with a context of 6%, turns stay in waiting for provider for over 30 seconds at a time.

using `btop` to monitor usage during these longs waiting for provider show almost no network activity, 0 cpu and 30mb of memory, seems like the process is just idle. But a curl to the same provider/model/key responds immediatly.

> High frequency of errors using muse models.

More than one person said they kept getting `! stream read failed`, over and over. I was able to reproduce it with muse-1.3

> Ocasional TUI freeze during bash calls.

Several reports of the TUI freezing on some bash calls not all.

> Editor area is unstyled/uses the host terminal colors.

I've confirmed this in our stress script runs screenshots.  We keep having issues with background coverage regressions, we need to pay attention to this when doing TUI runs during verification. Looking at the text output is clearly not working.
