# Legion

A native Omarchy bar panel for the [claude-legion](https://github.com/r3mcos3/claude-legion)
coordinator setup — a personal-use alternative to opening the dashboard
webapp in a browser tab. Runs fully standalone: it doesn't call the webapp
at all (no HTTP request to it anywhere), and doesn't need it running for
anything, including the reply-detection that drives the blink (see
"Standalone reply detection" below). It shares `members.json` / `tasks.json`
/ `cron-jobs.json` as plain files with the webapp when it happens to be
running too, purely so either interface reflects changes made through the
other — that's a convenience, not a dependency.

Not intended for the Omarchy plugin marketplace — this is tied to one
specific personal legion setup (fixed session names, workspace paths,
`start-sessions.sh` conventions), not something a general Omarchy user could
install and get value from.

## What it shows

- **Roster** — every legion member (boss + fixed + dynamic), online/offline,
  with a quick "start"/"stop" and an "terminal" button that opens a real
  terminal window running `claude attach <id>` (via Alacritty +
  Omarchy's `TUI.float` app-id) — the same way you'd talk to a member by
  hand, just one click away instead of typing the command yourself.
- **Opdrachten (tasks)** — a flat list (not the webapp's drag-and-drop kanban
  board): create one, send it (typed live into the member's session via a
  headless pty), mark it done.
- **Cronjobs** — read-only view of `cron-jobs.json`.
- **Meldingen** — the bar icon (and the specific member's own roster row)
  blinks when a task you sent gets a reply or is marked done, plus a real
  clickable desktop notification via `omarchy-notification-send`. Checked
  every 15s, independently of whether the panel is open — see below for how
  this is detected without the webapp.
- **Verbruik** — 5h/7d rate-limit percentage from
  `~/.claude/usage-cache.json`, with exact reset times on hover.
- **Lid toevoegen** — name + absolute workspace path (mkdir, sets
  `worktree.bgIsolation: none`, starts the session).

## Standalone reply detection

The one piece that used to depend on the webapp actually running: knowing
that a member replied to a task. The webapp's own `advanceTasksOnReply` gets
this from polling that member's transcript for a message landing back in
**boss's own transcript** — so this plugin polls the exact same file boss
already has (`~/.claude/projects/<cwd>/<sessionId>.jsonl`), looking for a
reply arriving via `SendMessage`. That shows up in the transcript in a few
different shapes depending on timing:

- a plain `type:"user"` entry whose string content wraps a
  `<cross-session-message from-name="X">...</cross-session-message>` tag —
  the common case;
- a structured `type:"attachment"` entry whose `attachment.origin.kind` is
  `"peer"` — including the `queued_command`-flavored attachment a message
  arriving *mid-turn* gets absorbed into (confirmed against a real
  `SendMessage` reply landing while boss was mid-tool-call — the detection
  doesn't care about `attachment.type`, only `origin.kind`, so this shape
  needed no special-casing).

Whichever shape it lands in, finding one advances the oldest `in_progress`
task for that member to `approved_questions` and fills in `.reply` — same
rule as the webapp (a member works one task at a time). The scan is
incremental (a byte offset persisted in
`~/.config/omarchy/legion-notify-marker.json`, seeded at end-of-file the
first time a given transcript path is seen so it never replays years of
history as "new"), same shape as the webapp's own delta-polling.

## What it deliberately does NOT do

- Auto-restart-with-backoff supervision for crashed members — that stays the
  webapp's job when it's running. This panel's roster is a fresh
  `claude agents --json` snapshot each poll, not the webapp's richer
  crash-history tracking.
- A real embedded terminal inside the popup — QML/Quickshell has no built-in
  terminal-emulator widget, and building one is an entirely different
  (much larger) project than the rest of this panel. Opening a real terminal
  window instead gets the same practical outcome for a fraction of the
  effort and risk.
- The webapp's full kanban board (drag-and-drop columns, editing a backlog
  card in place, football/weather sidebar cards). Deliberately scoped down to
  view + send + done.

## Files

- `manifest.json` — plugin metadata (bar-widget kind)
- `Panel.qml` — the widget
- `bin/legionctl` — bash helper (+ an embedded python3 pty-injection routine
  for sending a task) that all the QML calls shell out to

## Install

```sh
omarchy plugin add https://github.com/r3mcos3/omarchy-legion.git --enable
```

## Uninstall

```sh
omarchy plugin remove r3mcos3.legion
```

## License

[MIT](LICENSE)
