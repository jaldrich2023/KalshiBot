# Installing Kalshi Bot from the download

Each [GitHub Release](https://github.com/jaldrich2023/KalshiBot/releases) includes a ready-to-run copy of the app, `KalshiBot-<version>-macOS.zip`.

> **This is not a signed developer build.** The app is only *ad-hoc signed*: it isn't signed with an Apple Developer ID and hasn't been notarized by Apple. macOS will block it the first time you open it. The steps below tell macOS you trust it. If you'd rather not, [build it from source](../README.md#building) in Xcode instead.

## Requirements

- A Mac with **Apple silicon** (M1 or later). The download doesn't run on Intel Macs.
- **macOS 27.2** or later.
- A large display is best: the window is a fixed 2,400 × 1,600 points. On a smaller screen it shrinks to fit and the dashboard scrolls inside it.
- An internet connection. The app reads public market data only; it needs no account or API keys, and it never places orders.

## 1. Download and check it

1. Download `KalshiBot-<version>-macOS.zip` from the release's **Assets**.
2. Optional but recommended: check that the file is intact. Open **Terminal** and run:

   ```
   shasum -a 256 ~/Downloads/KalshiBot-2.28.0-macOS.zip
   ```

   The result should match the checksum in the release notes, which is also attached as `KalshiBot-<version>-macOS.zip.sha256`.

## 2. Install

1. Double-click the zip in **Downloads** to unzip it. You'll get **KalshiBot**.
2. Drag **KalshiBot** into your **Applications** folder.

## 3. Open it the first time

Because the app isn't notarized, the first launch takes a few extra steps.

1. Double-click **KalshiBot** in Applications. macOS says it can't verify the app, or that it can't be opened. Click **Done** (or **OK**). Don't move it to the Trash.
2. Open **System Settings › Privacy & Security**.
3. Scroll down to **Security**. You'll see *"KalshiBot" was blocked to protect your Mac*. Click **Open Anyway**.
4. Enter your password (or use Touch ID), then click **Open Anyway** again in the dialog.

After this one-time approval, KalshiBot opens normally.

### Or, using Terminal

If you prefer, remove the download's quarantine flag instead, then open the app normally:

```
xattr -dr com.apple.quarantine /Applications/KalshiBot.app
```

## 4. First run

- The bot starts automatically. The status pill at the top left shows **Live**.
- It downloads up to 180 days of Kalshi and Coinbase market history and rebuilds the past windows for training. This takes a few minutes the first time. Progress shows in the Model card.
- The first call locks at +3 minutes into the next 15-minute window.
- While it runs, it keeps your Mac awake so it doesn't miss windows. Turn off **Keep Mac awake** in the Strategy card to allow sleep.

See the [User Manual](USER_MANUAL.md) for everything else.

## Updating

Quit KalshiBot, replace the copy in Applications with the new version, and repeat step 3 if macOS asks again. Your prediction log, history and settings are kept: they live in the app's own data folder, not in the app itself.

## Uninstalling

1. Quit KalshiBot and drag it from Applications to the Trash.
2. To remove its data too (prediction log, saved history and settings), delete this folder:

   ```
   ~/Library/Containers/I-m-The-Team.KalshiBot
   ```

   Or use **Model › Reset Model… › Erase Everything** in the app before deleting it.

## Troubleshooting

**"KalshiBot is damaged and can't be opened."** The quarantine flag is still set. Run the Terminal command in step 3.

**Nothing appears under Privacy & Security.** Try opening the app once more from Applications, then look again; the **Open Anyway** button appears only for an hour or so after a blocked launch.

**It says it needs a newer version of macOS.** The app requires macOS 27.2 or later.

**It doesn't open on an Intel Mac.** The download is built for Apple silicon only. Intel Macs can [build it from source](../README.md#building).

> **Not financial advice.** Kalshi Bot gives statistical estimates for information and education only. See the [disclaimer](../DISCLAIMER.md). Kalshi Bot is open source under the [MIT License](../LICENSE).
