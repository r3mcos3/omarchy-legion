# Legion

A native Omarchy bar panel for the [claude-legion](https://github.com/r3mcos3/claude-legion)
coordinator setup — a personal-use alternative to the dashboard webapp.
Runs fully standalone, including bootstrapping the legion from cold: no
HTTP request to the webapp anywhere, and nothing it does — starting
sessions, detecting replies, notifying — needs the webapp running.
`session-start-hook.sh` in claude-legion no longer auto-starts the webapp
either, precisely because this plugin replaces that need. It shares
`members.json` / `tasks.json` / `cron-jobs.json` as plain files with the
webapp when it happens to be running too (started by hand — `cd dashboard
&& node server.js`), purely so either interface reflects changes made
through the other — that's a convenience, not a dependency.

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
- **Meldingen** — a desktop notification (`omarchy-notification-send`) + a
  chime + a blink (the bar icon and that member's own roster row) for
  basically every "vraag of antwoord" in any session: a task reply/done,
  but also a plain question landing on a member (typed by hand, or a
  cross-session message) and that member's own text answer — deliberately
  broad, see "Standalone message detection" below. Suppressed only when
  that specific member's own terminal window (opened via the panel's
  "terminal" button) currently has focus — you're already looking at it.
  Checked every 15s, independently of whether the panel is open. The chime
  has its own on/off switch next to the "MELDINGEN" header
  (`~/.config/omarchy/legion-settings.json`, `{"soundEnabled": ...}`) —
  the desktop toast and blink stay on regardless, only the sound is
  affected.
- **Verbruik** — 5h/7d rate-limit percentage from
  `~/.claude/usage-cache.json`, with exact reset times on hover.
- **Lid toevoegen** — name + absolute workspace path (mkdir, sets
  `worktree.bgIsolation: none`, starts the session).
- **Start alles** — a header button next to the roster that bootstraps the
  whole legion from cold: starts boss if it isn't running (its own
  `session-start-hook.sh` then brings up the fixed five + any dynamic
  members, same as it always has), or — if boss is already up — directly
  restarts whichever fixed/dynamic member isn't currently online. No
  terminal, no `start-sessions.sh` by hand, no webapp needed for this either.

## Standalone message detection

Every known session (boss + fixed + dynamic) has its own transcript
(`~/.claude/projects/<cwd>/<sessionId>.jsonl`), polled independently, each
with its own incremental byte offset persisted in
`~/.config/omarchy/legion-notify-marker.json` (seeded at end-of-file the
first time a given transcript path is seen, so it never replays years of
history as "new" — and re-seeds the same way if a session's transcript file
changes, e.g. after a restart). Two things come out of that one scan:

**1. Task-reply detection** (this used to be the webapp's job, via
`advanceTasksOnReply` polling **boss's own transcript** for a message
landing back from a member). A reply sent via `SendMessage` shows up there
in one of a few shapes depending on timing:

- a plain `type:"user"` entry whose string content wraps a
  `<cross-session-message from-name="X">...</cross-session-message>` tag —
  the common case;
- a structured `type:"attachment"` entry whose `attachment.origin.kind` is
  `"peer"` — including the `queued_command`-flavored attachment a message
  arriving *mid-turn* gets absorbed into (confirmed against a real
  `SendMessage` reply landing while boss was mid-tool-call — the detection
  doesn't care about `attachment.type`, only `origin.kind`, so this shape
  needed no special-casing).

Finding one advances the oldest `in_progress` task for that member to
`approved_questions` and fills in `.reply` — same rule as the webapp (a
member works one task at a time).

**2. "Vraag of antwoord" notifications — a question landing on a member, or
its actual final answer.** A `type:"user"` entry (a prompt someone typed at
that member, or a cross-session message addressed to it) fires immediately.
A `type:"assistant"` text entry is trickier: a single turn can emit several
of those — short "doing X now" updates alongside tool calls — before the
real final answer, and only that last one is worth a notification. Text and
a tool call are never in the same transcript entry here, so text presence
alone can't tell them apart; what can is whether another assistant entry
(necessarily a tool call, since that's the only thing that follows a
mid-turn update) comes next, or the turn instead hands back to a real
user/peer entry. So an assistant text candidate is held (`.pendingAnswers`
in the marker, carried across polls) and only turned into a notification
once a later poll confirms — a genuine next turn started — that it was
never followed by more tool activity; a tool call arriving instead just
discards it, no notification. A tool-result-only `user` entry (the
mechanical feedback loop, not a real turn) confirms nothing either way.

One tool call is an exception to "a tool call discards the pending
candidate and nothing else happens": `AskUserQuestion`. It's a `tool_use`
block, not text, so it would otherwise vanish the same way any other tool
call does — but it is unambiguously a "this needs you right now" moment
(the turn is blocked until you answer), arguably the clearest case of
"vraag" this whole feature exists for. It fires its own `kind:"question"`
message immediately, no confirm-on-next-turn wait, using the question
text(s) from its `input.questions[]`.

Either kind fires a desktop notification, plays a chime, and marks that
member `unseen` (the blink), unless its terminal window currently has
focus (see below). Two things never fire this way for boss specifically:
its own peer-origin replies (job 1 above already gives those a nicer,
task-specific notification), and a plain message straight from Remco —
that's just this conversation, and there's no point notifying him about
something he only just typed. Everything else, including boss's own final
answer to you in chat, goes through this path.

### Focus check

A member's terminal only counts as "in beeld" if it's the currently
*focused* window (`hyprctl activewindow -j`), matched by `initialTitle`
rather than the live `title` — Alacritty's `--title` sets the title once at
launch, but the program running inside it (the shell, `claude attach`) can
rewrite the live title afterward, while Hyprland's `initialTitle` stays
exactly what it was at window-map time. `openTerminalFor()` in Panel.qml
passes `--title "legion:<name>"` for this reason; a `claude attach` window
opened any other way has no matching title and is simply never treated as
"that member is on screen". No matching window, or no `hyprctl` at all,
both mean "not focused" — the safe default is to notify.

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
