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
  with a quick "start"/"stop" and a "terminal" button that opens a real
  terminal window running `claude attach <id>` (via Alacritty +
  Omarchy's `TUI.float` app-id) — the same way you'd talk to a member by
  hand, just one click away instead of typing the command yourself. A
  second click on the same member reuses that window (moves it to your
  current workspace and focuses it) instead of opening a duplicate, and
  the window closes itself the moment focus moves anywhere else — no
  keybinding needed to dismiss it, like a quake-style dropdown terminal.
  See "Click-outside-to-close" below for how.
- **Opdrachten (tasks)** — a flat list (not the webapp's drag-and-drop kanban
  board): create one, send it (typed live into the member's session via a
  headless pty), mark it done.
- **Cronjobs** — read-only view of `cron-jobs.json`.
- **Meldingen** — a desktop notification (`omarchy-notification-send`) + a
  chime + a blink (the bar icon and that member's own roster row) for a
  task reply/done, a member's own final answer once it's actually
  finished, or a question (`AskUserQuestion`) it's waiting on you for —
  see "Standalone message detection" below for exactly which of those
  apply where. Suppressed only when that specific member's own terminal
  window (opened via the panel's "terminal" button) currently has focus —
  you're already looking at it. Checked every 15s, independently of
  whether the panel is open. The chime has its own on/off switch next to
  the "MELDINGEN" header (`~/.config/omarchy/legion-settings.json`,
  `{"soundEnabled": ...}`) — the desktop toast and blink stay on
  regardless, only the sound is affected.
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

**2. "Vraag of antwoord" notifications — a member's actual final answer, or
a question it's waiting on you for.** This one only fires for boss, or for
a member whose "legion:<name>" terminal you currently have open yourself
(`should_notify_member`) — a member worked purely through boss/tasks relay
has no such window, and stays covered by job 1's own notification instead
of also notifying separately for the same exchange (that's the "ik krijg
gewoon een melding via jou" case).

A `type:"assistant"` text entry is trickier than it looks: a single turn
can emit several of those — short "doing X now" updates alongside tool
calls — before the real final answer, and only that last one is worth a
notification. Text and a tool call are never in the same transcript entry
here, so text presence alone can't tell them apart. The first approach
tried was structural — confirm a candidate final answer only once a
*following* turn started — but that meant only finding out a member was
done after Remco had already typed his next message to it, one turn too
late for "let me know when you're finished" (reported directly, and
reproducible). What actually works: a text-only assistant entry is held as
an unconfirmed candidate (`.pendingAnswers` in the marker, carried across
polls, cleared the moment a tool call follows it since that proves it
wasn't final), and gets turned into a notification the moment that
session's *live* status (`claude agents --json`) reads `idle` while a
candidate is still sitting there unflushed — not a busy→idle *edge*, which
a first attempt used and which missed the flush entirely whenever the
status settled back to idle on an earlier poll than the one whose
transcript scan actually caught the final text (confirmed live: an
answer sat in `.pendingAnswers` indefinitely because no further edge ever
came for it). Checking "idle now" plus "still pending" needs no per-session
status history — `pending` itself is already the "is there anything new"
signal, cleared the instant it flushes, so a session sitting quietly idle
never re-fires.

`AskUserQuestion` is an exception to "a tool call discards the pending
candidate and nothing else happens": it's a `tool_use` block, not text, so
it would otherwise vanish the same way any other tool call does — but it's
unambiguously a "this needs you right now" moment (the turn is blocked
until you answer), arguably the clearest case of "vraag" this whole
feature exists for. It fires its own `kind:"question"` message
immediately, no idle-wait needed, using the question text(s) from its
`input.questions[]`.

Either kind fires a desktop notification, plays a chime, and marks that
member `unseen` (the blink), unless its terminal window currently has
focus (see below). A plain message landing on a session — Remco typing
directly, a task injected via `pty_send`, or a cross-session message
arriving from boss/another peer — never fires this notification on its
own, on any session, boss included: it's either self-inflicted (Remco just
typed or sent it himself) or internal relay traffic already covered by job
1 once the relayed exchange resolves.

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

### Click-outside-to-close

`cmd_terminal_open` in legionctl already dedupes a second click on the same
member (moves the existing "legion:<name>" window to your current
workspace and focuses it — see `find_terminal_window`/`hl.dsp.window.move`
+ `hl.dsp.focus`, the same Lua dispatch API the focus check above relies
on). Making it disappear on its own works the other way round, from
Panel.qml: `openTerminalFor()` starts a one-shot 1.8s timer (a freshly-
launched window isn't mapped yet the instant the open call returns,
confirmed live), then asks `legionctl terminal find NAME` for that
window's address and starts watching Quickshell's `Hyprland.activeToplevel`
for the plugin's own moves; the moment the active window's address stops
matching the tracked one — click elsewhere, another window, another
workspace — `legionctl terminal close NAME` closes it (a graceful
`hl.dsp.window.close`, not a kill; detaching `claude attach` this way
never stops the underlying session, same as Ctrl-]). One thing worth
knowing if you ever touch this: `Hyprland.activeToplevel.address` (via
Quickshell.Hyprland) omits the `0x` prefix that `hyprctl clients -j` (and
so `legionctl`'s own address lookups) includes — confirmed live, address
comparisons here normalize both sides or they'd never match even for the
same window.

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
