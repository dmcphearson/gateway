import Foundation
import CommonCrypto

// Define the AWS CLI credentials format
struct AWSCliCredentials: Codable {
    let providerType: String
    let credentials: Credentials

    struct Credentials: Codable {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String
        let expiration: Date

        // Add CodingKeys to match the capitalized JSON field names
        enum CodingKeys: String, CodingKey {
            case accessKeyId = "AccessKeyId"
            case secretAccessKey = "SecretAccessKey"
            case sessionToken = "SessionToken"
            case expiration = "Expiration"
        }
    }

    enum CodingKeys: String, CodingKey {
        case providerType = "ProviderType"
        case credentials = "Credentials"
    }
}

// Update SSOToken to be more flexible
struct SSOToken: Codable {
    // Make required fields optional so we can work with both formats
    let startUrl: String?
    let region: String?
    let accessToken: String?
    let expiresAt: Date
    let clientId: String?
    let clientSecret: String?
    let refreshToken: String?
    let sessionName: String?

    enum CodingKeys: String, CodingKey {
        case startUrl
        case region
        case accessToken
        case expiresAt
        case clientId
        case clientSecret
        case refreshToken
        case sessionName
    }

    // Custom initializer to support creating from CLI credentials
    init(expiresAt: Date, startUrl: String? = nil, region: String? = nil,
         accessToken: String? = nil, clientId: String? = nil, clientSecret: String? = nil,
         refreshToken: String? = nil, sessionName: String? = nil) {
        self.startUrl = startUrl
        self.region = region
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
        self.sessionName = sessionName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Make these fields optional for flexibility
        startUrl = try container.decodeIfPresent(String.self, forKey: .startUrl)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)

        if let expiresAtString = try? container.decode(String.self, forKey: .expiresAt),
           let date = SSOTokenManager.parseISO8601(expiresAtString) {
            expiresAt = date
        } else {
            expiresAt = Date()
        }

        clientId = try container.decodeIfPresent(String.self, forKey: .clientId)
        clientSecret = try container.decodeIfPresent(String.self, forKey: .clientSecret)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
    }
}

class SSOTokenManager {
    static let shared = SSOTokenManager()

    private init() {}

