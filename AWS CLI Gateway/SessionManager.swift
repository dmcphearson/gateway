import Foundation
import CommonCrypto

@MainActor
class SessionManager {
    static let shared = SessionManager()

    // MARK: - Properties

    private(set) var activeSessions: [String: ProfileSession] = [:]
    private var monitoringTasks: [String: Task<Void, Never>] = [:]
    private var sessionTimer: Timer?

    var activeProfile: String? { activeSessions.keys.sorted().first }

    // profileCacheFileMap is read/written from `nonisolated` file-I/O helpers
    // running off the main actor, so it stays lock-guarded and nonisolated.
    private nonisolated let profileCacheFileMapLock = NSLock()
    private nonisolated(unsafe) var _profileCacheFileMap: [String: String] = [:]
    private nonisolated var profileCacheFileMap: [String: String] {
        get {
            profileCacheFileMapLock.lock()
            defer { profileCacheFileMapLock.unlock() }
            return _profileCacheFileMap
        }
        set {
            profileCacheFileMapLock.lock()
            _profileCacheFileMap = newValue
            DispatchQueue.global(qos: .background).async {
                UserDefaults.standard.set(newValue, forKey: "profile_cache_file_map")
            }
            profileCacheFileMapLock.unlock()
        }
    }

    // Callbacks
    var onSessionsUpdated: (([String: ProfileSession]) -> Void)?
    var onTokenExpirationWarning: ((String, TimeInterval) -> Void)?

    private let tokenExpirationWarningThreshold: TimeInterval = 5 * 60
    private let tokenExpirationCriticalThreshold: TimeInterval = 60

    private init() {
        if let savedMap = UserDefaults.standard.dictionary(forKey: "profile_cache_file_map") as? [String: String] {
            profileCacheFileMap = savedMap
        } else {
            profileCacheFileMap = [:]
        }
    }
    
    // REPLACE the existing generateCacheFileHash method with this version
    private nonisolated func generateCacheFileHash(profile: SSOProfile) -> String {
        // Get the session name for this profile
        let sessionName = ConfigManager.shared.getSSOSessionName(for: profile.name)

        if let sessionName = sessionName {

            // Create a components dict with sessionName instead of startUrl
            let components: [String: String] = [
                "accountId": profile.accountId,
                "roleName": profile.roleName,
                "sessionName": sessionName
            ]

            // Create JSON string with alphabetically sorted keys
            guard let jsonData = try? JSONSerialization.data(withJSONObject: components, options: [.sortedKeys]) else {
                print("SessionManager: Failed to create JSON for hash generation")
                return ""
            }

            let jsonString = String(data: jsonData, encoding: .utf8) ?? ""

            // Generate SHA-1 hash
            let data = Data(jsonString.utf8)
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
            data.withUnsafeBytes {
                _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
            }

            // Convert to hex string
            let hashString = digest.map { String(format: "%02x", $0) }.joined()
            return hashString
        } else {
            // Fallback to the old method using startUrl
            return generateLegacyCacheFileHash(
                roleName: profile.roleName,
                accountId: profile.accountId,
                startUrl: profile.startUrl
            )
        }
    }

    // Keep the original method for fallback
    private nonisolated func generateLegacyCacheFileHash(roleName: String, accountId: String, startUrl: String) -> String {
        // This is based on your existing method
        let components: [String: String] = [
            "accountId": accountId,
            "roleName": roleName,
            "startUrl": startUrl
        ]

        // Sort keys and create a JSON string
        guard let jsonData = try? JSONSerialization.data(withJSONObject: components, options: [.sortedKeys]) else {
            print("SessionManager: Failed to create JSON for hash generation")
            return ""
        }

        let jsonString = String(data: jsonData, encoding: .utf8) ?? ""

        // Generate SHA-1 hash
        let data = Data(jsonString.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }

        // Convert to hex string
        let hashString = digest.map { String(format: "%02x", $0) }.joined()
        return hashString
    }

    // MARK: - Public Interface

