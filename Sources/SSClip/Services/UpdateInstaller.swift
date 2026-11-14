import AppKit
import Foundation
import Security

enum UpdateInstallError: LocalizedError {
    case notRunningFromAppBundle
    case translocated
    case notWritable(String)
    case toolFailed(String, Int32)
    case appMissingInArchive
    case wrongBundle(String?)
    case notNewer(String)
    case signatureMismatch(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notRunningFromAppBundle:
            "当前不是从 SSClip.app 运行，无法自动更新"
        case .translocated:
            "SSClip 正在 macOS 的隔离位置运行。请先把 SSClip.app 移到“应用程序”文件夹再更新"
        case let .notWritable(path):
            "没有权限替换 \(path)，请手动下载新版本"
        case let .toolFailed(tool, status):
            "\(tool) 执行失败（状态 \(status)）"
        case .appMissingInArchive:
            "下载的压缩包里没有 SSClip.app"
        case let .wrongBundle(identifier):
            "下载的 App 标识不符（\(identifier ?? "无")）"
        case let .notNewer(version):
            "下载的 App 版本（\(version)）不比当前版本新"
        case let .signatureMismatch(status):
            "下载的 App 签名与当前 App 不一致，已拒绝安装（\(status)）"
        }
    }
}

/// 下载 release 里的 App 压缩包，校验后原地替换当前 App 并重新启动。
@MainActor
struct UpdateInstaller {
    var bundle: Bundle = .main
    var session: URLSession = .shared

    func install(_ update: AvailableUpdate) async throws {
        let currentApp = bundle.bundleURL.resolvingSymlinksInPath()
        guard currentApp.pathExtension == "app" else { throw UpdateInstallError.notRunningFromAppBundle }
        guard !currentApp.path.contains("/AppTranslocation/") else { throw UpdateInstallError.translocated }
        let parent = currentApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: currentApp.path)
        else { throw UpdateInstallError.notWritable(currentApp.path) }

        // 和当前 App 在同一个卷上，最后一步替换才是原子的。
        let workDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: currentApp,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let (download, response) = try await session.download(from: update.archiveURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateCheckError.badResponse(http.statusCode)
        }
        let archive = workDirectory.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: download, to: archive)

        let unpacked = workDirectory.appendingPathComponent("unpacked", isDirectory: true)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        let newApp = try Self.findApp(in: unpacked)
        try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        try verify(newApp)

        _ = try FileManager.default.replaceItemAt(currentApp, withItemAt: newApp)
        try relaunch(currentApp)
    }

    private func verify(_ newApp: URL) throws {
        guard let newBundle = Bundle(url: newApp),
              newBundle.bundleIdentifier == bundle.bundleIdentifier
        else { throw UpdateInstallError.wrongBundle(Bundle(url: newApp)?.bundleIdentifier) }

        let newVersionString = newBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let currentVersionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if let newVersion = AppVersion(newVersionString), let currentVersion = AppVersion(currentVersionString),
           newVersion <= currentVersion {
            throw UpdateInstallError.notNewer(newVersionString)
        }

        try Self.checkSignature(of: newApp, matches: bundle.bundleURL)
    }

    /// 当前 App 由证书签名时，新 App 必须满足当前 App 的指定要求（同一张证书、同一标识），
    /// 这样辅助功能授权也能沿用；当前 App 是临时签名时只能要求新 App 签名完整有效。
    static func checkSignature(of newApp: URL, matches currentApp: URL) throws {
        var newCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(newApp as CFURL, [], &newCode)
        guard status == errSecSuccess, let newCode else { throw UpdateInstallError.signatureMismatch(status) }

        var requirement: SecRequirement?
        var currentCode: SecStaticCode?
        if SecStaticCodeCreateWithPath(currentApp as CFURL, [], &currentCode) == errSecSuccess,
           let currentCode,
           hasCertificate(currentCode) {
            status = SecCodeCopyDesignatedRequirement(currentCode, [], &requirement)
            guard status == errSecSuccess else { throw UpdateInstallError.signatureMismatch(status) }
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidity(newCode, flags, requirement)
        guard status == errSecSuccess else { throw UpdateInstallError.signatureMismatch(status) }
    }

    private static func hasCertificate(_ code: SecStaticCode) -> Bool {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let certificates = information[kSecCodeInfoCertificates as String] as? [Any]
        else { return false }
        return !certificates.isEmpty
    }

    private static func findApp(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let apps = contents.filter { $0.pathExtension == "app" }
        guard let app = apps.first(where: { $0.lastPathComponent == "SSClip.app" }) ?? apps.first else {
            throw UpdateInstallError.appMissingInArchive
        }
        return app
    }

    /// 等当前进程退出后再打开新 App，避免两个实例同时注册全局快捷键。
    private func relaunch(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "ssclip-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            app.path
        ]
        try process.run()
        NSApp.terminate(nil)
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateInstallError.toolFailed(
                        URL(fileURLWithPath: tool).lastPathComponent,
                        process.terminationStatus
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