    static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static var iso8601DecodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            guard let date = parseISO8601(dateString) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
            }
            return date
        }
    }

    // Model for token info
    struct TokenInfo {
        let isValid: Bool
        let expiresAt: Date
        let remainingTime: TimeInterval

        var isExpired: Bool {
            return Date() >= expiresAt
        }
    }

    // Retrieves token information for a specific SSO session
    func getTokenInfo(startUrl: String, region: String) -> TokenInfo? {
        // First try SSO cache
        if let tokenInfo = getTokenInfoFromSSOCache(startUrl: startUrl, region: region) {
            return tokenInfo
        }

        // If not found, try CLI cache
        if let tokenInfo = getTokenInfoFromCLICache() {
            return tokenInfo
        }

        return nil
    }

    func getSSOTokenExpiry(forProfile profileName: String) -> Date? {
        guard let tokenFilePath = findTokenFile(forProfile: profileName),
              let tokenData = try? Data(contentsOf: tokenFilePath),
              let tokenDict = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let expiresAtString = tokenDict["expiresAt"] as? String else {
            return nil
        }
        return Self.parseISO8601(expiresAtString)
    }

    /// Whether the SSO session for this profile can still silently renew.
    /// A token file with a `refreshToken` can refresh the ~60min access token
    /// in the background; without one, `expiresAt` is a hard ceiling and the
    /// session is effectively dead once the access token lapses.
    func hasRefreshToken(forProfile profileName: String) -> Bool {
        guard let tokenFilePath = findTokenFile(forProfile: profileName),
              let tokenData = try? Data(contentsOf: tokenFilePath),
              let tokenDict = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any] else {
            return false
        }
        return tokenDict["refreshToken"] != nil
    }

    private func getTokenInfoFromSSOCache(startUrl: String, region: String) -> TokenInfo? {
        guard let tokenFilePath = findTokenFileByContent(startUrl: startUrl, region: region),
              let tokenData = try? Data(contentsOf: tokenFilePath),
              let tokenDict = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
              let expiresAtString = tokenDict["expiresAt"] as? String,
              let expiresAt = Self.parseISO8601(expiresAtString) else {
            return nil
        }
        let remainingTime = expiresAt.timeIntervalSince(Date())
        return TokenInfo(isValid: remainingTime > 0, expiresAt: expiresAt, remainingTime: remainingTime)
    }

    private func getTokenInfoFromCLICache() -> TokenInfo? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: cachePath, includingPropertiesForKeys: nil) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = Self.iso8601DecodingStrategy

        for file in cacheFiles where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let cliCredentials = try? decoder.decode(AWSCliCredentials.self, from: data) else {
                continue
            }
            let expiresAt = cliCredentials.credentials.expiration
            let remainingTime = expiresAt.timeIntervalSince(Date())
            return TokenInfo(isValid: remainingTime > 0, expiresAt: expiresAt, remainingTime: remainingTime)
        }

        return nil
    }

    func getTokenForProfile(_ profileName: String) async throws -> SSOToken? {

        // Try both SSO token and CLI token formats
        if let token = try await getSSOModeTokenForProfile(profileName) {
            return token
        }

        if let token = try await getCLIModeTokenForProfile(profileName) {
            return token
        }

        return nil
    }

    // Get token in SSO format
    private func getSSOModeTokenForProfile(_ profileName: String) async throws -> SSOToken? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cachePath = homeDir.appendingPathComponent(".aws/sso/cache")

        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: cachePath, includingPropertiesForKeys: nil) else {
            return nil
        }

        // Try to find the config file to get the SSO session name
        let ssoSessionName = try getSSOSessionNameForProfile(profileName)


        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = Self.iso8601DecodingStrategy

        for file in cacheFiles where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                if let token = try? decoder.decode(SSOToken.self, from: data) {
                    // Match by session name (from file content or filename hash)
                    if let sessionName = ssoSessionName {
                        if token.sessionName == sessionName || file.deletingPathExtension().lastPathComponent == Self.sha1Hash(sessionName) {
                            return token
                        }
                    } else if token.startUrl != nil && token.accessToken != nil && token.expiresAt > Date() {
                        // Legacy mode (no sso_session): match by startUrl via profile config
                        let profiles = ConfigManager.shared.getProfiles()
                        if let ssoProfile = profiles.first(where: { $0.name == profileName }) as? SSOProfile,
                           token.startUrl == ssoProfile.startUrl {
                            return token
                        }
                    }
                }
            } catch {
                continue
            }
        }

        return nil
    }

    // Get token in CLI format
    private func getCLIModeTokenForProfile(_ profileName: String) async throws -> SSOToken? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: cachePath, includingPropertiesForKeys: nil) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = Self.iso8601DecodingStrategy

        for file in cacheFiles where file.pathExtension == "json" && file.lastPathComponent != ".DS_Store" {
            guard let data = try? Data(contentsOf: file),
                  let cliCredentials = try? decoder.decode(AWSCliCredentials.self, from: data),
                  cliCredentials.credentials.expiration > Date() else {
                continue
            }
            return SSOToken(expiresAt: cliCredentials.credentials.expiration)
        }

        return nil
    }

    // Helper method to get SSO session name from profile
    private func getSSOSessionNameForProfile(_ profileName: String) throws -> String? {
        // Read the AWS config file
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configPath = homeDir.appendingPathComponent(".aws/config")

        guard let configContents = try? String(contentsOf: configPath, encoding: .utf8) else {
            return nil
        }

        // Look for the profile section
        let profilePattern = "\\[profile \(profileName)\\]([^\\[]*)?"
        guard let profileRange = configContents.range(of: profilePattern, options: .regularExpression) else {
            return nil
        }

        let profileSection = configContents[profileRange]

        // Look for sso_session within that section
        let ssoSessionPattern = "sso_session\\s*=\\s*([^\\s\\n]+)"
        guard let ssoSessionMatch = profileSection.range(of: ssoSessionPattern, options: .regularExpression) else {
            return nil
        }

        let ssoSessionLine = profileSection[ssoSessionMatch]

        // Extract just the session name
        let sessionNamePattern = "=\\s*([^\\s\\n]+)"
        guard let sessionNameMatch = ssoSessionLine.range(of: sessionNamePattern, options: .regularExpression) else {
            return nil
        }

        let sessionNameWithEquals = ssoSessionLine[sessionNameMatch]
        let sessionName = sessionNameWithEquals.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines)

        return sessionName
    }

    /// Finds the SSO token file for a profile using botocore-compatible hash logic.
    /// New-style config (sso_session block): sha1(sessionName)
    /// Legacy config (no sso_session): sha1(startUrl)
    private func findTokenFile(forProfile profileName: String) -> URL? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cacheDirPath = homeDir.appendingPathComponent(".aws/sso/cache")

        let sessionName = ConfigManager.shared.getSSOSessionName(for: profileName)
        let profiles = ConfigManager.shared.getProfiles()
        let startUrl = (profiles.first(where: { $0.name == profileName }) as? SSOProfile)?.startUrl

        // Compute hash per botocore: sha1(sessionName) if available, else sha1(startUrl)
        let hashInput: String?
        if let sessionName = sessionName {
            hashInput = sessionName
        } else if let startUrl = startUrl {
            hashInput = startUrl
        } else {
            hashInput = nil
        }

        if let hashInput = hashInput {
            let hash = Self.sha1Hash(hashInput)
            let potentialTokenFile = cacheDirPath.appendingPathComponent("\(hash).json")
            if FileManager.default.fileExists(atPath: potentialTokenFile.path) {
                return potentialTokenFile
            }
        }

        // Fallback: content scan matching by session name or startUrl
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: cacheDirPath, includingPropertiesForKeys: nil) else {
            return nil
        }

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Match by sessionName field if we have one
            if let sessionName = sessionName,
               let fileSessionName = json["sessionName"] as? String,
               fileSessionName == sessionName {
                return fileURL
            }

            // Match by startUrl for legacy configs (must also have accessToken to be a token file)
            if sessionName == nil,
               let startUrl = startUrl,
               let storedStartUrl = json["startUrl"] as? String,
               storedStartUrl == startUrl,
               json["accessToken"] != nil {
                return fileURL
            }
        }

        return nil
    }

    /// Content-based fallback for getTokenInfoFromSSOCache (used by legacy getTokenInfo API)
    private func findTokenFileByContent(startUrl: String, region: String) -> URL? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cacheDirPath = homeDir.appendingPathComponent(".aws/sso/cache")

        // Try hash of just startUrl first (legacy botocore behavior)
        let hash = Self.sha1Hash(startUrl)
        let potentialTokenFile = cacheDirPath.appendingPathComponent("\(hash).json")
        if FileManager.default.fileExists(atPath: potentialTokenFile.path) {
            return potentialTokenFile
        }

        // Fallback to content scan
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: cacheDirPath, includingPropertiesForKeys: nil) else {
            return nil
        }

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let storedStartUrl = json["startUrl"] as? String,
                  storedStartUrl == startUrl,
                  json["accessToken"] != nil else {
                continue
            }
            return fileURL
        }

        return nil
    }

    // SHA1 hash function (simplified version)
    static func sha1Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }

        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}

