import CommonCrypto
import Foundation

struct ClaudeOAuthCredentials: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
}

enum ClaudeCredentialSource: Sendable, Equatable {
    case file
    case keychain
    case environment
    case desktop
}

enum ClaudeCredentialLoadIssue: Error, Sendable, Equatable {
    case keychainAccessDenied
    case keychainFailure(String)

    var message: String {
        switch self {
        case .keychainAccessDenied:
            return "Claude Keychain access denied."
        case .keychainFailure(let message):
            return message
        }
    }
}

struct ClaudeCredentialResult: @unchecked Sendable {
    var oauth: ClaudeOAuthCredentials
    let source: ClaudeCredentialSource
    var fullData: [String: Any]
}

struct ClaudeCredentialResolution {
    let credentials: ClaudeCredentialResult?
    let issue: ClaudeCredentialLoadIssue?
}

struct ClaudeCredentialLoader {
    private let homeDirectory: URL
    private let environment: [String: String]
    private let keychainService: String
    private let desktopConfigURL: URL
    private let desktopSafeStorageService: String
    private let desktopSafeStorageAccount: String
    private let keychainLoadOverride: Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue>?
    private let keychainSaveOverride: (@Sendable (ClaudeCredentialResult) -> Void)?
    private let desktopSafeStoragePasswordOverride: Result<String?, ClaudeCredentialLoadIssue>?
    private static let refreshBufferMs: Double = 5 * 60 * 1000
    private static let desktopTokenCacheKey = "oauth:tokenCache"

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainService: String = "Claude Code-credentials",
        desktopConfigURL: URL? = nil,
        desktopSafeStorageService: String = "Claude Safe Storage",
        desktopSafeStorageAccount: String = "Claude Key",
        keychainLoadOverride: Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue>? = nil,
        keychainSaveOverride: (@Sendable (ClaudeCredentialResult) -> Void)? = nil,
        desktopSafeStoragePasswordOverride: Result<String?, ClaudeCredentialLoadIssue>? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.keychainService = keychainService
        self.desktopConfigURL = desktopConfigURL
            ?? homeDirectory.appendingPathComponent("Library/Application Support/Claude/config.json")
        self.desktopSafeStorageService = desktopSafeStorageService
        self.desktopSafeStorageAccount = desktopSafeStorageAccount
        self.keychainLoadOverride = keychainLoadOverride
        self.keychainSaveOverride = keychainSaveOverride
        self.desktopSafeStoragePasswordOverride = desktopSafeStoragePasswordOverride
    }

    func loadCredentials() -> ClaudeCredentialResult? {
        resolveCredentials().credentials
    }

    func resolveCredentials() -> ClaudeCredentialResolution {
        if let credentials = loadFromFile() {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        let keychainResult = loadFromKeychain()
        if case .success(let credentials) = keychainResult, let credentials {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        if let credentials = loadFromEnvironment() {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        let desktopResult = loadFromClaudeDesktop()
        if case .success(let credentials) = desktopResult, let credentials {
            return ClaudeCredentialResolution(credentials: credentials, issue: nil)
        }

        switch keychainResult {
        case .success:
            switch desktopResult {
            case .success:
                return ClaudeCredentialResolution(credentials: nil, issue: nil)
            case .failure(let issue):
                return ClaudeCredentialResolution(credentials: nil, issue: issue)
            }
        case .failure(let issue):
            return ClaudeCredentialResolution(credentials: nil, issue: issue)
        }
    }

    func needsRefresh(_ oauth: ClaudeOAuthCredentials) -> Bool {
        guard let expiresAt = oauth.expiresAt else {
            return true
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return nowMs + Self.refreshBufferMs >= expiresAt
    }

    func saveCredentials(_ result: ClaudeCredentialResult) {
        switch result.source {
        case .file:
            saveToFile(result)
        case .keychain:
            saveToKeychain(result)
        case .environment:
            return
        case .desktop:
            saveToClaudeDesktop(result)
        }
    }

    private func credentialsFileURL() -> URL {
        homeDirectory.appendingPathComponent(".claude/.credentials.json")
    }

    private func loadFromFile() -> ClaudeCredentialResult? {
        let url = credentialsFileURL()
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return nil
        }
        return makeCredentialResult(from: root, source: .file)
    }

    private func loadFromKeychain() -> Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue> {
        if let keychainLoadOverride {
            return keychainLoadOverride
        }

        do {
            let output = try ProcessRunner.runSync(
                executable: "/usr/bin/security",
                arguments: ["find-generic-password", "-s", keychainService, "-w"],
                input: nil,
                timeout: nil,
                currentDirectory: nil
            )

            guard
                let data = output.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data),
                let root = object as? [String: Any]
            else {
                return .success(nil)
            }

            return .success(makeCredentialResult(from: root, source: .keychain))
        } catch let error as ProcessRunnerError {
            return mapKeychainError(error)
        } catch {
            return .failure(.keychainFailure("Claude Keychain lookup failed: \(error.localizedDescription)"))
        }
    }

    private func loadFromEnvironment() -> ClaudeCredentialResult? {
        guard let rawToken = environment["CLAUDE_CODE_OAUTH_TOKEN"] else {
            return nil
        }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return nil
        }

        return ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(accessToken: token, refreshToken: nil, expiresAt: nil, subscriptionType: nil),
            source: .environment,
            fullData: [:]
        )
    }

    private func loadFromClaudeDesktop() -> Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue> {
        guard
            FileManager.default.fileExists(atPath: desktopConfigURL.path),
            let data = try? Data(contentsOf: desktopConfigURL),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let encryptedTokenCache = root[Self.desktopTokenCacheKey] as? String,
            !encryptedTokenCache.isEmpty
        else {
            return .success(nil)
        }

        let passwordResult = loadDesktopSafeStoragePassword()
        guard case .success(let password) = passwordResult else {
            if case .failure(let issue) = passwordResult {
                return .failure(issue)
            }
            return .success(nil)
        }
        guard let password, !password.isEmpty else {
            return .success(nil)
        }

        guard let plaintext = decryptClaudeDesktopValue(encryptedTokenCache, password: password) else {
            return .failure(.keychainFailure("Claude Desktop credentials could not be decrypted."))
        }
        guard
            let tokenData = plaintext.data(using: .utf8),
            let tokenObject = try? JSONSerialization.jsonObject(with: tokenData),
            let tokenCache = tokenObject as? [String: Any]
        else {
            return .failure(.keychainFailure("Claude Desktop token cache was not valid JSON."))
        }

        return .success(makeDesktopCredentialResult(from: tokenCache, root: root))
    }

    private func loadDesktopSafeStoragePassword() -> Result<String?, ClaudeCredentialLoadIssue> {
        if let desktopSafeStoragePasswordOverride {
            return desktopSafeStoragePasswordOverride
        }

        do {
            let output = try ProcessRunner.runSync(
                executable: "/usr/bin/security",
                arguments: [
                    "find-generic-password",
                    "-s", desktopSafeStorageService,
                    "-a", desktopSafeStorageAccount,
                    "-w",
                ],
                input: nil,
                timeout: nil,
                currentDirectory: nil
            )
            let password = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return password.isEmpty ? .success(nil) : .success(password)
        } catch let error as ProcessRunnerError {
            switch mapKeychainError(error) {
            case .success:
                return .success(nil)
            case .failure(let issue):
                return .failure(issue)
            }
        } catch {
            return .failure(.keychainFailure("Claude Desktop Keychain lookup failed: \(error.localizedDescription)"))
        }
    }

    private func makeCredentialResult(from root: [String: Any], source: ClaudeCredentialSource) -> ClaudeCredentialResult? {
        guard
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let rawToken = oauth["accessToken"] as? String
        else {
            return nil
        }

        let accessToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            return nil
        }

        return ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: trimmed(oauth["refreshToken"] as? String),
                expiresAt: parseExpiresAt(oauth["expiresAt"]),
                subscriptionType: trimmed(oauth["subscriptionType"] as? String)
            ),
            source: source,
            fullData: root
        )
    }

    private func makeDesktopCredentialResult(
        from tokenCache: [String: Any],
        root: [String: Any]
    ) -> ClaudeCredentialResult? {
        let preferredEntries = tokenCache
            .compactMap { key, value -> (String, [String: Any])? in
                guard let entry = value as? [String: Any] else { return nil }
                return (key, entry)
            }
            .sorted { lhs, rhs in
                let lhsIsCode = lhs.0.contains("user:sessions:claude_code")
                let rhsIsCode = rhs.0.contains("user:sessions:claude_code")
                if lhsIsCode != rhsIsCode {
                    return lhsIsCode
                }
                return lhs.0 < rhs.0
            }

        for (key, entry) in preferredEntries {
            guard let token = trimmed(entry["token"] as? String) else {
                continue
            }

            var fullData = root
            fullData["desktopTokenCache"] = tokenCache
            fullData["desktopTokenCacheEntryKey"] = key
            return ClaudeCredentialResult(
                oauth: ClaudeOAuthCredentials(
                    accessToken: token,
                    refreshToken: trimmed(entry["refreshToken"] as? String),
                    expiresAt: parseExpiresAt(entry["expiresAt"]),
                    subscriptionType: trimmed(entry["subscriptionType"] as? String)
                ),
                source: .desktop,
                fullData: fullData
            )
        }

        return nil
    }

    private func saveToFile(_ result: ClaudeCredentialResult) {
        let url = credentialsFileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let root = updatedFullData(for: result) else {
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func saveToKeychain(_ result: ClaudeCredentialResult) {
        if let keychainSaveOverride {
            keychainSaveOverride(result)
            return
        }

        guard
            let root = updatedFullData(for: result),
            let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }

        _ = try? ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["delete-generic-password", "-s", keychainService],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        )

        _ = try? ProcessRunner.runSync(
            executable: "/usr/bin/security",
            arguments: ["add-generic-password", "-s", keychainService, "-w", json],
            input: nil,
            timeout: 10,
            currentDirectory: nil
        )
    }

    private func saveToClaudeDesktop(_ result: ClaudeCredentialResult) {
        guard
            var tokenCache = result.fullData["desktopTokenCache"] as? [String: Any],
            let entryKey = result.fullData["desktopTokenCacheEntryKey"] as? String,
            var entry = tokenCache[entryKey] as? [String: Any]
        else {
            return
        }

        entry["token"] = result.oauth.accessToken
        if let refreshToken = result.oauth.refreshToken {
            entry["refreshToken"] = refreshToken
        }
        if let expiresAt = result.oauth.expiresAt {
            entry["expiresAt"] = expiresAt
        }
        if let subscriptionType = result.oauth.subscriptionType {
            entry["subscriptionType"] = subscriptionType
        }
        tokenCache[entryKey] = entry

        var root = readDesktopConfigRoot() ?? result.fullData
        root.removeValue(forKey: "desktopTokenCache")
        root.removeValue(forKey: "desktopTokenCacheEntryKey")

        guard
            let password = try? desktopSafeStoragePassword(),
            let tokenCacheData = try? JSONSerialization.data(withJSONObject: tokenCache, options: [.sortedKeys]),
            let tokenCacheJSON = String(data: tokenCacheData, encoding: .utf8),
            let encryptedTokenCache = encryptClaudeDesktopValue(tokenCacheJSON, password: password)
        else {
            return
        }

        root[Self.desktopTokenCacheKey] = encryptedTokenCache
        guard JSONSerialization.isValidJSONObject(root) else {
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: desktopConfigURL, options: .atomic)
    }

    private func readDesktopConfigRoot() -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: desktopConfigURL),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            return nil
        }
        return root
    }

    private func desktopSafeStoragePassword() throws -> String {
        switch loadDesktopSafeStoragePassword() {
        case .success(let password):
            guard let password, !password.isEmpty else {
                throw ClaudeCredentialLoadIssue.keychainFailure("Claude Desktop Safe Storage key was not found.")
            }
            return password
        case .failure(let issue):
            throw issue
        }
    }

    private func updatedFullData(for result: ClaudeCredentialResult) -> [String: Any]? {
        var root = result.fullData
        var oauth: [String: Any] = [
            "accessToken": result.oauth.accessToken,
        ]
        if let refreshToken = result.oauth.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt = result.oauth.expiresAt {
            oauth["expiresAt"] = expiresAt
        }
        if let subscriptionType = result.oauth.subscriptionType {
            oauth["subscriptionType"] = subscriptionType
        }
        root["claudeAiOauth"] = oauth
        return root
    }

    private func parseExpiresAt(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func decryptClaudeDesktopValue(_ encryptedValue: String, password: String) -> String? {
        guard var data = Data(base64Encoded: encryptedValue) else {
            return nil
        }
        if data.starts(with: Data("v10".utf8)) {
            data.removeFirst(3)
        }
        return cryptClaudeDesktopValue(data, password: password, operation: CCOperation(kCCDecrypt))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    private func encryptClaudeDesktopValue(_ value: String, password: String) -> String? {
        guard let data = value.data(using: .utf8) else {
            return nil
        }
        guard let encrypted = cryptClaudeDesktopValue(data, password: password, operation: CCOperation(kCCEncrypt)) else {
            return nil
        }
        return (Data("v10".utf8) + encrypted).base64EncodedString()
    }

    private func cryptClaudeDesktopValue(_ data: Data, password: String, operation: CCOperation) -> Data? {
        guard let key = claudeDesktopSafeStorageKey(password: password) else {
            return nil
        }

        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0

        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                iv.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            return nil
        }

        output.removeSubrange(outputLength..<output.count)
        return output
    }

    private func claudeDesktopSafeStorageKey(password: String) -> Data? {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count

        let status = key.withUnsafeMutableBytes { keyBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes,
                passwordBytes.count,
                saltBytes,
                saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                keyBytes.bindMemory(to: UInt8.self).baseAddress,
                keyLength
            )
        }

        return status == kCCSuccess ? key : nil
    }

    func mapKeychainError(_ error: ProcessRunnerError) -> Result<ClaudeCredentialResult?, ClaudeCredentialLoadIssue> {
        guard case .terminated(_, let output) = error else {
            return .failure(.keychainFailure(error.localizedDescription))
        }

        let normalized = output.lowercased()
        if normalized.contains("could not be found in the keychain") || normalized.contains("item could not be found") {
            return .success(nil)
        }

        if normalized.contains("user interaction is not allowed")
            || normalized.contains("authorization was denied")
            || normalized.contains("user canceled")
            || normalized.contains("user cancelled") {
            return .failure(.keychainAccessDenied)
        }

        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return .failure(.keychainFailure("Claude Keychain lookup failed."))
        }
        return .failure(.keychainFailure("Claude Keychain lookup failed: \(message)"))
    }
}