    @MainActor
    func startMonitoring(for profileName: String) {
        // Cancel any previous task for THIS profile only
        monitoringTasks[profileName]?.cancel()

        // Only invalidate timer if no other sessions are active
        if activeSessions.isEmpty {
            sessionTimer?.invalidate()
            sessionTimer = nil
        }

        // Register this profile as connecting
        activeSessions[profileName] = ProfileSession(
            profileName: profileName,
            status: .connecting
        )

        // Create a new task for this profile. Detached so the file I/O and
        // synchronous token reads run OFF the main actor; all writes to
        // activeSessions hop back via MainActor.run.
        let task = Task.detached { [weak self] in
            guard let self = self else { return }

            // Check for cancellation before proceeding
            if Task.isCancelled { return }

            // First try the content-based approach
            let cacheFilename = await self.findMatchingCacheFile(forProfile: profileName)
            if let cacheFilename = cacheFilename {
                // Check for cancellation

                self.profileCacheFileMap[profileName] = cacheFilename

                let ssoToken = try? await self.readCredentialsFromCacheFile(cacheFilename)
                if let ssoToken = ssoToken {
                    // Check for cancellation

                    // Also read the SSO session token expiry
                    let ssoExpiry = SSOTokenManager.shared.getSSOTokenExpiry(forProfile: profileName)

                    await MainActor.run {
                        if !Task.isCancelled {
                            self.activeSessions[profileName] = ProfileSession(
                                profileName: profileName,
                                roleCredExpiryDate: ssoToken.expiresAt,
                                ssoTokenExpiryDate: ssoExpiry,
                                lastHealthCheck: Date(),
                                status: .active,
                                cacheFileName: cacheFilename
                            )
                            self.startSessionTimer()
                            self.onSessionsUpdated?(self.activeSessions)
                        }
                    }
                    return
                }
            }

            // Check for cancellation
            if Task.isCancelled { return }

            // If that didn't work, try the legacy approach
            if let ssoToken = try? await self.findCLICredentialsForProfile(profileName) {
                // Check for cancellation
                if Task.isCancelled { return }

                let ssoExpiry = SSOTokenManager.shared.getSSOTokenExpiry(forProfile: profileName)

                await MainActor.run {
                    if !Task.isCancelled {
                        self.activeSessions[profileName] = ProfileSession(
                            profileName: profileName,
                            roleCredExpiryDate: ssoToken.expiresAt,
                            ssoTokenExpiryDate: ssoExpiry,
                            lastHealthCheck: Date(),
                            status: .active
                        )
                        self.startSessionTimer()
                        self.onSessionsUpdated?(self.activeSessions)
                    }
                }
                return
            }

            if Task.isCancelled { return }

            // If still no credentials, try to create them by running a command
            do {
                _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profileName])
                if Task.isCancelled { return }

                // Try again after refreshing
                if let cacheFilename = await self.findMatchingCacheFile(forProfile: profileName) {
                    if Task.isCancelled { return }
                    self.profileCacheFileMap[profileName] = cacheFilename
                    if let ssoToken = try? await self.readCredentialsFromCacheFile(cacheFilename) {
                        if Task.isCancelled { return }
                        let ssoExpiry = SSOTokenManager.shared.getSSOTokenExpiry(forProfile: profileName)
                        await MainActor.run {
                            if !Task.isCancelled {
                                self.activeSessions[profileName] = ProfileSession(
                                    profileName: profileName,
                                    roleCredExpiryDate: ssoToken.expiresAt,
                                    ssoTokenExpiryDate: ssoExpiry,
                                    lastHealthCheck: Date(),
                                    status: .active,
                                    cacheFileName: cacheFilename
                                )
                                self.startSessionTimer()
                                self.onSessionsUpdated?(self.activeSessions)
                            }
                        }
                        return
                    }
                }

                if Task.isCancelled { return }

                // Final fallback - legacy approach
                if let ssoToken = try? await self.findCLICredentialsForProfile(profileName) {
                    if Task.isCancelled { return }
                    let ssoExpiry = SSOTokenManager.shared.getSSOTokenExpiry(forProfile: profileName)
                    await MainActor.run {
                        if !Task.isCancelled {
                            self.activeSessions[profileName] = ProfileSession(
                                profileName: profileName,
                                roleCredExpiryDate: ssoToken.expiresAt,
                                ssoTokenExpiryDate: ssoExpiry,
                                lastHealthCheck: Date(),
                                status: .active
                            )
                            self.startSessionTimer()
                            self.onSessionsUpdated?(self.activeSessions)
                        }
                    }
                    return
                }

                await MainActor.run {
                    if !Task.isCancelled {
                        self.activeSessions[profileName]?.status = .expired
                        self.onSessionsUpdated?(self.activeSessions)
                    }
                }
            } catch {
                await MainActor.run {
                    if !Task.isCancelled {
                        let errorMessage = self.parseAWSError(error)
                        print("SessionManager: Failed to refresh credentials: \(errorMessage)")
                        self.activeSessions[profileName]?.status = .expired
                        self.onSessionsUpdated?(self.activeSessions)
                        if errorMessage.contains("Token is expired") || errorMessage.contains("TokenExpired") {
                            self.onTokenExpirationWarning?(profileName, 0)
                        }
                    }
                }
            }
        }
        monitoringTasks[profileName] = task
    }

    // MARK: - Error Parsing

    /// Parses AWS CLI error messages to provide more meaningful feedback
    private nonisolated func parseAWSError(_ error: Error) -> String {
        let errorString = error.localizedDescription

        // Check for common AWS SSO error patterns
        if errorString.contains("Token is expired") ||
           errorString.contains("TokenExpired") ||
           errorString.contains("The SSO session associated with this profile has expired") {
            return "SSO token has expired - please refresh your session"
        }

        if errorString.contains("UnauthorizedOperation") ||
           errorString.contains("InvalidUserID.NotFound") {
            return "Authentication failed - profile may not have proper permissions"
        }

        if errorString.contains("ProfileNotFound") ||
           errorString.contains("The config profile") {
            return "Profile configuration not found"
        }

        if errorString.contains("NoCredentialsError") ||
           errorString.contains("Unable to locate credentials") {
            return "No valid credentials found - SSO session may need to be established"
        }

        if errorString.contains("SSOTokenLoadError") ||
           errorString.contains("SSO Token has expired") {
            return "SSO token expired - session refresh required"
        }

        // Return the original error if we can't parse it
        return errorString
    }

    // MARK: - Token Expiration Checking

    func checkTokenExpiration(for profileName: String) async -> Bool {
        guard let session = activeSessions[profileName],
              let expiry = session.effectiveExpiry else {
            return false
        }

        let timeUntilExpiry = expiry.timeIntervalSinceNow

        if timeUntilExpiry <= 0 {
            await MainActor.run { self.onTokenExpirationWarning?(profileName, 0) }
            return false
        } else if timeUntilExpiry <= tokenExpirationCriticalThreshold {
            await MainActor.run { self.onTokenExpirationWarning?(profileName, timeUntilExpiry) }
            return false
        } else if timeUntilExpiry <= tokenExpirationWarningThreshold {
            await MainActor.run { self.onTokenExpirationWarning?(profileName, timeUntilExpiry) }
            return true
        }

        return true
    }

    /// Attempts to refresh the SSO session for a profile.
    /// First tries a silent refresh via sts get-caller-identity (uses refresh token).
    /// Only falls back to aws sso login (browser) if the refresh token is dead.
    func refreshSSOSession(for profileName: String) async -> Bool {
        print("SessionManager: Attempting to refresh session for profile \(profileName)")

        // Step 1: Try silent refresh — sts get-caller-identity forces CLI to use refresh token
        do {
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profileName])

            // Re-read the refreshed cache files
            profileCacheFileMap.removeValue(forKey: profileName)
            try await Task.sleep(nanoseconds: 500_000_000)

            if let cacheFilename = await findMatchingCacheFile(forProfile: profileName),
               let token = try? await readCredentialsFromCacheFile(cacheFilename),
               token.expiresAt > Date() {

                profileCacheFileMap[profileName] = cacheFilename
                let ssoExpiry = SSOTokenManager.shared.getSSOTokenExpiry(forProfile: profileName)

                await MainActor.run {
                    self.activeSessions[profileName] = ProfileSession(
                        profileName: profileName,
                        roleCredExpiryDate: token.expiresAt,
                        ssoTokenExpiryDate: ssoExpiry,
                        lastHealthCheck: Date(),
                        status: .active,
                        cacheFileName: cacheFilename
                    )
                    self.startSessionTimer()
                    self.onSessionsUpdated?(self.activeSessions)
                }
                return true
            }

            return true

        } catch {
            let errorString = "\(error)"
            print("SessionManager: Silent refresh failed for \(profileName): \(errorString)")

            let needsBrowser = errorString.contains("ExpiredToken") ||
                errorString.contains("InvalidIdentityToken") ||
                errorString.contains("The SSO session") ||
                errorString.contains("Token has expired") ||
                errorString.contains("UnauthorizedAccess") ||
                errorString.contains("SSOTokenLoadError")

            if !needsBrowser { return false }
        }

        // Refresh token is dead — fall back to browser login
        do {
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sso", "login", "--profile", profileName])
            try await Task.sleep(nanoseconds: 1_000_000_000)

            profileCacheFileMap.removeValue(forKey: profileName)
            if let cacheFilename = await findMatchingCacheFile(forProfile: profileName),
               let token = try? await readCredentialsFromCacheFile(cacheFilename),
               token.expiresAt > Date() {

                profileCacheFileMap[profileName] = cacheFilename
                let ssoExpiry = SSOTokenManager.shared.getSSOTokenExpiry(forProfile: profileName)

                await MainActor.run {
                    self.activeSessions[profileName] = ProfileSession(
                        profileName: profileName,
                        roleCredExpiryDate: token.expiresAt,
                        ssoTokenExpiryDate: ssoExpiry,
                        lastHealthCheck: Date(),
                        status: .active,
                        cacheFileName: cacheFilename
                    )
                    self.startSessionTimer()
                    self.onSessionsUpdated?(self.activeSessions)
                }
                return true
            }
            return false
        } catch {
            print("SessionManager: Browser login failed for \(profileName): \(error)")
            await MainActor.run {
                self.activeSessions[profileName]?.status = .expired
                self.onSessionsUpdated?(self.activeSessions)
            }
            return false
        }
    }

    // MARK: - Cache Management

    /// Clears all cached file mappings to force fresh discovery
    nonisolated func clearCacheFileMappings() {
        profileCacheFileMap.removeAll()
    }

    /// Clears cache mapping for a specific profile
    nonisolated func clearCacheFileMapping(for profileName: String) {
        profileCacheFileMap.removeValue(forKey: profileName)
    }

    // MARK: - Improved Cache File Finding

    private nonisolated func findMatchingCacheFile(forProfile profileName: String) async -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cliCachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        // First check if we already have a valid mapping
        if let knownCacheFile = profileCacheFileMap[profileName],
           FileManager.default.fileExists(atPath: cliCachePath.appendingPathComponent(knownCacheFile).path),
           let token = try? await readCredentialsFromCacheFile(knownCacheFile),
           token.expiresAt > Date() {
            return knownCacheFile
        }


        // Get profile details for comparison
        guard let profile = ConfigManager.shared.getProfile(profileName) else {
            return nil
        }

        // For SSO profiles, try to compute the exact hash first
        if let ssoProfile = profile as? SSOProfile {
            let expectedHash = generateCacheFileHash(
                profile: ssoProfile
            )

            if !expectedHash.isEmpty {
                let expectedFilename = "\(expectedHash).json"
                let expectedPath = cliCachePath.appendingPathComponent(expectedFilename)

                if FileManager.default.fileExists(atPath: expectedPath.path) {

                    // Verify it has valid credentials before returning
                    if let token = try? await readCredentialsFromCacheFile(expectedFilename),
                       token.expiresAt > Date() {
                        // Store this mapping for future use
                        profileCacheFileMap[profileName] = expectedFilename
                        return expectedFilename
                    } else {
                    }
                } else {
                }
            }
        }

        do {
            // Get all JSON files in the cache directory with modification dates
            let cacheFiles = try FileManager.default.contentsOfDirectory(at: cliCachePath, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" && $0.lastPathComponent != ".DS_Store" }

            // Sort by modification date (newest first) to prioritize recently updated files
            let sortedCacheFiles = cacheFiles.sorted { file1, file2 in
                guard let date1 = try? file1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      let date2 = try? file2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                    return false
                }
                return date1 > date2
            }


            // For each file, try to read it and check for a strong match
            for file in sortedCacheFiles {
                if let data = try? Data(contentsOf: file),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                    // For SSO profiles - STRICT matching
                    if let ssoProfile = profile as? SSOProfile {
                        // Check role ARN - must contain exact account ID and role name
                        if let roleArn = json["RoleArn"] as? String {
                            let roleArnPattern = "arn:aws:iam::\(ssoProfile.accountId):role/\(ssoProfile.roleName)"
                            if roleArn == roleArnPattern {
                                return file.lastPathComponent
                            }
                        }

                        // Look for account ID and role name in Credentials
                        if let credentialProcess = json["CredentialProcess"] as? String,
                           credentialProcess.contains(ssoProfile.accountId),
                           credentialProcess.contains(ssoProfile.roleName) {
                            return file.lastPathComponent
                        }

                        // Check for exact profile name in ConfigFile
                        if let configFile = json["ConfigFile"] as? String,
                           configFile.contains("[profile \(profileName)]") {
                            return file.lastPathComponent
                        }

                        // Check content for all three critical components
                        let fileContent = String(data: data, encoding: .utf8) ?? ""
                        if fileContent.contains(ssoProfile.accountId) &&
                           fileContent.contains(ssoProfile.roleName) &&
                           fileContent.contains(ssoProfile.startUrl) {
                            return file.lastPathComponent
                        }
                    }

                    // IAM role profile matching remains similar
                    if let iamProfile = profile as? IAMProfile {
                        if let assumedRoleUser = json["assumedRoleUser"] as? [String: Any],
                           let arn = assumedRoleUser["arn"] as? String {

                            let roleArnParts = iamProfile.roleArn.split(separator: "/")
                            if let roleName = roleArnParts.last,
                               arn.contains(String(roleName)) {
                                return file.lastPathComponent
                            }
                        }
                    }
                }
            }

            return nil

        } catch {
            print("SessionManager: Error searching cache files: \(error)")
            return nil
        }
    }
    
    // Read credentials from a specific cache file
    private nonisolated func readCredentialsFromCacheFile(_ filename: String) async throws -> SSOToken? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cliCachePath = homeDir.appendingPathComponent(".aws/cli/cache")
        let cacheFilePath = cliCachePath.appendingPathComponent(filename)

        if !FileManager.default.fileExists(atPath: cacheFilePath.path) {
            return nil
        }

        do {
            let data = try Data(contentsOf: cacheFilePath)
            let decoder = JSONDecoder()

            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)

                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]

                if let date = formatter.date(from: dateString) {
                    return date
                }

                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date")
            }

            // Try SSO format first
            if let ssoCredentials = try? decoder.decode(AWSCliCredentials.self, from: data) {
                let expiresAt = ssoCredentials.credentials.expiration

                if expiresAt > Date() {
                    return SSOToken(expiresAt: expiresAt)
                } else {
                    return nil
                }
            }
            // Then try IAM role format
            else if let iamCredentials = try? decoder.decode(IAMRoleCredentials.self, from: data) {
                let expiresAt = iamCredentials.credentials.expiration

                if expiresAt > Date() {
                    return SSOToken(expiresAt: expiresAt)
                } else {
                    return nil
                }
            }

            return nil
        } catch {
            return nil
        }
    }

    /// Forces a role-credential mint to test whether the SSO refresh token is
    /// still valid. This is the only authoritative liveness test: it clears the
    /// cached role creds so the AWS CLI is forced to mint fresh ones via the
    /// refresh token. To avoid destroying the user's still-valid creds when the
    /// refresh token is dead, the cache file is backed up first and restored on
    /// failure. Returns true if a fresh mint succeeded (session healthy).
    private nonisolated func probeRefresh(profileName: String, cacheFileName: String?) async -> Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cliCachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        // Resolve the role-cred cache file for this profile.
        let resolvedName = cacheFileName ?? profileCacheFileMap[profileName]
        guard let resolvedName = resolvedName else {
            // No known cache file — fall back to a plain mint attempt. Success
            // means creds are obtainable; failure means reauth is needed.
            do {
                _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profileName])
                return true
            } catch {
                return false
            }
        }

        let cacheFile = cliCachePath.appendingPathComponent(resolvedName)
        let backupFile = cliCachePath.appendingPathComponent("\(resolvedName).probe-backup")

        let fm = FileManager.default
        let hadCacheFile = fm.fileExists(atPath: cacheFile.path)

        // Back up, then remove the cache file so botocore must re-mint.
        if hadCacheFile {
            try? fm.removeItem(at: backupFile)               // clear any stale backup
            try? fm.copyItem(at: cacheFile, to: backupFile)
            try? fm.removeItem(at: cacheFile)
        }

        do {
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profileName])
            // Success: fresh creds are in the cache now. Drop the backup.
            try? fm.removeItem(at: backupFile)
            return true
        } catch {
            // Failure: restore the user's still-valid creds so they keep the
            // remaining time behind the yellow indicator.
            if hadCacheFile {
                try? fm.removeItem(at: cacheFile)            // remove any partial file
                try? fm.copyItem(at: backupFile, to: cacheFile)
                try? fm.removeItem(at: backupFile)
            }
            return false
        }
    }


    private nonisolated func findCLICredentialsForProfile(_ profileName: String) async throws -> SSOToken? {

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cliCachePath = homeDir.appendingPathComponent(".aws/cli/cache")

        // Check for a known mapping first
        if let knownCacheFile = profileCacheFileMap[profileName] {
            let cacheFilePath = cliCachePath.appendingPathComponent(knownCacheFile)

            if FileManager.default.fileExists(atPath: cacheFilePath.path),
               let token = try? await readCredentialsFromCacheFile(knownCacheFile),
               token.expiresAt > Date() {
                return token
            } else {
                // Known mapping is invalid, remove it
                profileCacheFileMap.removeValue(forKey: profileName)
            }
        }

        // Get profile details for strong matching
        guard let profile = ConfigManager.shared.getProfile(profileName) else {
            return nil
        }

        // For SSO profiles, try to compute the exact hash
        if let ssoProfile = profile as? SSOProfile {
            let expectedHash = generateCacheFileHash(
                profile: ssoProfile
            )

            if !expectedHash.isEmpty {
                let expectedFilename = "\(expectedHash).json"
                let expectedPath = cliCachePath.appendingPathComponent(expectedFilename)

                if FileManager.default.fileExists(atPath: expectedPath.path) {

                    if let token = try? await readCredentialsFromCacheFile(expectedFilename),
                       token.expiresAt > Date() {
                        profileCacheFileMap[profileName] = expectedFilename
                        return token
                    }
                }
            }
        }

        // Get all cache files sorted by modification time
        guard let cacheFiles = try? FileManager.default.contentsOfDirectory(at: cliCachePath, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }

        // Build list of files with their modification dates
        var filesWithDates: [(URL, Date)] = []
        for file in cacheFiles.filter({ $0.pathExtension == "json" && $0.lastPathComponent != ".DS_Store" }) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modDate = attributes[.modificationDate] as? Date {
                filesWithDates.append((file, modDate))
            }
        }

        // Sort by modification date (newest first)
        let sortedFiles = filesWithDates.sorted { $0.1 > $1.1 }

        // IMPORTANT: We're removing the "use any valid credential" fallback!
        // Instead, we'll only match credentials that are likely for this profile

        for (file, _) in sortedFiles {
            do {
                let data = try Data(contentsOf: file)

                // For more precise matching, check file contents first
                if let ssoProfile = profile as? SSOProfile {
                    let fileContent = String(data: data, encoding: .utf8) ?? ""

                    // Only consider files that contain BOTH the account ID and role name
                    // This is a minimal bar to avoid using credentials from totally unrelated profiles
                    if !fileContent.contains(ssoProfile.accountId) || !fileContent.contains(ssoProfile.roleName) {
                        continue  // Skip this file if it doesn't contain both critical identifiers
                    }
                }

                // Now try to parse the file
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)

                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]

                    if let date = formatter.date(from: dateString) {
                        return date
                    }

                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date")
                }

                // Try SSO format
                if let ssoCredentials = try? decoder.decode(AWSCliCredentials.self, from: data),
                   ssoCredentials.credentials.expiration > Date() {

                    // Strong match for SSO profiles - additional verification
                    if let ssoProfile = profile as? SSOProfile,
                       let roleArn = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let roleArnStr = roleArn["RoleArn"] as? String {

                        let expectedArn = "arn:aws:iam::\(ssoProfile.accountId):role/\(ssoProfile.roleName)"
                        if roleArnStr == expectedArn {
                            profileCacheFileMap[profileName] = file.lastPathComponent
                            return SSOToken(expiresAt: ssoCredentials.credentials.expiration)
                        }
                    } else {
                        // Still save this as a fallback, but with a warning
                        profileCacheFileMap[profileName] = file.lastPathComponent
                        return SSOToken(expiresAt: ssoCredentials.credentials.expiration)
                    }
                }

                // Try IAM format with precise matching for IAM profiles
                if let iamCredentials = try? decoder.decode(IAMRoleCredentials.self, from: data),
                   iamCredentials.credentials.expiration > Date() {

                    if let iamProfile = profile as? IAMProfile {
                        // For IAM profiles, check if the ARN contains the role name
                        let arn = iamCredentials.assumedRoleUser.arn
                        let roleArnParts = iamProfile.roleArn.split(separator: "/")

                        if let roleName = roleArnParts.last, arn.contains(String(roleName)) {
                            profileCacheFileMap[profileName] = file.lastPathComponent
                            return SSOToken(expiresAt: iamCredentials.credentials.expiration)
                        }
                    }
                }
            } catch {
            }
        }

        return nil
    }

    // For AWS CLI SSO Credentials format
    struct AWSCliCredentials: Codable {
        let providerType: String
        let credentials: Credentials

        struct Credentials: Codable {
            let accessKeyId: String
            let secretAccessKey: String
            let sessionToken: String
            let expiration: Date

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

    // IAM role credentials format struct
    private struct IAMRoleCredentials: Codable {
        let credentials: Credentials
        let assumedRoleUser: AssumedRoleUser

        struct Credentials: Codable {
            let accessKeyId: String
            let secretAccessKey: String
            let sessionToken: String
            let expiration: Date

            enum CodingKeys: String, CodingKey {
                case accessKeyId = "AccessKeyId"
                case secretAccessKey = "SecretAccessKey"
                case sessionToken = "SessionToken"
                case expiration = "Expiration"
            }
        }

        struct AssumedRoleUser: Codable {
            let assumedRoleId: String
            let arn: String

            enum CodingKeys: String, CodingKey {
                case assumedRoleId = "AssumedRoleId"
                case arn = "Arn"
            }
        }

        enum CodingKeys: String, CodingKey {
            case credentials = "Credentials"
            case assumedRoleUser = "AssumedRoleUser"
        }
    }

    func cleanDisconnect() {
        activeSessions.removeAll()
        monitoringTasks.values.forEach { $0.cancel() }
        monitoringTasks.removeAll()
        sessionTimer?.invalidate()
        sessionTimer = nil
        onSessionsUpdated?(activeSessions)
    }

    func cleanDisconnect(for profileName: String) {
        activeSessions.removeValue(forKey: profileName)
        monitoringTasks[profileName]?.cancel()
        monitoringTasks.removeValue(forKey: profileName)

        if activeSessions.isEmpty {
            sessionTimer?.invalidate()
            sessionTimer = nil
        }

        onSessionsUpdated?(activeSessions)
    }

    func stopMonitoring() {
        activeSessions.removeAll()
        monitoringTasks.values.forEach { $0.cancel() }
        monitoringTasks.removeAll()
        sessionTimer?.invalidate()
        sessionTimer = nil
        onSessionsUpdated?(activeSessions)

        NotificationCenter.default.post(
            name: Notification.Name(Constants.Notifications.sessionMonitoringStopped),
            object: nil
        )
    }

    func stopMonitoring(for profileName: String) {
        activeSessions.removeValue(forKey: profileName)
        monitoringTasks[profileName]?.cancel()
        monitoringTasks.removeValue(forKey: profileName)

        if activeSessions.isEmpty {
            stopMonitoring()
        } else {
            onSessionsUpdated?(activeSessions)
            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.sessionMonitoringStopped),
                object: nil,
                userInfo: [Constants.NotificationKeys.profileName: profileName]
            )
        }
    }

    func renewSession() async throws {
        guard let profile = activeProfile else {
            throw SessionError.noActiveProfile
        }

        monitoringTasks[profile]?.cancel()

        do {
            // 1) Logout old session
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sso", "logout", "--profile", profile])

            // 2) Clear local cache
            ConfigManager.shared.clearCache()

            // 3) Clear the mapping for this profile
            profileCacheFileMap.removeValue(forKey: profile)

            // 4) Login again
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sso", "login", "--profile", profile])

            // 5) Force creation of fresh credentials
            _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profile])

            // 6) Update expirationDate and restart the timer
            startMonitoring(for: profile)

            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.sessionRenewed),
                object: nil
            )
        } catch {
            throw SessionError.renewalFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    private func startSessionTimer() {
        assert(Thread.isMainThread, "startSessionTimer must be called on the main thread")
        guard !activeSessions.isEmpty else { return }

        sessionTimer?.invalidate()
        self.sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // The timer fires on the main RunLoop, so we are genuinely on the
            // main actor — assume isolation to call the @MainActor methods.
            MainActor.assumeIsolated {
                guard let self = self, !self.activeSessions.isEmpty else { return }
                self.checkSessionStatus()
            }
        }
        RunLoop.current.add(self.sessionTimer!, forMode: .common)
        self.checkSessionStatus()
    }
    


    private var expiryRefreshTime: Date? = nil
    private let healthCheckInterval: TimeInterval = 300 // 5 minutes

    private nonisolated let tokenRefresher = SSOTokenRefresher()
    private var refreshingSSOSessions: Set<String> = []

    /// The sso-session a profile signs in through: its own for SSO profiles,
    /// the source's for IAM role profiles chained from one.
    nonisolated func ssoSessionName(for profileName: String) -> String? {
        if let name = ConfigManager.shared.getSSOSessionName(for: profileName) {
            return name
        }
        if let iamProfile = ConfigManager.shared.getProfile(profileName) as? IAMProfile,
           !iamProfile.ssoSession.isEmpty {
            return iamProfile.ssoSession
        }
        return nil
    }

    /// Refreshes the SSO access token of every sso-session behind the active
    /// profiles (once per session, however many profiles share it).
    private func keepSSOTokensFresh() {
        let profileNames = Array(activeSessions.keys)
        Task.detached { [weak self] in
            guard let self = self else { return }
            let profilesBySession = Dictionary(grouping: profileNames) { self.ssoSessionName(for: $0) }
            for case let (sessionName?, profiles) in profilesBySession {
                let claimed = await MainActor.run { self.refreshingSSOSessions.insert(sessionName).inserted }
                guard claimed else { continue }
                let outcome = await self.refreshSSOToken(sessionName: sessionName)
                await MainActor.run {
                    self.refreshingSSOSessions.remove(sessionName)
                    self.applySSOTokenOutcome(outcome, profiles: profiles)
                }
            }
        }
    }

    private nonisolated func refreshSSOToken(sessionName: String) async -> SSOTokenRefresher.Outcome {
        let outcome = await tokenRefresher.refreshIfNeeded(sessionName: sessionName)
        switch outcome {
        case .refreshed(let expiresAt):
            print("[AWSCLIGateway] SSO token for session \(sessionName) refreshed, expires \(expiresAt)")
        case .needsLogin(let reason), .failed(let reason):
            print("[AWSCLIGateway] Error: \(reason)")
        case .fresh, .alreadyRefreshed:
            break
        }
        return outcome
    }

    private func applySSOTokenOutcome(_ outcome: SSOTokenRefresher.Outcome, profiles: [String]) {
        for profileName in profiles where activeSessions[profileName] != nil {
            switch outcome {
            case .refreshed(let expiresAt):
                activeSessions[profileName]?.ssoTokenExpiryDate = expiresAt
                fallthrough
            case .alreadyRefreshed:
                // A refresh that just worked proves the session can renew;
                // clear a yellow state left by an earlier failure or probe.
                if activeSessions[profileName]?.status == .reauthRequired {
                    activeSessions[profileName]?.status = .active
                    activeSessions[profileName]?.ssoSessionAlive = true
                }
            case .needsLogin:
                // Role creds may still work for the CLI, but SDK tools that use
                // the SSO token (Terraform) are already failing: show yellow.
                if activeSessions[profileName]?.status == .active {
                    activeSessions[profileName]?.status = .reauthRequired
                }
            case .fresh, .failed:
                break
            }
        }
        onSessionsUpdated?(activeSessions)
    }

    private func checkSessionStatus() {
        guard !activeSessions.isEmpty else { return }

        let now = Date()

        // Every 60 seconds: re-read cache files for all active sessions
        if expiryRefreshTime == nil || now.timeIntervalSince(expiryRefreshTime!) > 60 {
            expiryRefreshTime = now
            keepSSOTokensFresh()

            for (profileName, session) in activeSessions {
                let cacheNameHint = session.cacheFileName ?? profileCacheFileMap[profileName]
                let priorRoleExpiry = session.roleCredExpiryDate
                Task.detached { [weak self] in
                    guard let self = self else { return }
                    if await self.activeSessions.isEmpty { return }

                    var updatedRoleExpiry: Date? = priorRoleExpiry
                    if let cacheFilename = cacheNameHint,
                       let token = try? await self.readCredentialsFromCacheFile(cacheFilename) {
                        updatedRoleExpiry = token.expiresAt
                    }

                    let updatedSSOExpiry = SSOTokenManager.shared.getSSOTokenExpiry(forProfile: profileName)
                    // A token file without a refresh token can't silently renew —
                    // treat the session as dead once its access token lapses.
                    let hasRefresh = SSOTokenManager.shared.hasRefreshToken(forProfile: profileName)
                    let ssoDead = !hasRefresh && (updatedSSOExpiry == nil || updatedSSOExpiry! <= Date())

                    await MainActor.run {
                        guard self.activeSessions[profileName] != nil else { return }
                        self.activeSessions[profileName]?.roleCredExpiryDate = updatedRoleExpiry
                        self.activeSessions[profileName]?.ssoTokenExpiryDate = updatedSSOExpiry
                        if ssoDead {
                            self.activeSessions[profileName]?.ssoSessionAlive = false
                        }
                    }
                }
            }
        }

        // Health check: check every profile whose interval is due, not just one
        // per tick. Per-profile rate limiting is preserved by lastHealthCheck +
        // healthCheckInterval (each profile re-checks at most once per interval),
        // so detection latency is ≤ healthCheckInterval regardless of how many
        // profiles are active (previously up to N × interval with the round-robin).
        if !activeSessions.isEmpty {
            let profileNames = Array(activeSessions.keys).sorted()
            for profileName in profileNames {
                guard let session = activeSessions[profileName] else { continue }
                let sessionLastCheck = session.lastHealthCheck ?? .distantPast
                if now.timeIntervalSince(sessionLastCheck) > healthCheckInterval {
                    activeSessions[profileName]?.lastHealthCheck = now

                    Task.detached { [weak self] in
                        guard let self = self else { return }
                        if await self.activeSessions.isEmpty { return }
                        do {
                            _ = try await CommandRunner.shared.runCommand("aws", args: ["sts", "get-caller-identity", "--profile", profileName])
                        } catch {
                            let errorString = "\(error)"
                            if errorString.contains("ExpiredToken") || errorString.contains("InvalidIdentityToken") ||
                               errorString.contains("UnauthorizedAccess") || errorString.contains("The SSO session") {
                                print("SessionManager: Health check failed for \(profileName): \(errorString)")
                                await MainActor.run {
                                    if !self.activeSessions.isEmpty {
                                        self.activeSessions[profileName]?.ssoSessionAlive = false
                                        self.activeSessions[profileName]?.status = .expired
                                        self.onSessionsUpdated?(self.activeSessions)
                                        NotificationCenter.default.post(
                                            name: Notification.Name(Constants.Notifications.sessionExpired),
                                            object: nil,
                                            userInfo: [Constants.NotificationKeys.profileName: profileName]
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Proactive refresh-token probe: when role creds drop within 60 min of
        // expiry, force a real mint (clear cache + sts get-caller-identity) to
        // test whether the refresh token still works. On success the user gets a
        // fresh ~12h window silently; on failure we mark the profile yellow
        // (.reauthRequired) while they keep the remaining valid creds and an
        // hour of warning. Probe once per credential window (probedCredExpiry).
        let probeThreshold: TimeInterval = 60 * 60
        for (profileName, session) in activeSessions {
            if let roleExpiry = session.roleCredExpiryDate,
               roleExpiry.timeIntervalSinceNow > 0,
               roleExpiry.timeIntervalSinceNow <= probeThreshold,
               session.status == .active,
               session.probedCredExpiry != roleExpiry {
                // Mark immediately so we don't re-probe every tick this window.
                activeSessions[profileName]?.probedCredExpiry = roleExpiry
                let cacheName = session.cacheFileName
                Task.detached { [weak self] in
                    guard let self = self else { return }
                    if await self.activeSessions.isEmpty { return }
                    let ok = await self.probeRefresh(profileName: profileName, cacheFileName: cacheName)
                    if ok {
                        // Fresh creds minted — re-read the new ~12h expiry.
                        let newName = cacheName ?? self.profileCacheFileMap[profileName]
                        let newExpiry = (newName != nil)
                            ? (try? await self.readCredentialsFromCacheFile(newName!))?.expiresAt
                            : nil
                        await MainActor.run {
                            guard self.activeSessions[profileName] != nil else { return }
                            if let newExpiry = newExpiry {
                                self.activeSessions[profileName]?.roleCredExpiryDate = newExpiry
                            }
                            self.activeSessions[profileName]?.ssoSessionAlive = true
                            self.activeSessions[profileName]?.status = .active
                            self.activeSessions[profileName]?.probedCredExpiry = nil
                            self.onSessionsUpdated?(self.activeSessions)
                        }
                    } else {
                        // Refresh token is dead — yellow until the user reauths.
                        await MainActor.run {
                            guard self.activeSessions[profileName] != nil else { return }
                            self.activeSessions[profileName]?.ssoSessionAlive = false
                            self.activeSessions[profileName]?.status = .reauthRequired
                            self.onSessionsUpdated?(self.activeSessions)
                        }
                    }
                }
                break // One probe per tick
            }
        }

        // Update status for all active sessions
        var anyExpired = false
        for (profileName, session) in activeSessions {
            let willExpire: Bool
            if let expiry = session.effectiveExpiry {
                willExpire = expiry.timeIntervalSinceNow <= 0
            } else {
                willExpire = true
            }

            if willExpire {
                // If the profile was yellow (failed probe) and has now run out
                // the clock, escalate to the reauth notification so the user
                // gets the one-click sign-in prompt.
                if session.status == .reauthRequired {
                    NotificationCenter.default.post(
                        name: Notification.Name(Constants.Notifications.sessionExpired),
                        object: nil,
                        userInfo: [Constants.NotificationKeys.profileName: profileName]
                    )
                }
                activeSessions[profileName]?.status = .expired
                anyExpired = true
            } else if session.status != .reauthRequired {
                // Preserve a yellow (failed-probe) state until creds actually
                // expire; otherwise a still-valid countdown reads as active.
                activeSessions[profileName]?.status = .active
            }
        }

        self.onSessionsUpdated?(activeSessions)

        // Post time update for the primary profile
        if let primarySession = activeSessions.values.first,
           let expiry = primarySession.effectiveExpiry {
            let remaining = max(0, expiry.timeIntervalSinceNow)
            NotificationCenter.default.post(
                name: Notification.Name(Constants.Notifications.sessionTimeUpdated),
                object: nil,
                userInfo: [Constants.NotificationKeys.timeRemaining: remaining]
            )
            checkWarningThresholds(remaining)
        }
    }

    private func checkWarningThresholds(_ remaining: TimeInterval) {

        for threshold in Constants.Session.warningThresholds {
            if remaining <= threshold && remaining > threshold - 1 {
                NotificationCenter.default.post(
                    name: Notification.Name(Constants.Notifications.sessionWarning),
                    object: nil,
                    userInfo: [
                        Constants.NotificationKeys.timeRemaining: remaining,
                        Constants.NotificationKeys.threshold: threshold
                    ]
                )
            }
        }
    }
}

// MARK: - Errors
enum SessionError: LocalizedError {
    case noActiveProfile
    case renewalFailed(String)

    var errorDescription: String? {
        switch self {
        case .noActiveProfile:
            return "No active profile selected"
        case .renewalFailed(let message):
            return "Session renewal failed: \(message)"
        }
    }
}
