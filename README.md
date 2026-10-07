# tmux-agent-status

Sidebar-first AI agent session manager for tmux. It gives each tmux session a persistent status sidebar, keeps a compact summary in the status line, and adds a hierarchical `fzf` target switcher for fast jumps and cleanup across agent sessions, windows, and panes.

Claude Code and Codex CLI are both integrated through hooks, so their states come from agent lifecycle events rather than fragile process polling. Custom agents can still integrate through status files or collector extensions.

[![tmux-agent-status demo screenshot](demo/full.png)](demo/full.mp4)

Demo video: [`demo/full.mp4`](demo/full.mp4)

## Features

- Persistent sidebar in every tmux session
- Hierarchical `fzf` target switcher for quick jumps and close actions
- Hook-based Claude Code and Codex tracking
- Wait mode for triaging work
- Pinned status-line watchlist with finish notifications
- Works across multi-pane sessions, worktrees, and remote tmux sessions

## Supported Agents

| Agent | Integration | Status |
|-------|-------------|--------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Hook-based via `hooks/better-hook.sh` | Stable |
| [Codex CLI](https://github.com/openai/codex) | Hook-based via `hooks/codex-hook.sh` | Stable in plugin, hooks still experimental upstream |
| [Devin CLI](https://docs.devin.ai/cli) | Hook-based via `hooks/devin-hook.sh` (local CLI only) | Stable in plugin |
| Custom (Aider, Cline, Copilot CLI, etc.) | Status files or collector extensions | Stable |

All agent sessions can run simultaneously across tmux sessions and panes, each tracked independently.

## Install

With [TPM](https://github.com/tmux-plugins/tpm):

```bash
set -g @plugin 'samleeney/tmux-agent-status'
```

Then press `prefix + I` to install.

On macOS, install a modern Bash before using the sidebar:

```bash
brew install bash
```

The plugin auto-detects Homebrew Bash at `/opt/homebrew/bin/bash` or `/usr/local/bin/bash` when macOS launches scripts with the system Bash 3.2.
If Bash is installed somewhere else, set `TMUX_AGENT_STATUS_BASH` to that path.

By default the plugin:

- Appends the live summary to `status-right`
- Starts the sidebar collector daemon
- Auto-creates a sidebar in existing and new tmux sessions
- Binds the popup switcher, wait, and next-ready actions

## Claude Code Setup

Add hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh Stop"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh Notification"
          }
        ]
      }
    ]
  }
}
```

Claude Code state is tracked entirely through hooks, so the plugin gets precise working/done transitions directly from the agent. If a turn ends while a background task is still running (e.g. a `run_in_background` Bash command), the `Stop` payload's `background_tasks` array keeps the session marked `working` until a later `Stop` reports the task finished — so backgrounded work doesn't show a premature green checkmark.

## Codex CLI Setup

tmux-agent-status supports official [Codex hooks](https://developers.openai.com/codex/hooks).

Enable hooks in `~/.codex/config.toml`:

```toml
[features]
hooks = true
```

For a one-off session, you can also start Codex with `codex --enable hooks`.

To enable Codex tracking globally, add `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/codex-hook.sh SessionStart"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/codex-hook.sh UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/codex-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/codex-hook.sh Stop"
          }
        ]
      }
    ]
  }
}
```

Restart Codex, then run `/hooks` in the CLI and trust the new command hooks if Codex marks them as pending review. Non-managed command hooks must be trusted before Codex will run them.

Codex state is also hook-based. The handler marks the tmux session or pane `working` on `UserPromptSubmit` and `PreToolUse`, resets it to `done` on `Stop`, and seeds resumed sessions on `SessionStart`.

For repo-local tracking while working on this plugin, put the same hook shape in `<repo>/.codex/hooks.json`. Codex loads project-local hooks once the project `.codex/` layer is trusted.

## Devin CLI Setup

This integrates the local [Devin CLI](https://docs.devin.ai/cli) (the `devin` binary that runs in your terminal), not cloud Devin sessions. The Devin CLI uses a [Claude Code-compatible hooks format](https://docs.devin.ai/cli/extensibility/hooks/overview).

Add hooks to `~/.config/devin/config.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/devin-hook.sh SessionStart"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/devin-hook.sh UserPromptSubmit"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/devin-hook.sh PreToolUse"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/devin-hook.sh PostToolUse"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.config/tmux/plugins/tmux-agent-status/hooks/devin-hook.sh Stop"
          }
        ]
      }
    ]
  }
}
```

Run `/hooks` in the CLI to confirm the command hooks are loaded, and trust them if Devin marks them as pending review.

Devin state is hook-based. The handler marks the session or pane `working` on `UserPromptSubmit`/`PreToolUse`/`PostToolUse`, resets it to `done` on `Stop`, and seeds resumed sessions on `SessionStart`.

Without hooks, the collector still auto-detects a running `devin` process inside a pane (presence only); hooks are required for live `working`/`done` state.

## Custom Agent Integration

Integrate any AI coding tool with either of these approaches:

1. Write `working`, `done`, or `wait` to `~/.cache/tmux-agent-status/<session>.status`
2. For per-pane state, write to `~/.cache/tmux-agent-status/panes/<session>_<pane>.status`
3. Extend the collector scan in [`scripts/lib/collect.sh`](scripts/lib/collect.sh) if you want automatic process-based tracking

## Usage

Default mode is sidebar-first:

- Every tmux session gets a sidebar pane automatically
- `prefix + S` opens the hierarchical `fzf` target switcher
- `prefix + o` focuses or creates the sidebar in the current window

| Key | Action |
|-----|--------|
| `prefix + S` | Open the hierarchical `fzf` target switcher |
| `prefix + o` | Focus or create the sidebar |
| `prefix + N` | Jump to the next inbox item in inbox order |
| `prefix + W` | Put the current session or pane into timed wait mode |

The status bar is a watchlist: it shows the agents you pinned, each as a
short tag coloured by state, and collapses everything else into one counter.

```text
bug  rfc✓  perf?   ·6
```

| State | Tag |
|-------|-----|
| working | yellow, bold, bare |
| waiting | cyan, bare |
| ask | magenta, bold, `?` |
| done | green, `✓` |
| pane gone | muted (bright black), bare |

Tags are assigned when you pin (`ctrl-i` in the switcher's agents view), are
1-4 characters, must be unique, and keep the order you pinned them in — the
bar is never re-sorted, so where a tag sits is part of how you read it.
Nothing on the bar varies with time: no durations and no animation, so a
glance costs nothing when nothing has changed. Age lives in the picker
instead.

The trailing `·N` counts the agents you did not pin. It is muted normally
and takes the ask colour when one of them is asking, so an opt-in watchlist
cannot quietly lose an agent that is blocked on you. A finished agent does not
light it: done is the resting state, so with several agents something
unpinned is nearly always done.

When a pinned pane dies, its pin is dropped if the agent had finished, and
otherwise held in the muted colour until you unpin it. Pins last as long as
the tmux server and are not written to disk: pane ids are recycled across
restarts, and a saved pin would latch onto an unrelated pane.

The colours follow your theme through five options (see
[Configuration](#configuration)). A value can be a plain colour or a tmux
format such as `#{@base0A}`; it is expanded every time the bar is rebuilt, so
a theme switch recolours the bar within about ten seconds. An option that is
unset or expands to nothing uses the default.

