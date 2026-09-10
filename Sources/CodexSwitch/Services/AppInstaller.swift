import Foundation
import Security

// 다운로드 위치의 앱을 검증한 뒤 Applications에 설치하며 기존 앱은 재실행 성공까지 보관한다.
struct AppInstaller: Sendable {
    enum InstallationError: LocalizedError {
        case invalidApp, occupiedDestination, invalidSignature

        var errorDescription: String? {
            switch self {
            case .invalidApp: return "설치할 앱 정보를 읽지 못했어요. ZIP 파일을 다시 다운로드해 주세요."
            case .occupiedDestination: return "응용 프로그램 폴더에 같은 이름의 다른 앱이 있어요. 파일 이름을 확인해 주세요."
            case .invalidSignature: return "앱 서명을 확인하지 못했어요. 공식 배포 파일을 다시 다운로드해 주세요."
            }
        }
    }

    struct Installation: Sendable {
        let applicationURL: URL
        let backupURL: URL?

        func finish() {
            if let backupURL { try? FileManager.default.removeItem(at: backupURL) }
        }

        // 새 앱을 열지 못하면 교체 전 앱을 복원한다.
        func restoreBackup() throws {
            if let backupURL {
                _ = try FileManager.default.replaceItemAt(
                    applicationURL, withItemAt: backupURL, options: .usingNewMetadataOnly
                )
            }
        }
    }

    let sourceURL: URL
    var systemApplicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    var userApplicationsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true)
    var validate: @Sendable (URL, String) throws -> Void = Self.validateSignature

    var isInstalled: Bool {
        let source = sourceURL.resolvingSymlinksInPath().path
        return [systemApplicationsURL, userApplicationsURL].contains {
            source.hasPrefix($0.resolvingSymlinksInPath().path + "/")
        }
    }

    // 전체 사용자 폴더에 쓸 수 없으면 macOS가 지원하는 개인 Applications 폴더를 사용한다.
    func destinationURL() -> URL {
        let manager = FileManager.default
        let systemApp = systemApplicationsURL.appendingPathComponent("CodexSwitch.app", isDirectory: true)
        let userApp = userApplicationsURL.appendingPathComponent("CodexSwitch.app", isDirectory: true)
        if manager.fileExists(atPath: systemApp.path) { return systemApp }
        if manager.fileExists(atPath: userApp.path) { return userApp }
        return manager.isWritableFile(atPath: systemApplicationsURL.path) ? systemApp : userApp
    }

    func install() throws -> Installation {
        let manager = FileManager.default
        let sourceInfo = try metadata(at: sourceURL)
        let destination = destinationURL()
        try validate(sourceURL, sourceInfo.identifier)
        var replacing = false

        // 다른 앱·심볼릭 링크를 덮어쓰지 않고, 동일하거나 더 최신인 설치본은 그대로 연다.
        if manager.fileExists(atPath: destination.path) {
            guard try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  let installedInfo = try? metadata(at: destination),
                  installedInfo.identifier == sourceInfo.identifier else {
                throw InstallationError.occupiedDestination
            }
            try validate(destination, sourceInfo.identifier)
            if installedInfo.build >= sourceInfo.build {
                try prepareForLaunch(at: destination)
                return Installation(applicationURL: destination, backupURL: nil)
            }
            replacing = true
        }

        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = try manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: directory, create: true
        )
        defer { try? manager.removeItem(at: staging) }
        let copiedApp = staging.appendingPathComponent("CodexSwitch.app")
        try manager.copyItem(at: sourceURL, to: copiedApp)
        try validate(copiedApp, sourceInfo.identifier)
        try prepareForLaunch(at: copiedApp)

        if replacing {
            let backupName = ".CodexSwitch-backup-\(UUID().uuidString).app"
            _ = try manager.replaceItemAt(
                destination, withItemAt: copiedApp, backupItemName: backupName,
                options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
            )
            return Installation(applicationURL: destination,
                                backupURL: directory.appendingPathComponent(backupName))
        }
        try manager.moveItem(at: copiedApp, to: destination)
        return Installation(applicationURL: destination, backupURL: nil)
    }

    private func metadata(at applicationURL: URL) throws -> (identifier: String, build: Int) {
        let data = try Data(contentsOf: applicationURL.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              let buildString = info["CFBundleVersion"] as? String,
              let build = Int(buildString) else { throw InstallationError.invalidApp }
        return (identifier, build)
    }

    // 서명 검증을 마친 설치본만 다운로드 격리를 해제해 재실행 시 임시 경로로 돌아가지 않게 한다.
    // 다운로드 원본·공증 티켓은 보존하고, 번들 밖을 가리킬 수 있는 심볼릭 링크는 따라가지 않는다.
    private func prepareForLaunch(at applicationURL: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = nil
        var application = applicationURL
        try application.setResourceValues(values)
        let files = FileManager.default.enumerator(at: applicationURL, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while var file = files?.nextObject() as? URL {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
            try file.setResourceValues(values)
        }
    }

    // 복사 전후 모두 번들 전체가 같은 개발자의 올바른 서명인지 검사한다.
    static func validateSignature(at applicationURL: URL, identifier: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &code) == errSecSuccess,
              let code else { throw InstallationError.invalidSignature }
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"6YUP32AZ63\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw InstallationError.invalidSignature
        }
    }
}
