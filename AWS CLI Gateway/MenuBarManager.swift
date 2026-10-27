import SwiftUI
import Cocoa
import CommonCrypto
import UserNotifications

// MARK: - Floating Panel (replaces NSMenu for full interactivity)

class StatusBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onClose: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override func resignKey() {
        super.resignKey()
        close()
        onClose?()
    }
}

// MARK: - SwiftUI Content View

struct StatusBarContentView: View {
    @ObservedObject var viewModel: StatusBarViewModel
    @State private var showDisconnected = false
    @State private var expandedProfile: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("AWS Profiles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            // Connected profiles
            ForEach(viewModel.connectedProfiles, id: \.name) { profile in
                ConnectedProfileRow(
                    profile: profile,
                    isExpanded: expandedProfile == profile.name,
                    onTap: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            expandedProfile = expandedProfile == profile.name ? nil : profile.name
                        }
                    },
                    onFullRefresh: { viewModel.fullRefreshProfile(profile.name) },
                    onDisconnect: { viewModel.disconnectProfile(profile.name) }
                )
            }

            // Disconnected profiles toggle
            if !viewModel.disconnectedProfiles.isEmpty {
                Divider().padding(.horizontal, 10).padding(.vertical, 4)

                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showDisconnected.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: showDisconnected ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                        Text("\(viewModel.disconnectedProfiles.count) more profile\(viewModel.disconnectedProfiles.count == 1 ? "" : "s")")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                if showDisconnected {
                    ForEach(viewModel.disconnectedProfiles, id: \.name) { profile in
                        DisconnectedProfileRow(
                            profile: profile,
                            onConnect: { viewModel.connectProfile(profile.name) }
                        )
                    }
                }
            }

            Divider().padding(.horizontal, 10).padding(.vertical, 4)

            // Actions
            if !viewModel.connectedProfiles.isEmpty {
                MenuActionButton(title: "Open AWS Console", icon: "globe") {
                    viewModel.openConsole()
                }
                MenuActionButton(title: "Disconnect All", icon: "xmark.circle") {
                    viewModel.disconnectAll()
                }
                Divider().padding(.horizontal, 10).padding(.vertical, 4)
            }

            MenuActionButton(title: "Settings...", icon: "gear") {
                viewModel.openSettings()
            }
            MenuActionButton(title: "Quit", icon: "power") {
                NSApp.terminate(nil)
            }
            .padding(.bottom, 8)
        }
        .frame(width: 300)
        .background(VisualEffectView())
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ConnectedProfileRow: View {
    let profile: ProfileDisplayInfo
    let isExpanded: Bool
    let onTap: () -> Void
    let onFullRefresh: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(profile.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Text(profile.timeRemaining)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.20))
                    .cornerRadius(4)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            // Expanded detail
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let account = profile.accountId, let role = profile.roleName {
                        DetailRow(label: "Account", value: account)
                        DetailRow(label: "Role", value: role)
                    }
                    if let region = profile.region {
                        DetailRow(label: "Region", value: region)
                    }
                    if let expires = profile.expiresAtLocal {
                        DetailRow(label: "Expires", value: expires)
                    }
                    if let ssoToken = profile.ssoTokenState {
                        DetailRow(label: "SSO token", value: ssoToken)
                    }

                    HStack(spacing: 8) {
                        Spacer()
                        // In the yellow reauth state, the refresh button becomes
                        // a prominent "Sign In" — onFullRefresh already runs the
                        // browser login + re-mint flow.
                        Button(action: onFullRefresh) {
                            HStack(spacing: 4) {
                                Image(systemName: profile.status == .reauthRequired ? "person.badge.key" : "arrow.clockwise")
                                    .font(.system(size: 10))
                                Text(profile.status == .reauthRequired ? "Sign In" : "Full Refresh")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(profile.status == .reauthRequired ? .yellow : nil)

                        Button(action: onDisconnect) {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 10))
                                Text("Disconnect")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var statusColor: Color {
        switch profile.status {
        case .active: return .green
        case .reauthRequired: return .yellow
        case .expired: return .red
        default: return .gray
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 75, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.primary)
        }
    }
}

struct DisconnectedProfileRow: View {
    let profile: ProfileDisplayInfo
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.gray)
                .frame(width: 8, height: 8)

            Text(profile.name)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button(action: onConnect) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

