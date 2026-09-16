**English** · [한국어 설명 보기](README.ko.md)

<div align="center">
  <img src="docs/images/codexswitch-icon.png" width="104" alt="CodexSwitch app icon">
  <h1>CodexSwitch</h1>
  <p><strong>Switch accounts. Keep your workflow.</strong></p>
  <p>View multiple ChatGPT/Codex accounts and their usage from the menu bar, and switch between them.</p>
  <p>
    <a href="https://github.com/heeeete/CodexSwitch/releases/latest"><img src="https://img.shields.io/badge/Download-latest-5865E8?style=flat-square&logo=apple&logoColor=white" alt="Download the latest version"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-30363D?style=flat-square&logo=macos&logoColor=white" alt="macOS 14 or later">
    <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-42B7B3?style=flat-square" alt="Apple Silicon">
  </p>
</div>



## Features

- **Account switching** — Switch between saved accounts without opening a terminal.
- **Usage overview** — See remaining Codex usage and the time until reset at a glance, with percentages and progress bars.
- **Reset credits** — View the current account’s available credits in order of soonest expiry. Remaining time is shown in a compact format such as `5d 20h`, and credits are fetched automatically.
- **Auto-refresh** — Refresh usage and reset credits every minute, even when the menu is closed. It is enabled by default, and your preference is saved between launches.
- **App updates** — Automatically check for updates and show a restart prompt at the bottom of the menu when an update is ready.
- **Account management** — Add new accounts and remove accounts saved on this Mac.

## Installation

1. Download the Apple Silicon ZIP from the [latest release](https://github.com/heeeete/CodexSwitch/releases/latest).
2. Unzip it and open `CodexSwitch.app`. On first launch, it installs itself in **Applications** and reopens automatically.
3. Click the CodexSwitch icon in the menu bar. If another instance of CodexSwitch is running, quit it, then click **Try Again** in the installation prompt.

> [!NOTE]
> The release app is signed with an Apple Developer ID and notarized by Apple. Once installed, it runs in the menu bar. If `/Applications` is not writable, it uses your personal `~/Applications` folder instead.

If you are using a version earlier than `0.3.0`, download and replace the app manually once.
Starting with `0.3.0`, the app checks for updates every hour. After downloading and verifying an
update, it displays **“An update is ready. Restart now?”** Click **Restart** to update and
relaunch CodexSwitch only. If an account operation is in progress, the button becomes available
once that operation finishes.

## Requirements

- macOS 14 or later
- An Apple Silicon Mac
- Either the official Codex CLI or the official ChatGPT desktop app

## Usage

1. If you are already signed in to the Codex CLI or ChatGPT, your existing account is imported automatically.
2. If you have no accounts, click **Add Account** and sign in through your browser. Your current account and any running ChatGPT app remain unchanged.
3. To switch accounts, hover over **Switch Account** and select an account from the submenu on the right.
4. To remove an account saved on this Mac, choose it from **Remove Account**.

Removing an account only deletes its Codex authentication data on this Mac. It does not delete your actual ChatGPT account.

## Usage Data

Usage is based on recent records. After switching accounts, “No usage data” may appear until new usage is recorded.

## Data and Accounts

- Account information is stored on this Mac and is not sent to a separate CodexSwitch server.
- Reset credits are requested directly from OpenAI using your saved sign-in credentials.
- Existing sign-in information is backed up locally before switching accounts.
- Avoid changing the same accounts in other tools while CodexSwitch is switching or removing an account.

## Open Source and Notices

CodexSwitch includes [`codex-auth`](https://github.com/Loongphy/codex-auth), which is licensed under the MIT License. See [Third-party notices](THIRD_PARTY_NOTICES.md) for full attribution and licensing details.

No separate open-source license applies to CodexSwitch’s own source code. CodexSwitch is not affiliated with OpenAI and is not an official product endorsed by OpenAI. ChatGPT and Codex are trademarks of their respective owners.
