# Release Notes

## Version 1.0.3

- Renamed to **Gateway**. Settings, connected profiles and the `gateway` command carry over unchanged.
- Now installable with Homebrew: `brew install --cask dmcphearson/tap/gateway`, updated with `brew upgrade --cask gateway`. If you installed AWS CLI Gateway by hand, quit it and delete `/Applications/AWS CLI Gateway.app` first.
- Terraform and other AWS SDK tools keep working: the SSO token in `~/.aws/sso/cache`, which they use instead of the CLI's role credentials, is refreshed before its one-hour expiry. Previously it lapsed while the countdown and the AWS CLI still looked healthy, and Terraform failed with `InvalidGrantException`.
- Refresh and Sign In now renew the SSO token too, signing in with `aws sso login --sso-session` when the profile uses an SSO session.
- The profile details show the SSO token's state next to the role-credential countdown, and the profile turns yellow when that token can no longer refresh.
- The menu bar item keeps its position and stays visible, and the panel stays on screen near display edges.

---

## Version 1.0.2

- Fixed a session-monitoring crash caused by a data race on shared session state
- More accurate session tracking: only profiles connected through the app are restored on launch; terminal-only `aws sso login` no longer shows up as connected
- Faster detection of dead sessions (health-checks every due profile each tick instead of round-robin)
- Proactive refresh-token probe: when role credentials near expiry, the app silently mints a fresh window if the SSO refresh token is still valid
- New yellow "reauth required" state with one-click Sign In when the refresh token has expired, so a still-valid final hour of credentials is never destroyed

---

## Version 1.0.1

- Added status indicator dot on menu bar icon (green = active session, red = expired)
- Interactive arrow-key profile picker for `gateway use` CLI command
- Per-terminal session persistence for gateway CLI

---

## Version 1.0.0

Major release — complete rebuild of the session management system and UI.

### Multi-Profile Sessions
- Monitor up to 5 concurrent AWS SSO profiles simultaneously
- Independent per-profile countdown timers, health checks, and refresh
- Proactive credential refresh when role credentials are within 15 minutes of expiry
- Automatic session restore on app launch

### New Menu Bar UI
- Replaced NSMenu with a floating NSPanel + SwiftUI interface
- Expandable profile rows showing region, account ID, and token expiry
- Per-profile connect, disconnect, and refresh controls inline
- Color-coded session status (green/red/gray)

### Phantom Session Fix
- Fixed incorrect SSO cache hash computation (now matches botocore: `sha1(sessionName)` for new-style configs, `sha1(startUrl)` for legacy)
- Dual-layer expiry tracking: monitors both role credentials (~1h) and SSO session tokens (~8h)
- Health checks detect dead sessions that still have time on the countdown


### Notifications
- Per-profile expiry warnings at configurable thresholds (1h, 30m, 10m, 5m, 1m)
- 60-second cooldown per profile to prevent notification spam
- Actionable "Refresh" button on notification banners

### App Icon
- New liquid glass icon designed with Icon Composer for macOS Sequoia

### Codebase
- 24% line-of-code reduction (7054 → 5382) with zero features removed
- Removed 5 orphaned files from prior UI architecture
- Consolidated duplicate managers into generic `JSONFileStore`
- Extracted shared ISO8601 date parsing across token managers
- Added `build.sh` for building from source without Xcode GUI
- Fixed App Support directory permission error when owned by root

### Breaking Changes
- Minimum macOS version raised to 15.2 (Sequoia)

---

## Version 0.4.5

- Enhanced UX: Star buttons only appear when there's an active session
- Improved Session Management: Fixed token synchronization issues
- Dynamic Menu Layout: Menu width and spacing adjust based on session state
- Better Error Handling: Resolved infinite loop on expired SSO refresh
- Visual Polish: Proper spacing and padding

## Version 0.4.0

- Session Management: Clear cache for active sessions on quit
- Tools & Settings Menu: Reorganized submenu
- Install CLI Tools: Simplified terminal integration access
- AWS Console Access: Open console from menu bar
- Official Apple Developer ID signing

## Version 0.3.0

- Refactored script management
- Enhanced menu bar responsiveness
- Stability fixes for session management

## Version 0.2.0

- Terminal Integration: `gateway` command for profile-aware AWS CLI
- Connected Profile: Auto-uses connected profile in terminal
- Enhanced Session Management: Improved tracking and renewal
- Debug Tools: Diagnostic features for troubleshooting