// MARK: - SSO Token Refresh

/// Keeps the SSO access token for an `sso-session` fresh in ~/.aws/sso/cache.
///
/// Tools that resolve SSO profiles themselves (Terraform and the other Go SDK
/// users) read this token, not the AWS CLI's role credentials in
/// ~/.aws/cli/cache. The access token lives ~1h and nothing refreshes it while
/// the CLI keeps working from cached role credentials, so those tools fail
/// even though the app's countdown looks healthy.
struct SSOTokenRefresher: Sendable {
    enum Outcome: Equatable {
        /// Token has more than `refreshWindow` left; nothing to do.
        case fresh
        /// Token refreshed and written back.
        case refreshed(expiresAt: Date)
        /// Another tool rotated the refresh token while we were refreshing.
        case alreadyRefreshed
        /// The refresh token or client registration is unusable; the user has
        /// to run `aws sso login --sso-session <name>`.
        case needsLogin(String)
        /// Transient failure (network, server error); try again next cycle.
        case failed(String)
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Start refreshing this long before expiry: ahead of the AWS CLI (15 min)
    /// and Go SDK (5 min) windows, so the app is normally the only refresher
    /// and two tools never race the same rotating refresh token.
    static let refreshWindow: TimeInterval = 20 * 60

    let cacheDirectory: URL
    let transport: Transport

