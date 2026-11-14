import Foundation

/// 形如 `1.0.12` 或 `v1.0.12` 的版本号，按数字逐段比较，缺的段按 0 处理。
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        if let suffix = value.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            value = String(value[..<suffix])
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            components.append(number)
        }
        self.components = components
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

struct AvailableUpdate: Equatable, Sendable {
    let version: AppVersion
    let tagName: String
    let notes: String
    let pageURL: URL
    let archiveURL: URL
    let archiveSize: Int
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL
        let size: Int

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    let tagName: String
    let body: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }

    /// 只接受正式版且带 App 压缩包的 release；版本号来自标签。
    var update: AvailableUpdate? {
        guard !draft, !prerelease, let version = AppVersion(tagName) else { return nil }
        let archives = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        guard let archive = archives.first(where: { $0.name.hasPrefix("SSClip") }) ?? archives.first else {
            return nil
        }
        return AvailableUpdate(
            version: version,
            tagName: tagName,
            notes: body ?? "",
            pageURL: htmlURL,
            archiveURL: archive.browserDownloadURL,
            archiveSize: archive.size
        )
    }
}

enum UpdateCheckError: LocalizedError {
    case badResponse(Int)
    case noInstallableRelease

    var errorDescription: String? {
        switch self {
        case let .badResponse(status):
            "GitHub 返回了错误（HTTP \(status)）"
        case .noInstallableRelease:
            "最新 release 中没有可安装的 App"
        }
    }
}

struct UpdateChecker: Sendable {
    static let repository = "dandibbert/ssclip"

    var latestReleaseURL = URL(string: "https://api.github.com/repos/\(UpdateChecker.repository)/releases/latest")!
    var session: URLSession = .shared

    func fetchLatest(currentVersion: String) async throws -> AvailableUpdate {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SSClip/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateCheckError.badResponse(http.statusCode)
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let update = release.update else { throw UpdateCheckError.noInstallableRelease }
        return update
    }
}
