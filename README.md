# pty-monitor

macOS monitor for PTY exhaustion caused by [GitHub Copilot CLI](https://github.com/github/copilot-cli) leaking pseudo-terminal file descriptors.

## Problem

Copilot CLI spawns PTY-backed bash sessions via [node-pty](https://github.com/microsoft/node-pty) for each tool invocation but does not close them after completion. This leaks `/dev/ptmx` file descriptors inside the copilot process, exhausting the macOS kernel limit (`kern.tty.ptmx_max`, default 511, max 999).

When the limit is reached, any PTY allocation fails with:

```
exited with error: pty_posix_spawn failed with error: -1 (Unknown error: -1)
```

This breaks Copilot CLI, terminal emulators, SSH sessions, and any other tool that needs a PTY.

**Tracked issues:**
- [github/copilot-cli#677](https://github.com/github/copilot-cli/issues/677) — Bash Tool Fails with posix_spawnp Error After Extended Use
- [microsoft/node-pty#882](https://github.com/microsoft/node-pty/releases) — `/dev/ptmx` leak fix (v1.2.0-beta.10)
- [microsoft/vscode#259179](https://github.com/microsoft/vscode/issues/259179) — Copilot causing "Too Many Open Files"

## What it does

| Level | Action | Trigger |
|-------|--------|---------|
| 1 | **Auto-kill** zombie copilot processes | `PPID=1` + no TTY (orphaned, 100% CPU, writes EIO in loop) |
| 2 | **Alert** with per-process breakdown | Any copilot process with >150 leaked ptmx FDs |
| 3 | **Alert** with restart recommendation | Total PTY usage >80% of `kern.tty.ptmx_max` |

Alerts go to macOS Notification Center. If [`notify-telegram`](https://github.com/witqq/telegram-notifier) is found in `$PATH`, alerts are also sent to Telegram (optional, no hard dependency).

Alerts have a 30-minute cooldown to avoid spam.

## Why not auto-fix?

Leaked ptmx FDs are held **inside** the copilot process. The only way to free them is to kill the process. `lldb` attach is blocked by Copilot's Hardened Runtime code signature (signed by GitHub with `runtime` flag, no `get-task-allow` entitlement). There is no external mechanism on macOS to close another process's file descriptors.

The monitor alerts you which process to restart and how many PTYs it will free. `copilot --resume` restores session context after restart.

## Install

```bash
git clone https://github.com/witqq/pty-monitor.git
cd pty-monitor
./install.sh
```

This will:
- Symlink `pty-monitor` to `~/.local/bin/`
- Create and load a LaunchAgent (runs every 5 minutes)

Requires `~/.local/bin` in `$PATH`.

## Usage

```bash
pty-monitor --status     # show PTY usage table
pty-monitor              # kill zombies + alert if >80%
pty-monitor --force      # alert regardless of cooldown
pty-monitor --dry-run    # preview actions without executing
```

### Example output

```
PTY: 948/999 used (94%), 51 free

PID      TTY        CPU%   ptmx     Project
---      ---        ---    ---      ---
75234    ttys002    3.0    464      claude-ask LEAK!
78010    ttys015    4.9    389      planeta-analysis-worktree LEAK!
74473    ttys008    0.0    52       mcp-moira-dev
87473    ttys007    0.0    53       claude-supervisor-dev

Restart recommendation: kill PID 75234 (claude-ask in ttys002)
  -> frees ~464 PTYs, then 'copilot --resume' in that terminal
```

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.local.pty-monitor.plist
rm ~/Library/LaunchAgents/com.local.pty-monitor.plist ~/.local/bin/pty-monitor
```

## Diagnostics

Manual checks without the script:

```bash
# Current PTY limit
sysctl kern.tty.ptmx_max

# PTY devices allocated
ls /dev/ttys[0-9][0-9][0-9] | wc -l

# Per-process ptmx FD count
lsof -p <PID> | grep -c ptmx

# Increase limit to max (temporary, resets on reboot)
sudo sysctl kern.tty.ptmx_max=999
```

## Logs

- Monitor log: `/tmp/pty-monitor.log`
- LaunchAgent log: `/tmp/pty-monitor-launchd.log`

## Platform

macOS only. Tested on macOS Tahoe (Darwin 25.x) with Copilot CLI 0.0.405.
