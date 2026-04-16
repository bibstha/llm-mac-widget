# llm-mac-widget

Menu bar app for macOS that shows:

- **Z.AI** GLM coding plan quota (remaining **%** from the [Z.AI usage API](https://api.z.ai))
- **Claude Code / Claude Max** session quota (remaining **%** in the current 5-hour window, from Anthropic’s OAuth usage API — the same session data as `claude` after you sign in)

The app was **built entirely using [Cursor](https://cursor.com)** (AI-assisted development in the editor).

Your **Z.AI API key** is **stored in the macOS login keychain** when you save it in Preferences (generic password for this app — not in files, not in git). **Claude** does not use a key from this app: it reuses the OAuth session the **Claude Code** CLI stores under `~/.claude/.credentials.json`, the Keychain item **Claude Code-credentials**, or optional env vars **`CLAUDE_CODE_OAUTH_TOKEN`** / **`CLAUDE_OAUTH_TOKEN`** (same idea as [ClaudeBar](https://github.com/tddworks/ClaudeBar)).

![Menu bar: Z.ai quota and menu](menubar-screenshot.png)

## Requirements

- macOS 14+
- Swift toolchain (Xcode or Command Line Tools)

## Run

```bash
git clone https://github.com/bibstha/llm-mac-widget.git
cd llm-mac-widget
./run.sh
```

That builds a release binary, packages `LlmTokenWidget.app`, and opens it. The item appears on the **right** side of the menu bar.

**Manual build:**

```bash
swift build -c release
./package_app.sh
open LlmTokenWidget.app
```

## Debug

For a debug build under **lldb** (with optional unified **logs** or **Address Sanitizer**):

```bash
./scripts/run-debug.sh           # build + lldb (type `run` in lldb)
./scripts/run-debug.sh logs      # second terminal: stream app logs
./scripts/run-debug.sh asan       # ASan build + lldb (slow)
./scripts/run-debug.sh --help
```

Crash reports may appear under `~/Library/Logs/DiagnosticReports/LlmTokenWidget-*.ips`.

## Credentials

### Z.AI

1. Create or copy a key from [Z.AI API keys](https://z.ai/manage-apikey/apikey-list).
2. **Preferences…** (⌘,) from the menu bar item and paste it. It is saved to the **login keychain** (you can inspect or delete it in **Keychain Access** if needed).

Or set **`ZAI_API_KEY`** or **`GLM_API_KEY`** in your environment instead (not stored in the keychain).

### Claude Code / Max

Sign in with the **`claude`** CLI (`claude login` or equivalent). The widget reads the same OAuth credentials as the CLI. If the menu shows **CC—**, confirm `~/.claude/.credentials.json` exists and is readable, or that **Claude Code-credentials** appears in Keychain Access. You can also set **`CLAUDE_CODE_OAUTH_TOKEN`** (or **`CLAUDE_OAUTH_TOKEN`**) in the environment when launching the app from a shell — Finder-launched apps do not inherit shell exports.

## Behaviour

- **Menu bar title** shows seconds until the next automatic refresh, then compact Z.AI and Claude Code fragments, for example **`55 Z80 CC90`** (no `:` or `%` in the title). The countdown is **refreshed every 5 seconds** in the UI (the actual auto-refresh still runs on schedule).
- **Automatic refresh** runs on a timer: **every 5 minutes** by default. Enable **Refresh every 1 minute** in the menu (checkbox) for a 1-minute interval; the choice is persisted in **UserDefaults**.
- Use **Refresh** in the menu anytime (⌘R). The dropdown lists token quota lines; there is no separate countdown line in the menu (the menu bar title is the main indicator).
- **Claude Code** quota uses Anthropic’s **`/api/oauth/usage`** endpoint, which is **rate-limited** (Claude Code polls it too). After at least one successful fetch, the menu bar **keeps the last good `CC` percentage** when refresh fails (rate limits, decode quirks, etc.); **`CC!`** only appears if the usage API never succeeded this session. Prefer **5-minute** auto-refresh over **1-minute** if you hit limits often.
- On macOS 26 (Tahoe), launch the **`.app`** (`open`, Finder, or `./run.sh`). Avoid running the raw binary from Terminal and pressing **Ctrl+C**, which quits the app.
