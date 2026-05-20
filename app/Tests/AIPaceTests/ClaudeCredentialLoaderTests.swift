import Foundation
import Testing
@testable import AIPace

struct ClaudeCredentialLoaderTests {
    @Test
    func resolveCredentialsPrefersFileOverEnvironment() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "claudeAiOauth": {
                "accessToken": " file-token ",
                "refreshToken": " refresh-token ",
                "expiresAt": "12345",
                "subscriptionType": " pro "
              }
            }
            """.utf8
        ).write(to: credentialsURL)

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "env-token"],
            keychainLoadOverride: .success(nil)
        )

        let resolution = loader.resolveCredentials()

        #expect(resolution.credentials?.source == .file)
        #expect(resolution.credentials?.oauth.accessToken == "file-token")
        #expect(resolution.credentials?.oauth.refreshToken == "refresh-token")
        #expect(resolution.credentials?.oauth.expiresAt == 12345)
        #expect(resolution.credentials?.oauth.subscriptionType == "pro")
    }

    @Test
    func resolveCredentialsFallsBackToEnvironment() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": " env-token \n"],
            keychainLoadOverride: .success(nil)
        )

        let resolution = loader.resolveCredentials()

        #expect(resolution.credentials?.source == .environment)
        #expect(resolution.credentials?.oauth.accessToken == "env-token")
    }

    @Test
    func resolveCredentialsFallsBackToClaudeDesktopTokenCache() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let desktopConfigURL = homeDirectory.appendingPathComponent("desktop-config.json")
        try Data(
            """
            {
              "oauth:tokenCache": "\(Self.encryptedDesktopTokenCache)"
            }
            """.utf8
        ).write(to: desktopConfigURL)

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            desktopConfigURL: desktopConfigURL,
            keychainLoadOverride: .success(nil),
            desktopSafeStoragePasswordOverride: .success("desktop-password")
        )

        let resolution = loader.resolveCredentials()

        #expect(resolution.credentials?.source == .desktop)
        #expect(resolution.credentials?.oauth.accessToken == "desktop-token")
        #expect(resolution.credentials?.oauth.refreshToken == "desktop-refresh")
        #expect(resolution.credentials?.oauth.expiresAt == 123456)
        #expect(resolution.credentials?.oauth.subscriptionType == "claude_max")
    }

    @Test
    func saveCredentialsUpdatesClaudeDesktopTokenCache() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let desktopConfigURL = homeDirectory.appendingPathComponent("desktop-config.json")
        try Data(
            """
            {
              "oauth:tokenCache": "\(Self.encryptedDesktopTokenCache)",
              "kept": true
            }
            """.utf8
        ).write(to: desktopConfigURL)

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            desktopConfigURL: desktopConfigURL,
            keychainLoadOverride: .success(nil),
            desktopSafeStoragePasswordOverride: .success("desktop-password")
        )
        var result = try #require(loader.resolveCredentials().credentials)
        result.oauth.accessToken = "updated-desktop-token"
        result.oauth.refreshToken = "updated-desktop-refresh"
        result.oauth.expiresAt = 789
        result.oauth.subscriptionType = "pro"

        loader.saveCredentials(result)

        let reloaded = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            desktopConfigURL: desktopConfigURL,
            keychainLoadOverride: .success(nil),
            desktopSafeStoragePasswordOverride: .success("desktop-password")
        )
        let updated = reloaded.resolveCredentials().credentials
        let data = try Data(contentsOf: desktopConfigURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["kept"] as? Bool == true)
        #expect(updated?.source == .desktop)
        #expect(updated?.oauth.accessToken == "updated-desktop-token")
        #expect(updated?.oauth.refreshToken == "updated-desktop-refresh")
        #expect(updated?.oauth.expiresAt == 789)
        #expect(updated?.oauth.subscriptionType == "pro")
    }

    @Test
    func needsRefreshHonorsExpiryBuffer() {
        let loader = ClaudeCredentialLoader(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )

        let now = Date().timeIntervalSince1970 * 1000
        let fresh = ClaudeOAuthCredentials(accessToken: "token", refreshToken: nil, expiresAt: now + 10 * 60 * 1000, subscriptionType: nil)
        let expiring = ClaudeOAuthCredentials(accessToken: "token", refreshToken: nil, expiresAt: now + 4 * 60 * 1000, subscriptionType: nil)

        #expect(!loader.needsRefresh(fresh))
        #expect(loader.needsRefresh(expiring))
        #expect(loader.needsRefresh(ClaudeOAuthCredentials(accessToken: "token", refreshToken: nil, expiresAt: nil, subscriptionType: nil)))
    }

    @Test
    func saveCredentialsWritesUpdatedFileContents() throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )
        let result = ClaudeCredentialResult(
            oauth: ClaudeOAuthCredentials(
                accessToken: "updated-token",
                refreshToken: "updated-refresh",
                expiresAt: 999,
                subscriptionType: "claude_max"
            ),
            source: .file,
            fullData: ["existing": "value"]
        )

        loader.saveCredentials(result)

        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        let data = try Data(contentsOf: credentialsURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oauth = try #require(object["claudeAiOauth"] as? [String: Any])

        #expect(object["existing"] as? String == "value")
        #expect(oauth["accessToken"] as? String == "updated-token")
        #expect(oauth["refreshToken"] as? String == "updated-refresh")
        #expect(oauth["expiresAt"] as? Double == 999)
        #expect(oauth["subscriptionType"] as? String == "claude_max")
    }

    @Test
    func mapKeychainErrorCategorizesCommonFailures() throws {
        let loader = ClaudeCredentialLoader(
            homeDirectory: try makeTemporaryDirectory(),
            environment: [:],
            keychainLoadOverride: .success(nil)
        )

        switch loader.mapKeychainError(.terminated(1, "User interaction is not allowed.")) {
        case .failure(let issue):
            #expect(issue == .keychainAccessDenied)
        default:
            Issue.record("Expected access denied classification")
        }

        switch loader.mapKeychainError(.terminated(44, "The specified item could not be found in the keychain.")) {
        case .success(let credentials):
            #expect(credentials == nil)
        default:
            Issue.record("Expected missing keychain item to map to no credentials")
        }
    }

    private static let encryptedDesktopTokenCache = """
    djEw1t3ciMhY5p0gKmEKqWNBS6J3Hdd/KMu06KS9MwEV6By5ydfBpzhwpL9gto1YhCiyEb89IkMwvbSfMz4ikBYCcCukFAZ9DNsBHZVUz0rAZ2bGYph25JnT/bfPdoArWbiDgToPxOjhFDpXmzdHCN0U6/Y8U2ZxTs7C1hHq5TcHXT/iLlXCjGtB3OcEFoJHugbdcADCjB4WitC0C01NNhKppt4mZ/JE9/DlP6QQoZ3j/AEUnYVMdzgwAecRmRyN2yeMhpNa1Tw3NlGMpoFQsBaC8dpxDAlAcO10byHqEb2/yCw=
    """
}
