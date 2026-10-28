# Gateway

<p align="center">
    <img src="AWS CLI Gateway/Assets.xcassets/AppIcon.appiconset/aws-cli-gateway-app-icon-iOS-Default-512x512@1x.png" width="128">
</p>

## Overview

A macOS menu bar application for managing AWS SSO profiles and sessions. Monitor multiple concurrent sessions, get proactive expiry warnings, and run AWS CLI commands without manually specifying profiles.

## What's New in v1.0.0

Version 1.0 is a ground-up redesign of Gateway.

**Completely new interface** — The legacy NSMenu dropdown has been replaced with a floating NSPanel powered by SwiftUI. Profiles are displayed as interactive rows with expandable detail sections showing region, account ID, role, and token expiry. Connect, disconnect, and refresh sessions without ever leaving the menu bar.

**Multi-profile session monitoring** — Track up to 5 concurrent AWS SSO sessions simultaneously. Each profile gets its own countdown timer, health check cycle, and status indicator. Sessions are automatically restored when the app launches.

**Intelligent session management** — Dual-layer token tracking monitors both role credentials (~1h lifespan) and SSO session tokens (~8h lifespan) independently. Proactive credential refresh kicks in 15 minutes before expiry, keeping `~/.aws/cli/cache` fresh for the AWS CLI, and the SSO token in `~/.aws/sso/cache` is refreshed before it expires so Terraform and other AWS SDK tools keep working. Health checks run every 5 minutes via `sts get-caller-identity` to catch dead sessions early.

**Redesigned notifications** — Per-profile expiry warnings at configurable thresholds (1h, 30m, 10m, 5m, 1m) with actionable "Refresh" buttons. Notification deduplication prevents spam — each profile is rate-limited to one notification per 60 seconds.

**Color-coded status system** — Green pulsing dot for active sessions, red for expired, gray for disconnected. Status is visible at a glance in both the menu bar icon and per-profile rows.

**New liquid glass app icon** — Designed with Icon Composer for macOS Sequoia.

**Build from source** — New `build.sh` script lets anyone clone the repo and build without opening Xcode.

### [Full Release Notes](Release%20Notes.md)

## Features

### Multi-Profile Session Management
- Monitor up to 5 concurrent AWS SSO sessions
- Per-profile countdown timers with automatic refresh
- Proactive credential refresh 15 minutes before expiry
- Health checks via `sts get-caller-identity` every 5 minutes
- Session restore on app launch

### Interactive Menu Bar Panel
- Floating NSPanel with SwiftUI interface (replaces legacy NSMenu)
- Expandable profile detail showing region, account, and expiry info
- One-click connect, disconnect, and refresh per profile
- Color-coded status: green (active), red (expired), gray (disconnected)

### Profile Management
- **SSO Profiles**: Create profiles with permission set management
- **IAM Role Profiles**: Assume roles from source SSO profiles

### Terminal Integration
- `gateway` CLI command routes AWS commands through your connected profile
- `gateway list sso` / `gateway list role` for quick profile enumeration
- `gateway debug` for troubleshooting

### Notifications
- Per-profile expiry warnings with configurable thresholds
- Notification deduplication (60s cooldown per profile)
- "Refresh" action button directly on notifications

## Installation

Install with [Homebrew](https://brew.sh):

```bash
brew trust dmcphearson/tap
brew install --cask dmcphearson/tap/gateway
```

Homebrew 7 only loads third-party taps you have trusted; the first line does that once.

Update with `brew upgrade --cask gateway`. Or download the latest release from the [Releases](https://github.com/dmcphearson/gateway/releases) page and move `Gateway.app` to your Applications folder.

### Build from Source

Requires Xcode 16+ and macOS 15.2+.

```bash
git clone https://github.com/dmcphearson/gateway.git
cd gateway
./build.sh
```

The built app appears in `output/Gateway.app`. To install:

```bash
cp -R output/Gateway.app /Applications/
```

To sign with your own Developer ID:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name" ./build.sh
```

Building in Xcode signs the app to run locally by default, so no Apple account is needed. To sign with your own team (for Archive, for example), create `Config/Signing.local.xcconfig`; it is gitignored:

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = <your Team ID>
```

Set signing there, not in the Signing & Capabilities tab, which writes your team into the project file. CI fails if signing settings appear in `project.pbxproj`.

## Terminal Integration

Install the `gateway` command from the menu bar: **Tools & Settings > Install CLI Tools**.

```bash
# Run AWS commands with your connected profile
gateway s3 ls
gateway ec2 describe-instances

# List available profiles
gateway list
gateway list sso
gateway list role

# Debug information
gateway debug
```

## Requirements

- macOS 15.2 (Sequoia) or later
- AWS CLI v2 installed and configured
- AWS SSO configured for your organization

## Roadmap

Features I'm exploring for future releases:

- **Keychain-backed token storage** — Store SSO refresh tokens in macOS Keychain (encrypted at rest, Touch ID protected) instead of plaintext JSON in `~/.aws/sso/cache`
- **App-to-profile binding** — Bind shell commands (`terraform`, `cdk`, `npm`) to specific profiles with per-command `AWS_PROFILE` injection
- **Profile grouping** — Organize profiles by AWS organization or team for users managing 15+ profiles
- **Menu bar icon state** — Reflect worst-case session status across all profiles in the status bar icon

## Contributing

Contributions are welcome. Please open an issue or pull request.

## License

Licensed under the [Apache License 2.0](LICENSE). If you redistribute it, include the [NOTICE](NOTICE) file. AWS is a trademark of Amazon.com, Inc. or its affiliates; this project is not affiliated with or endorsed by Amazon.
