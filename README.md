# ClaudeUsageBar

A tiny macOS menu bar app that shows two numbers side by side:

```
✳︎ 66%  ◷ 14%
```

- **✳︎**: how much of your **weekly Claude budget** is left (the same figure `/usage` shows in Claude Code)
- **◷**: how much of the **week** is left until that budget resets

If the budget number is lower than the time number, you're using the budget faster than the week is passing, and the budget number turns **orange**.

Click the menu bar item to see details: % used, the exact reset time, your 5-hour session usage, a Refresh button (⌘R), a *Launch at Login* toggle and Quit.

## How it works

1. It reads the OAuth token that Claude Code stores in the macOS Keychain (item `Claude Code-credentials`), or `~/.claude/.credentials.json` if the Keychain item isn't there.
2. Every 5 minutes it calls `GET https://api.anthropic.com/api/oauth/usage`, the endpoint Claude Code itself uses for usage, and reads:
   - `seven_day.utilization`: % of the weekly budget used, so the app shows 100 − this
   - `seven_day.resets_at`: when the weekly budget resets
   - `five_hour`: your current session window (shown in the menu)
3. Week left = time until `resets_at` ÷ 7 days. This number updates every minute.

The token is sent only to `api.anthropic.com`. The app doesn't store anything or send data anywhere else. It is a single Swift file ([main.swift](main.swift)) with no dependencies.

> **Note:** The usage endpoint isn't documented and could change without notice.

## Prerequisites

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- **Claude Code** installed and logged in with a Claude Pro/Max account. The app reuses that login and has none of its own.

## Build & run

```sh
git clone https://github.com/schildbuerger/claude-usage-bar.git
cd claude-usage-bar
./build.sh
open ClaudeUsageBar.app
```

You can move `ClaudeUsageBar.app` to `/Applications` and turn on *Launch at Login* from its menu.

## Troubleshooting

- **⚠︎ "Token expired" / "Unauthorized"**: the app never renews the token itself, because that could log Claude Code out. Use Claude Code once and it renews the token; the app picks it up at the next refresh.
- **⚠︎ "No Claude Code login found"**: log in to Claude Code first (`claude` → `/login`).
- **Keychain prompt on first launch**: click *Always Allow* so the app can read the token.

## License

MIT
