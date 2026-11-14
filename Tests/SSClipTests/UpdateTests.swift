import Foundation
import Testing
@testable import SSClip

struct UpdateTests {
    @Test func versionsCompareNumericallyBySegment() throws {
        let v1_0_9 = try #require(AppVersion("1.0.9"))
        let v1_0_10 = try #require(AppVersion("v1.0.10"))
        #expect(v1_0_9 < v1_0_10)
        #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
        #expect(AppVersion("0.1.0")! < AppVersion("1.0.1")!)
        #expect(AppVersion("1.2.0-beta.1")! == AppVersion("1.2.0")!)
        #expect(v1_0_10.description == "1.0.10")
    }

    @Test func malformedVersionsAreRejected() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("personal-v1") == nil)
    }

    @Test func releasePicksTheAppArchive() throws {
        let release = try decode(release(assets: [
            ("SSClip-1.0.4.dmg", "https://example.com/SSClip-1.0.4.dmg"),
            ("SSClip-1.0.4.sha256", "https://example.com/SSClip-1.0.4.sha256"),
            ("SSClip-1.0.4.zip", "https://example.com/SSClip-1.0.4.zip")
        ]))
        let update = try #require(release.update)
        #expect(update.version == AppVersion("1.0.4"))
        #expect(update.tagName == "v1.0.4")
        #expect(update.archiveURL.absoluteString == "https://example.com/SSClip-1.0.4.zip")
        #expect(update.notes == "说明")
        #expect(update.pageURL.absoluteString == "https://github.com/dandibbert/ssclip/releases/tag/v1.0.4")
    }

    @Test func releaseWithoutArchiveOrMarkedPrereleaseIsIgnored() throws {
        #expect(try decode(release(assets: [("SSClip-1.0.4.dmg", "https://example.com/a.dmg")])).update == nil)
        #expect(try decode(release(prerelease: true)).update == nil)
        #expect(try decode(release(tag: "nightly")).update == nil)
    }

    @Test @MainActor func onlyNewerReleasesAreOffered() throws {
        let update = try #require(decode(release()).update)
        #expect(UpdateController.isNewer(update, than: "1.0.3"))
        #expect(UpdateController.isNewer(update, than: "0.1.0"))
        #expect(!UpdateController.isNewer(update, than: "1.0.4"))
        #expect(!UpdateController.isNewer(update, than: "1.1"))
    }

    @Test @MainActor func automaticCheckRunsOncePerDay() {
        let now = Date()
        #expect(UpdateController.isDue(lastChecked: nil, now: now))
        #expect(!UpdateController.isDue(lastChecked: now.addingTimeInterval(-60 * 60), now: now))
        #expect(UpdateController.isDue(lastChecked: now.addingTimeInterval(-25 * 60 * 60), now: now))
        #expect(UpdateController.isDue(lastChecked: now.addingTimeInterval(60 * 60), now: now))
    }

    @Test @MainActor func automaticChecksSettingPersistsAndDefaultsToOn() throws {
        let suiteName = "SSClipUpdateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.automaticallyChecksForUpdates)
        settings.automaticallyChecksForUpdates = false
        #expect(!AppSettings(defaults: defaults).automaticallyChecksForUpdates)
    }

    private func decode(_ json: String) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    private func release(
        tag: String = "v1.0.4",
        prerelease: Bool = false,
        assets: [(String, String)] = [("SSClip-1.0.4.zip", "https://example.com/SSClip-1.0.4.zip")]
    ) -> String {
        let assetJSON = assets.map { name, url in
            #"{"name":"\#(name)","browser_download_url":"\#(url)","size":1234,"content_type":"application/zip"}"#
        }.joined(separator: ",")
        return """
        {"tag_name":"\(tag)","name":"SSClip","body":"说明","draft":false,"prerelease":\(prerelease),\
        "html_url":"https://github.com/dandibbert/ssclip/releases/tag/\(tag)","assets":[\(assetJSON)]}
        """
    }
}