Inside the popup switcher:

- `Enter` switches to the selected session, window, or pane
- `Ctrl-I` (`Tab`) expands or collapses the selected session or window in tree view, and pins in agents view
- `Ctrl-P` shows or hides the preview pane
- `Ctrl-X` closes the selected pane immediately
- `Ctrl-X` on a window immediately closes that window and all child panes
- `Ctrl-X` on a session immediately closes that session and all child windows and panes
- `Ctrl-W` opens wait mode for the selected target, or cancels an existing wait
- `Ctrl-R` resets tracked state

In the agents view, `Ctrl-I` opens a prompt prefilled with the row's tag, or
a tag derived from its window name when the row is unpinned: the first three
characters, or the first free of those plus 2-9 (`wor`, `wor2`, `wor3`) when
another agent already holds it. Entering text pins or renames; entering
nothing unpins; a tag another agent already holds is rejected.

Inside the sidebar:

- `x` and `w` perform the same close and wait actions without interfering with popup search input

`prefix + N` follows the same top-to-bottom order as the `INBOX` section. The inbox is ordered by session name, then by tmux window order within each session.

Waiting and closing always apply to the selected scope only:

- selecting a session row affects the whole session
- selecting a window row affects only that window
- selecting a pane row affects only that pane

In multi-window sessions, sidebar and inbox rows labeled with a window name operate on that window, not just the first pane inside it.

