# CodexSwitch introduction website

<!-- impeccable:product-schema 1 -->

## Platform

web

This record covers the website in `website/`, not the native Swift application.

## Product Purpose

Introduce CodexSwitch and link visitors to its existing GitHub releases.
The native macOS menu bar app switches ChatGPT/Codex accounts, shows usage and
reset credits, and manages locally saved accounts. Product facts come from
README.ko.md and Sources/CodexSwitch.

## Users

Repository-supported audience: Apple Silicon Mac users with several Codex or
ChatGPT accounts. Marketing audience segmentation beyond that is undecided.

## Capabilities and Constraints

- macOS 14 or later and Apple Silicon; official Codex CLI or ChatGPT app required.
- Account information is stored locally; login and usage requests contact OpenAI.
- Switching may restart ChatGPT; CLI restart remains manual.
- No invented testimonials, adoption statistics, prices, or license claims.
- Web demonstration values are examples; the website does not access accounts.
- Existing Korean and English routes and release download destination remain.

## Brand Commitments

User explicitly rejected the previous mint/silver palette, ribbon artwork,
tilted screenshot presentation, and overall design.
User explicitly named https://codexbar.app/?lang=ko as the reference for a clean,
realistic Mac display with native menu UI, and requested direct code rendering
of CodexSwitch's actual UI instead of screenshots. Preserve the app name/icon.
No generated artwork or screenshot-based product panels in the replacement.

## Evidence on Hand

- Sources/CodexSwitch/Views/MenuContentView.swift: 372px menu, native text hierarchy.
- Sources/CodexSwitch/Views/StatusMenuController.swift: submenu order and behavior.
- README.ko.md: app capabilities, installation, supported devices and legal facts.
- docs/images/codexswitch-icon.png: established app icon.
- User-provided CodexBar reference inspected in the browser.