struct MenuActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(isHovered ? Color.primary.opacity(0.1) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .padding(.horizontal, 4)
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - View Model

struct ProfileDisplayInfo {
    let name: String
    var timeRemaining: String
    var status: ProfileSessionStatus
    var accountId: String?
    var roleName: String?
    var region: String?
    var expiresAtLocal: String?
    var ssoTokenState: String?
}

@MainActor
class StatusBarViewModel: ObservableObject {
    @Published var connectedProfiles: [ProfileDisplayInfo] = []
    @Published var disconnectedProfiles: [ProfileDisplayInfo] = []

    weak var manager: MenuBarManager?

    func refresh() {
        let connected = ProfileHistoryManager.shared.getConnectedProfiles()
        let connectedNames = Set(connected.map { $0.originalName })
        let allProfiles = ConfigManager.shared.getProfiles()

        connectedProfiles = connected.map { info in
            let session = SessionManager.shared.activeSessions[info.originalName]
            let awsProfile = allProfiles.first(where: { $0.name == info.originalName })
            let ssoProfile = awsProfile as? SSOProfile

            var expiresLocal: String?
            if let expiry = session?.effectiveExpiry {
                let fmt = DateFormatter()
                fmt.dateStyle = .none
                fmt.timeStyle = .short
                fmt.timeZone = .current
                let timePart = fmt.string(from: expiry)
                if Calendar.current.isDateInToday(expiry) {
                    expiresLocal = "Today at \(timePart)"
                } else if Calendar.current.isDateInTomorrow(expiry) {
                    expiresLocal = "Tomorrow at \(timePart)"
                } else {
                    let dayFmt = DateFormatter()
                    dayFmt.dateFormat = "MMM d"
                    expiresLocal = "\(dayFmt.string(from: expiry)) at \(timePart)"
                }
            }

            return ProfileDisplayInfo(
                name: info.originalName,
                timeRemaining: session?.formattedTimeRemaining ?? "--:--:--",
                status: session?.status ?? .connecting,
                accountId: ssoProfile?.accountId,
                roleName: ssoProfile?.roleName,
                region: ssoProfile?.region,
                expiresAtLocal: expiresLocal,
                ssoTokenState: session?.ssoTokenSummary()
            )
        }

        disconnectedProfiles = allProfiles
            .filter { !connectedNames.contains($0.name) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { ProfileDisplayInfo(name: $0.name, timeRemaining: "", status: .expired) }
    }

    func refreshProfile(_ name: String) {
        Task {
            let success = await SessionManager.shared.refreshSSOSession(for: name)
            if !success {
                await MainActor.run {
                    manager?.showError("Refresh Failed", message: "Could not refresh session for \(name). The refresh token may have expired — try connecting again.")
                }
            }
        }
    }

    func fullRefreshProfile(_ name: String) {
        Task {
            // Delete existing role cred cache for this profile
            if let cacheFile = SessionManager.shared.activeSessions[name]?.cacheFileName {
                let homeDir = FileManager.default.homeDirectoryForCurrentUser
                let cachePath = homeDir.appendingPathComponent(".aws/cli/cache/\(cacheFile)")
                try? FileManager.default.removeItem(at: cachePath)
            }

            // Re-login (opens browser, gets fresh SSO token + refresh token)
            let loginArgs = SessionManager.ssoLoginArguments(
                profileName: name, sessionName: SessionManager.shared.ssoSessionName(for: name))
            _ = try? await CommandRunner.shared.runCommand("aws", args: loginArgs)
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            // Force new role credentials into the cache
            _ = try? await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", name])
            try? await Task.sleep(nanoseconds: 500_000_000)

            await MainActor.run {
                SessionManager.shared.startMonitoring(for: name)
                refresh()
            }
        }
    }

    func disconnectProfile(_ name: String) {
        Task {
            SessionManager.shared.cleanDisconnect(for: name)
            ProfileHistoryManager.shared.setProfileDisconnected(name)
            _ = try? await CommandRunner.shared.runCommand("aws", args: ["sso", "logout", "--profile", name])
            await MainActor.run {
                if manager?.activeProfile == name {
                    manager?.activeProfile = ProfileHistoryManager.shared.getConnectedProfileOriginalName()
                }
                refresh()
            }
        }
    }

    func connectProfile(_ name: String) {
        guard ProfileHistoryManager.shared.canConnectProfile() else {
            Task { @MainActor in
                manager?.showError("Connection Limit", message: "Maximum \(ProfileHistoryManager.maxConcurrentProfiles) concurrent profiles reached.")
            }
            return
        }
        manager?.connectProfileByName(name)
    }

    func disconnectAll() {
        manager?.disconnectAllProfiles()
    }

    func openConsole() {
        manager?.openConsole()
    }

    func openSettings() {
        manager?.openSettings()
    }
}

// MARK: - MenuBarManager

@MainActor
class MenuBarManager: NSObject {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private var panel: StatusBarPanel?
    private let viewModel = StatusBarViewModel()

    // Notification cooldown
    private var lastNotificationSent: [String: Date] = [:]
    private let notificationCooldown: TimeInterval = 60

    fileprivate(set) var activeProfile: String? {
        didSet {
            guard !isRestoringSessions else { return }
            Task { @MainActor in
                if let profile = activeProfile {
                    SessionManager.shared.startMonitoring(for: profile)
                    ProfileHistoryManager.shared.setConnectedProfile(profile)
                } else if ProfileHistoryManager.shared.getConnectedProfiles().isEmpty {
                    SessionManager.shared.cleanDisconnect()
                }
                viewModel.refresh()
            }
        }
    }
    private var isRestoringSessions = false

    private override init() {
        super.init()
        viewModel.manager = self
    }

    // MARK: - Setup

    func setup() {
        Task { @MainActor in
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

            // A named autosave gives the item a persisted slot in the menu bar.
            // Without it macOS recomputes a position on every layout pass and can
            // park the item outside the visible bounds of the display.
            statusItem?.autosaveName = "AWSCLIGatewayStatusItem"
            statusItem?.isVisible = true

            if let button = statusItem?.button {
                if let image = NSImage(named: "cloud-lock") {
                    image.size = NSSize(width: 18, height: 18)
                    image.isTemplate = true
                    button.image = image
                } else {
                    // Never leave the button empty — a variableLength item with no
                    // image collapses to zero width and becomes unclickable.
                    button.title = "AWS"
                    print("[Gateway] Error: cloud-lock image failed to load, using text fallback")
                }
                button.action = #selector(togglePanel)
                button.target = self
            } else {
                print("[Gateway] Error: status item button unavailable")
            }

            // No NSMenu — we use a panel instead
            statusItem?.menu = nil

            setupNotifications()
            restoreActiveSessions()
            viewModel.refresh()
            updateStatusIcon()

            // Live session updates — only update time strings, not full rebuild
            SessionManager.shared.onSessionsUpdated = { [weak self] sessions in
                Task { @MainActor in
                    guard let self = self else { return }
                    var changed = false
                    for i in self.viewModel.connectedProfiles.indices {
                        let name = self.viewModel.connectedProfiles[i].name
                        if let session = sessions[name] {
                            let newTime = session.formattedTimeRemaining
                            if self.viewModel.connectedProfiles[i].timeRemaining != newTime {
                                self.viewModel.connectedProfiles[i].timeRemaining = newTime
                                self.viewModel.connectedProfiles[i].status = session.status
                                changed = true
                            }
                            let ssoTokenState = session.ssoTokenSummary()
                            if self.viewModel.connectedProfiles[i].ssoTokenState != ssoTokenState {
                                self.viewModel.connectedProfiles[i].ssoTokenState = ssoTokenState
                                self.viewModel.connectedProfiles[i].status = session.status
                                changed = true
                            }
                        }
                    }
                    if changed {
                        self.viewModel.objectWillChange.send()
                    }
                    self.updateStatusIcon()

                    // Notify (once, with cooldown) for any profile that just
                    // entered the yellow reauth-required state.
                    for (name, session) in sessions where session.status == .reauthRequired {
                        self.handleReauthRequired(profileName: name)
                    }
                }
            }

            SessionManager.shared.onTokenExpirationWarning = { [weak self] profileName, timeUntilExpiry in
                Task { @MainActor in
                    self?.handleTokenExpirationWarning(profileName: profileName, timeUntilExpiry: timeUntilExpiry)
                }
            }
        }
    }

    @objc private func togglePanel() {
        if let panel = panel, panel.isVisible {
            panel.close()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        // Clean up any stale panel
        panel?.close()
        panel = nil

        guard let button = statusItem?.button, let buttonWindow = button.window else { return }

        viewModel.refresh()

        let contentView = StatusBarContentView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame.size = hostingView.fittingSize

        let panelRect = NSRect(x: 0, y: 0, width: hostingView.fittingSize.width, height: hostingView.fittingSize.height)
        let newPanel = StatusBarPanel(contentRect: panelRect)
        newPanel.contentView = hostingView
        newPanel.onClose = { [weak self] in
            self?.panel = nil
        }

        // Position below the status bar item, clamped to the screen so the panel
        // stays reachable even when the item sits near an edge of the display.
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        var panelX = screenRect.midX - panelRect.width / 2
        var panelY = screenRect.minY - panelRect.height - 4

        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            let margin: CGFloat = 8
            let maxX = max(visible.minX + margin, visible.maxX - panelRect.width - margin)
            panelX = min(max(panelX, visible.minX + margin), maxX)
            panelY = max(panelY, visible.minY + margin)
        }

        newPanel.setFrameOrigin(NSPoint(x: panelX, y: panelY))

        newPanel.makeKeyAndOrderFront(nil)
        self.panel = newPanel
    }

    // MARK: - Session Restore

    @MainActor
    private func restoreActiveSessions() {
        isRestoringSessions = true
        defer { isRestoringSessions = false }

        // Only restore profiles the user actually connected via the app (persisted
        // in profile_history.json), not every profile that happens to have a token
        // on disk — a terminal `aws sso login` should NOT auto-appear as connected.
        // Reconcile against disk: a previously-connected profile whose token is now
        // gone gets marked disconnected.
        let previouslyConnected = ProfileHistoryManager.shared.getConnectedProfiles()
        var restoredCount = 0

        for info in previouslyConnected {
            let profileName = info.originalName

            guard restoredCount < ProfileHistoryManager.maxConcurrentProfiles else {
                ProfileHistoryManager.shared.setProfileDisconnected(profileName)
                continue
            }

            if hasValidSessionOnDisk(for: profileName) {
                if activeProfile == nil { activeProfile = profileName }
                SessionManager.shared.startMonitoring(for: profileName)
                restoredCount += 1
            } else {
                // Token was logged out / expired while the app was closed.
                ProfileHistoryManager.shared.setProfileDisconnected(profileName)
            }
        }
    }

    /// Whether a profile has a usable SSO session on disk: a non-expired access
    /// token, or a token file that still carries a refresh token (renewable).
    @MainActor
    private func hasValidSessionOnDisk(for profileName: String) -> Bool {
        if let ssoExpiry = SSOTokenManager.shared.getSSOTokenExpiry(forProfile: profileName),
           ssoExpiry > Date() {
            return true
        }

        guard let sessionName = ConfigManager.shared.getSSOSessionName(for: profileName) else {
            return false
        }
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let ssoCachePath = homeDir.appendingPathComponent(".aws/sso/cache")
        let data = Data(sessionName.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        let hash = digest.map { String(format: "%02hhx", $0) }.joined()

        let tokenFile = ssoCachePath.appendingPathComponent("\(hash).json")
        if let fileData = try? Data(contentsOf: tokenFile),
           let json = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
           json["refreshToken"] != nil {
            return true
        }
        return false
    }

    func hasActiveSession() -> Bool {
        return activeProfile != nil
    }

    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        panel?.close()
        statusItem = nil
    }

    // MARK: - Status Icon

    private var statusDotView: NSView?

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        guard let baseImage = NSImage(named: "cloud-lock") else { return }

        let sessions = SessionManager.shared.activeSessions
        let hasExpired = sessions.values.contains { $0.status == .expired }
        let hasReauthRequired = sessions.values.contains { $0.status == .reauthRequired }
        let hasActive = sessions.values.contains { $0.status == .active }

        button.image = baseImage
        button.image?.isTemplate = true

        statusDotView?.removeFromSuperview()
        statusDotView = nil

        if sessions.isEmpty { return }

        // Priority: red (expired) > yellow (reauth needed) > green (active).
        let dotColor: NSColor
        if hasExpired {
            dotColor = .systemRed
        } else if hasReauthRequired {
            dotColor = .systemYellow
        } else if hasActive {
            dotColor = .systemGreen
        } else {
            dotColor = .systemGray
        }
        let dotDiameter: CGFloat = 6

        let dot = NSView(frame: NSRect(
            x: button.bounds.width - dotDiameter - 1,
            y: 1,
            width: dotDiameter,
            height: dotDiameter
        ))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = dotColor.cgColor
        dot.layer?.cornerRadius = dotDiameter / 2
        button.addSubview(dot)
        statusDotView = dot
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProfilesUpdated),
            name: Notification.Name(Constants.Notifications.profilesUpdated),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProfileConnected(_:)),
            name: Notification.Name(Constants.Notifications.profileConnected),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionExpired(_:)),
            name: Notification.Name(Constants.Notifications.sessionExpired),
            object: nil
        )
    }

    // MARK: - Actions (called by ViewModel)

    func connectProfileByName(_ name: String) {
        let profiles = ConfigManager.shared.getProfiles()
        guard let profile = profiles.first(where: { $0.name == name }) else { return }

        Task {
            do {
                if let iamProfile = profile as? IAMProfile {
                    let sourceProfileName = iamProfile.sourceProfile
                    let allProfiles = ConfigManager.shared.getProfiles()
                    if let sourceProfile = allProfiles.first(where: { $0.name == sourceProfileName }) as? SSOProfile {
                        _ = try await CommandRunner.shared.runCommand("aws", args: ["sso", "login", "--profile", sourceProfile.name])
                    }
                } else if profile is SSOProfile {
                    _ = try await CommandRunner.shared.runCommand("aws", args: ["sso", "login", "--profile", profile.name])
                }

                _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profile.name])
                try await Task.sleep(nanoseconds: 200_000_000)

                await MainActor.run {
                    self.activeProfile = profile.name
                    ProfileHistoryManager.shared.setConnectedProfile(profile.name)
                    self.viewModel.refresh()
                }

                NotificationCenter.default.post(
                    name: Notification.Name(Constants.Notifications.profileConnected),
                    object: nil,
                    userInfo: [Constants.NotificationKeys.profile: profile]
                )
            } catch {
                await MainActor.run {
                    self.showError("Login Failed", message: error.localizedDescription)
                }
            }
        }
    }

    func disconnectAllProfiles() {
        guard let profile = activeProfile else { return }
        Task {
            SessionManager.shared.cleanDisconnect()
            _ = try? await CommandRunner.shared.runCommand("aws", args: ["sso", "logout", "--profile", profile])
            ProfileHistoryManager.shared.clearConnectedProfile()
            await MainActor.run {
                self.activeProfile = nil
                self.viewModel.refresh()
                self.updateStatusIcon()
            }
        }
    }

    func openConsole() {
        guard let activeProfile = activeProfile else { return }
        if let ssoStartUrl = ConfigManager.shared.getSSOStartUrl(for: activeProfile),
           let url = URL(string: ssoStartUrl) {
            NSWorkspace.shared.open(url)
        }
    }

    func openSettings() {
        panel?.close()
        WindowManager.shared.showSettingsWindow()
    }

    func refreshCurrentSession() {
        guard let activeProfile = self.activeProfile else { return }
        refreshSession(for: activeProfile)
    }

    /// Reauths a specific profile (used by the per-profile notification action
    /// and the yellow-state "Sign In" button). refreshSSOSession tries a silent
    /// refresh first and falls back to the browser login when the refresh token
    /// is dead, then restarts monitoring on success.
    func refreshSession(for profileName: String) {
        Task {
            let success = await SessionManager.shared.refreshSSOSession(for: profileName)
            if !success {
                await MainActor.run {
                    showError("Session Refresh Failed",
                             message: "Unable to refresh your SSO session automatically. Please run 'aws sso login --profile \(profileName)' in Terminal.")
                }
            }
        }
    }

    // MARK: - Notification Handlers

    @MainActor
    @objc private func handleProfilesUpdated() {
        viewModel.refresh()
    }

    @MainActor
    @objc private func handleProfileConnected(_ notification: Notification) {
        if let profile = notification.userInfo?[Constants.NotificationKeys.profile] as? AWSProfile {
            activeProfile = profile.name
            ProfileHistoryManager.shared.setConnectedProfile(profile.name)
            updateStatusIcon()
        }
    }

    @MainActor
    @objc private func handleSessionExpired(_ notification: Notification) {
        if let profileName = notification.userInfo?[Constants.NotificationKeys.profileName] as? String {
            ProfileHistoryManager.shared.setProfileDisconnected(profileName)
            if activeProfile == profileName {
                activeProfile = ProfileHistoryManager.shared.getConnectedProfileOriginalName()
            }
        } else {
            ProfileHistoryManager.shared.clearConnectedProfile()
            activeProfile = nil
        }
        viewModel.refresh()
        updateStatusIcon()
    }

    // MARK: - Token Expiration Handling

    private func handleTokenExpirationWarning(profileName: String, timeUntilExpiry: TimeInterval) {
        let level: String
        if timeUntilExpiry <= 0 {
            level = "expired"
        } else if timeUntilExpiry <= 60 {
            level = "critical"
        } else if timeUntilExpiry <= 300 {
            level = "warning"
        } else {
            return
        }

        let key = "\(profileName)-\(level)"
        if let lastSent = lastNotificationSent[key],
           Date().timeIntervalSince(lastSent) < notificationCooldown {
            return
        }
        lastNotificationSent[key] = Date()

        switch level {
        case "expired":
            showTokenExpiredNotification(profileName: profileName)
        case "critical":
            showTokenExpiringNotification(profileName: profileName, timeUntilExpiry: timeUntilExpiry, isCritical: true)
        case "warning":
            showTokenExpiringNotification(profileName: profileName, timeUntilExpiry: timeUntilExpiry, isCritical: false)
        default:
            break
        }
    }

    /// Fires once (per cooldown) when a profile enters the yellow reauth state:
    /// role creds are still valid but the SSO refresh token can no longer renew
    /// them, so the user should sign in again before the creds run out.
    private func handleReauthRequired(profileName: String) {
        let key = "\(profileName)-reauth"
        if let lastSent = lastNotificationSent[key],
           Date().timeIntervalSince(lastSent) < notificationCooldown {
            return
        }
        lastNotificationSent[key] = Date()
        showReauthRequiredNotification(profileName: profileName)
    }

    private func showReauthRequiredNotification(profileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Gateway"
        content.body = "AWS session for '\(profileName)' can't auto-renew — sign in again within the hour to stay connected."
        content.sound = .default

        let signInAction = UNNotificationAction(identifier: "refresh-action", title: "Sign In", options: [.foreground])
        let remindLaterAction = UNNotificationAction(identifier: "remind-later-action", title: "Remind Later", options: [])
        let category = UNNotificationCategory(identifier: "token-expiring", actions: [signInAction, remindLaterAction], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        content.categoryIdentifier = "token-expiring"
        content.userInfo = ["profileName": profileName]

        let request = UNNotificationRequest(identifier: "token-reauth-\(profileName)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func showTokenExpiredNotification(profileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Gateway"
        content.body = "Your AWS SSO session for '\(profileName)' has expired. Please refresh to continue."
        content.sound = .default

        let refreshAction = UNNotificationAction(identifier: "refresh-action", title: "Refresh Session", options: [.foreground])
        let ignoreAction = UNNotificationAction(identifier: "ignore-action", title: "Ignore", options: [])
        let category = UNNotificationCategory(identifier: "token-expired", actions: [refreshAction, ignoreAction], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        content.categoryIdentifier = "token-expired"
        content.userInfo = ["profileName": profileName]

        let request = UNNotificationRequest(identifier: "token-expired-\(profileName)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func showTokenExpiringNotification(profileName: String, timeUntilExpiry: TimeInterval, isCritical: Bool) {
        let minutes = Int(timeUntilExpiry / 60)
        let seconds = Int(timeUntilExpiry.truncatingRemainder(dividingBy: 60))

        let content = UNMutableNotificationContent()
        content.title = "Gateway"

        if isCritical {
            content.body = "Your AWS SSO session for '\(profileName)' expires in \(seconds) seconds!"
            content.sound = .defaultCritical
        } else {
            let timeText = minutes > 0 ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : "\(seconds) seconds"
            content.body = "Your AWS SSO session for '\(profileName)' expires in \(timeText)."
            content.sound = .default
        }

        let refreshAction = UNNotificationAction(identifier: "refresh-action", title: "Refresh Now", options: [.foreground])
        let remindLaterAction = UNNotificationAction(identifier: "remind-later-action", title: "Remind Later", options: [])
        let category = UNNotificationCategory(identifier: "token-expiring", actions: [refreshAction, remindLaterAction], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        content.categoryIdentifier = "token-expiring"
        content.userInfo = ["profileName": profileName]

        let request = UNNotificationRequest(identifier: "token-expiring-\(profileName)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Helpers

    @MainActor
    func showError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
