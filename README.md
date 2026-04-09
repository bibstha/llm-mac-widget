# zai_token_widget

Menu bar app for macOS that shows **Z.AI** GLM coding plan quota (remaining **%** from the [usage API](https://api.z.ai)).

The app was **built entirely using [Cursor](https://cursor.com)** (AI-assisted development in the editor).

Your Z.AI API key is **stored in the macOS login keychain** when you save it in Preferences (generic password for this app — not in files, not in git).

![Menu bar: Z.ai quota and menu](menubar-screenshot.png)

## Requirements

- macOS 14+
- Swift toolchain (Xcode or Command Line Tools)

## Run

```bash
git clone https://github.com/bibstha/zai_token_widget.git
cd zai_token_widget
./run.sh
```

That builds a release binary, packages `ZaiTokenWidget.app`, and opens it. The item appears on the **right** side of the menu bar.

**Manual build:**

```bash
swift build -c release
./package_app.sh
open ZaiTokenWidget.app
```

## API key

1. Create or copy a key from [Z.AI API keys](https://z.ai/manage-apikey/apikey-list).
2. **Preferences…** (⌘,) from the menu bar item and paste it. It is saved to the **login keychain** (you can inspect or delete it in **Keychain Access** if needed).

Or set **`ZAI_API_KEY`** or **`GLM_API_KEY`** in your environment instead (not stored in the keychain).

## Behaviour

- Fetches quota on launch, then **every 5 minutes** (use **Refresh** in the menu anytime).
- On macOS 26 (Tahoe), launch the **`.app`** (`open`, Finder, or `./run.sh`). Avoid running the raw binary from Terminal and pressing **Ctrl+C**, which quits the app.
