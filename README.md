# Legion

A native Omarchy bar panel for the [claude-legion](https://github.com/r3mcos3/claude-legion)
coordinator setup — a personal-use alternative to opening the dashboard
webapp in a browser tab. The webapp keeps running independently; this panel
reads and writes the same `members.json` / `tasks.json` / `cron-jobs.json` /
`log-history.json` files it does, so either interface reflects changes made
through the other.

Not intended for the Omarchy plugin marketplace — this is tied to one
specific personal legion setup (fixed session names, workspace paths,
`start-sessions.sh` conventions), not something a general Omarchy user could
install and get value from.

## What it shows

- **Roster** — every legion member (boss + fixed + dynamic), online/offline,
  with a quick "start"/"stop" and an "terminal" button that opens a real
  terminal window running `claude attach <id>` (via
  `omarchy-launch-terminal`) — the same way you'd talk to a member by hand,
  just one click away instead of typing the command yourself.
- **Opdrachten (tasks)** — a flat list (not the webapp's drag-and-drop kanban
  board): create one, send it (typed live into the member's session via a
  headless pty, same mechanism the webapp's own terminal tab uses), mark it
  done.
- **Cronjobs** — read-only view of `cron-jobs.json`.
- **Meldingen** — tails the webapp's own `log-history.json`, so it shows the
  same notification feed without re-implementing any of the transcript-diffing
  logic that produces it.
- **Meldingen (proactief)** — a real desktop notification (via
  `omarchy-notification-send`, clickable to open the panel) plus a badge on
  the bar icon, fired when a task you sent flips out of `in_progress` (the
  webapp's own reply-detection advances it to `approved_questions`, or it's
  marked done by hand in either UI). This is *not* the same signal the
  webapp's own chime uses — that's an ephemeral in-memory broadcast over its
  websocket to connected browser tabs, never written to disk, so a
  file-polling plugin like this one has no way to observe it after the
  fact. Task-status transitions in the shared `tasks.json` are a
  file-based proxy for the same "a member is done" moment, checked every
  15s regardless of whether the panel is open.
- **Verbruik** — 5h/7d rate-limit percentage from
  `~/.claude/usage-cache.json`, with exact reset times on hover.
- **Lid toevoegen** — name + absolute workspace path; mirrors the webapp's
  `/api/members` behavior (creates the folder, sets
  `worktree.bgIsolation: none`, starts the session).

## What it deliberately does NOT do

- Auto-restart-with-backoff supervision for crashed members — that stays the
  webapp's job (it's already running, this panel doesn't duplicate it).
  This panel's roster is a fresh `claude agents --json` snapshot each poll,
  not the webapp's richer crash-history tracking.
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