## Configuration

```tmux
set -g @agent-status-key "S"
set -g @agent-sidebar-key "o"
set -g @agent-next-done-key "N"
set -g @agent-wait-key "W"

set -g @agent-switcher-style "both"        # popup | sidebar | both
set -g @agent-status-display-method "popup" # popup | window
set -g @agent-sidebar-width "42"

# Switcher view (prefix + S). "tree" is the hierarchical
# session/window/pane list (default). "agents" is a flat list of every
# agent pane sorted by status. Toggle mid-session with ctrl-f.
set -g @agent-switcher-default-mode "tree"  # tree | agents

# Status bar colours. Plain colours or tmux formats (expanded at render time).
set -g @agent-status-color-working "yellow"     # bold
set -g @agent-status-color-ask     "magenta"    # bold; also the lit ·N count
set -g @agent-status-color-done    "green"
set -g @agent-status-color-wait    "cyan"
set -g @agent-status-color-muted   "brightblack" # ·N count and dead pins
# e.g. with a base16 theme that exports its palette as user options:
# set -g @agent-status-color-working "#{@base0A}"
```

`@agent-switcher-style "both"` is the default. It keeps the persistent sidebar and leaves `prefix + S` as the lightweight popup switcher.

The switcher popup has two views. **Tree** (default) is the hierarchical session/window/pane list; `ctrl-i` expands/collapses. **Agents** is a flat list of every agent pane (any status) sorted by priority — `ask`, `done`, `working`, `wait` — with a tag column, the age of each agent's current state, a live preview pane, and 2-second refresh. The tag column is blank for unpinned agents, so it doubles as the pin indicator. Press `ctrl-f` inside the popup to toggle between views.

The sidebar has the same two views, toggled with `m` from inside the sidebar pane (alongside `w`/`x` for wait/close). In **tree** mode the SESSIONS section lists every session and collapses single-agent sessions to one row; the INBOX section surfaces `done`/`ask` work. In **agents** mode the SESSIONS section is filtered to sessions/worktrees that contain agent panes and every agent pane is expanded; INBOX is suppressed because it would duplicate the same rows.

## Notification Sounds

Play a sound when an agent finishes:

```tmux
set -g @agent-notification-sound "chime"
```

Options: `chime` (default), `bell`, `fanfare`, `frog`, `speech`, `none`.

## Multi-Agent Deploy

Launch parallel AI coding sessions with isolated git worktrees:

```bash
bash ~/.config/tmux/plugins/tmux-agent-status/scripts/deploy-sessions.sh manifest.json
```

Each session gets a `deploy/<name>` branch, and the plugin tracks the spawned sessions automatically.

## SSH Remote Sessions

Monitor AI agents on remote machines:

```bash
./setup-server.sh <session-name> <ssh-host>
```

Works with cloud VMs, GPU boxes, and any SSH-accessible tmux host.

## How It Works

```text
┌──────────────┐    hooks     ┌──────────────────────────┐
│ Claude Code  ├─────────────►│ ~/.cache/tmux-agent-     │
└──────────────┘              │ status/                  │
                              │ <session>.status         │
┌──────────────┐    hooks     │ panes/*.status           │
│ Codex CLI    ├─────────────►│ wait/*.wait              │
└──────────────┘              └─────────────┬────────────┘
┌──────────────┐ status files               │
│ Custom agent ├────────────────────────────┘
└──────────────┘
                                            ▼
                              ┌──────────────────────────┐
                              │ sidebar-collector.sh     │
                              │ writes shared cache and  │
                              │ status summary           │
                              └─────────────┬────────────┘
                                            │
                         ┌──────────────────┼──────────────────┐
                         ▼                  ▼                  ▼
                 ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
                 │ sidebar pane │   │ status line  │   │ fzf switcher │
                 └──────────────┘   └──────────────┘   └──────────────┘
```

- Claude Code support is hook-based
- Codex CLI support is hook-based
- Custom agents can be file-based or process-detected
- The sidebar is the main live view; the `fzf` switcher is the quick jump and close tool

## License

MIT
