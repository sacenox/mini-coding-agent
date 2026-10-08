# User reports

These come from other people using mini

---

> High frequency of errors using muse models.

More than one person said they kept getting `! stream read failed`, over and over. I was able to reproduce it with muse-1.3

> Editor area is unstyled/uses the host terminal colors.

I've confirmed this in our stress script runs screenshots.  We keep having issues with background coverage regressions, we need to pay attention to this when doing TUI runs during verification. Looking at the text output is clearly not working.

> Ocasional TUI freeze during bash calls.

Several reports of the TUI freezing on some bash calls not all.