    init(cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws/sso/cache"),
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.cacheDirectory = cacheDirectory
        self.transport = transport
    }

    /// botocore and the Go SDK name the token file sha1(session name).
    func tokenFile(forSession sessionName: String) -> URL {
        cacheDirectory.appendingPathComponent("\(SSOTokenManager.sha1Hash(sessionName)).json")
    }

    func refreshIfNeeded(sessionName: String, now: Date = Date()) async -> Outcome {
        let file = tokenFile(forSession: sessionName)
        guard let token = readToken(file) else {
            return .needsLogin("No SSO token cached for session \(sessionName)")
        }

        if let expiresAt = date(token["expiresAt"]),
           expiresAt.timeIntervalSince(now) > Self.refreshWindow {
            return .fresh
        }

        guard let refreshToken = token["refreshToken"] as? String,
              let clientId = token["clientId"] as? String,
              let clientSecret = token["clientSecret"] as? String,
              let region = token["region"] as? String else {
            return .needsLogin("SSO token for session \(sessionName) has no refresh token")
        }
        if let registrationExpiresAt = date(token["registrationExpiresAt"]), registrationExpiresAt <= now {
            return .needsLogin("SSO client registration for session \(sessionName) has expired")
        }

        guard let url = URL(string: "https://oidc.\(region).amazonaws.com/token") else {
            return .failed("Invalid SSO region \(region)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "grantType": "refresh_token",
            "refreshToken": refreshToken,
        ])

        let data: Data
        let status: Int
        do {
            let (body, response) = try await transport(request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return .failed("SSO token refresh request failed: \(error.localizedDescription)")
        }

        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard status == 200 else {
            let error = (body["error"] as? String) ?? (body["__type"] as? String) ?? "HTTP \(status)"
            guard error == "invalid_grant" || error.contains("InvalidGrant") || error == "invalid_client" else {
                return .failed("SSO token refresh failed: \(error)")
            }
            // The refresh token is rejected. If another tool rotated it while
            // we were refreshing, the session is fine; otherwise it's dead.
            if let current = readToken(file), current["refreshToken"] as? String != refreshToken {
                return .alreadyRefreshed
            }
            return .needsLogin("SSO refresh token for session \(sessionName) was rejected (\(error))")
        }

        guard let accessToken = body["accessToken"] as? String,
              let expiresIn = (body["expiresIn"] as? NSNumber)?.doubleValue else {
            return .failed("SSO token refresh returned an unexpected response")
        }

        // Update in place so fields other tools rely on (startUrl, clientId,
        // registrationExpiresAt, ...) are preserved.
        let expiresAt = now.addingTimeInterval(expiresIn)
        var updated = token
        updated["accessToken"] = accessToken
        updated["expiresAt"] = Self.formatDate(expiresAt)
        if let rotated = body["refreshToken"] as? String {
            updated["refreshToken"] = rotated
        }

        do {
            try writeToken(updated, to: file)
        } catch {
            return .failed("Could not write SSO token cache: \(error.localizedDescription)")
        }
        return .refreshed(expiresAt: expiresAt)
    }

    private func readToken(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Writes via a 0600 temp file and rename so readers never see a partial
    /// file and the token is never world-readable.
    private func writeToken(_ token: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: token)
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temp.path, file.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private func date(_ value: Any?) -> Date? {
        (value as? String).flatMap(SSOTokenManager.parseISO8601)
    }

    /// botocore writes `2026-01-01T13:00:00Z` (UTC, no fractional seconds).
    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
