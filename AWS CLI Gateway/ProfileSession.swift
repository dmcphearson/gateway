import Foundation

struct ProfileSession {
    let profileName: String
    var roleCredExpiryDate: Date?
    var ssoTokenExpiryDate: Date?
    var lastHealthCheck: Date?
    var status: ProfileSessionStatus
    var cacheFileName: String?

    /// Whether the underlying SSO session (refresh token) is still alive.
    /// Set to false when a health check fails with an auth/expiry error so the
    /// UI stops showing a green countdown for a session that can no longer renew.
    var ssoSessionAlive: Bool = true

    /// The roleCredExpiryDate value we last ran a forced-refresh probe against.
    /// Used to ensure the T-60min probe fires only once per credential window
    /// rather than every timer tick during the final hour.
    var probedCredExpiry: Date?

    /// Role credentials reflect the permission set duration (actual usable session).
    /// The SSO access token (60min) auto-refreshes via refresh token — don't use it
    /// as the countdown. Fall back to SSO token only if role creds aren't available.
    ///
    /// Returns nil once the SSO session is known to be dead (a health check failed
    /// or the token has no refresh token), so the countdown zeroes and the status
    /// goes expired instead of optimistically ticking down a session that can no
    /// longer renew.
    var effectiveExpiry: Date? {
        guard ssoSessionAlive else { return nil }
        if let role = roleCredExpiryDate {
            return role
        }
        return ssoTokenExpiryDate
    }

    var timeRemaining: TimeInterval {
        guard let expiry = effectiveExpiry else { return 0 }
        return max(0, expiry.timeIntervalSinceNow)
    }

    /// State of the SSO access token that SDK tools (Terraform) use, which
    /// can lapse while the role-credential countdown still runs.
    func ssoTokenSummary(now: Date = Date()) -> String? {
        guard let expiry = ssoTokenExpiryDate else { return nil }
        if status == .reauthRequired { return "Can't refresh, sign in again" }

        let remaining = Int(expiry.timeIntervalSince(now))
        guard remaining > 0 else { return "Expired" }
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        return hours > 0 ? "Valid, \(hours)h \(minutes)m left" : "Valid, \(minutes)m left"
    }

    var formattedTimeRemaining: String {
        let remaining = timeRemaining
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

enum ProfileSessionStatus: Equatable {
    case connecting
    case active
    /// Role credentials are still valid (countdown > 0) but the last forced
    /// refresh failed — the SSO session can no longer auto-renew, so the user
    /// must browser-reauth before the role creds expire. Shown as yellow.
    case reauthRequired
    case expired
    case error(String)

    static func == (lhs: ProfileSessionStatus, rhs: ProfileSessionStatus) -> Bool {
        switch (lhs, rhs) {
        case (.connecting, .connecting), (.active, .active),
             (.reauthRequired, .reauthRequired), (.expired, .expired):
            return true
        case let (.error(a), .error(b)):
            return a == b
        default:
            return false
        }
    }
}

/// Decides which profiles signed in outside Gateway (a terminal `aws sso login`)
/// to bring online. Only profiles with cached role credentials are connected,
/// since one SSO session covers every profile on it; the rest are only marked
/// signed in so connecting them skips the browser.
enum SessionAdoption {
    struct Candidate: Equatable {
        let name: String
        let sessionLive: Bool
        let hasRoleCredentials: Bool
        /// Disconnected in Gateway by the person; shown as signed in, never auto-connected.
        var dismissed: Bool = false
    }

    struct Plan: Equatable {
        var connect: [String] = []
        var signedIn: Set<String> = []
    }

    static func plan(_ candidates: [Candidate], connected: Set<String>, limit: Int) -> Plan {
        var plan = Plan()
        var slots = max(0, limit - connected.count)
        for candidate in candidates where candidate.sessionLive && !connected.contains(candidate.name) {
            if candidate.hasRoleCredentials && !candidate.dismissed && slots > 0 {
                plan.connect.append(candidate.name)
                slots -= 1
            } else {
                plan.signedIn.insert(candidate.name)
            }
        }
        return plan
    }
}
