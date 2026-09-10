import AppKit
import SwiftUI
import XCTest
@testable import CodexSwitch

final class AppInstallerTests: XCTestCase {
    // 최초 설치는 전체 앱을 복사하고 다운로드 원본은 보존한다.
    func testFirstInstallCopiesAppAndRecognizesInstalledLocation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        XCTAssertFalse(fixture.installer.isInstalled)
        let result = try fixture.installer.install()
        XCTAssertEqual(result.applicationURL, fixture.destination)
        XCTAssertNil(result.backupURL)
        XCTAssertEqual(try fixture.marker(at: result.applicationURL), "new")
        XCTAssertEqual(try fixture.marker(at: fixture.source), "new")
        var installed = fixture.installer
        installed = AppInstaller(sourceURL: result.applicationURL,
                                 systemApplicationsURL: installed.systemApplicationsURL,
                                 userApplicationsURL: installed.userApplicationsURL,
                                 validate: { _, _ in })
        XCTAssertTrue(installed.isInstalled)
    }

    // 시스템 폴더를 쓸 수 없을 때 개인 Applications로 설치한다.
    func testFallsBackToUserApplications() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.systemDirectory)
        let result = try fixture.installer.install()
        XCTAssertEqual(result.applicationURL, fixture.userDirectory.appendingPathComponent("CodexSwitch.app"))
        XCTAssertEqual(try fixture.marker(at: result.applicationURL), "new")
    }

    // 설치본의 다운로드 격리만 해제하고 원본과 외부 심볼릭 링크 대상은 보존한다.
    func testVerifiedInstallClearsOnlyCopiedBundleQuarantine() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sourceFile = fixture.source.appendingPathComponent("Contents/marker")
        let externalFile = fixture.root.appendingPathComponent("external")
        try Data().write(to: externalFile)
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("Contents/external"), withDestinationURL: externalFile
        )
        for var url in [fixture.source, sourceFile, externalFile] {
            var values = URLResourceValues()
            values.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeOtherDownload"]
            try url.setResourceValues(values)
            XCTAssertNotNil(try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        }
        let result = try fixture.installer.install()
        for url in [result.applicationURL, result.applicationURL.appendingPathComponent("Contents/marker")] {
            let properties = try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
            XCTAssertNil(properties)
        }
        for url in [fixture.source, sourceFile, externalFile] {
            let properties = try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
            XCTAssertEqual(properties?["LSQuarantineType"] as? String, "LSQuarantineTypeOtherDownload")
        }
    }

    // 기존 앱 교체는 검증 후 이뤄지며 재실행 실패 시 원본을 복원할 수 있다.
    func testReplacementCanRestorePreviousApp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeApp(at: fixture.destination, build: 5, marker: "old")
        let result = try fixture.installer.install()
        XCTAssertEqual(try fixture.marker(at: result.applicationURL), "new")
        XCTAssertEqual(try fixture.marker(at: XCTUnwrap(result.backupURL)), "old")
        try result.restoreBackup()
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "old")
    }

    // 재실행이 성공하면 앱 교체에 사용한 임시 백업을 정리한다.
    func testSuccessfulReplacementRemovesBackup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeApp(at: fixture.destination, build: 5, marker: "old")
        let result = try fixture.installer.install()
        let backup = try XCTUnwrap(result.backupURL)
        result.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "new")
    }

    // 같은 버전과 최신 버전은 다운로드한 예전 앱으로 덮어쓰지 않는다.
    func testEqualOrNewerInstalledVersionIsPreserved() throws {
        for build in [6, 7] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            try fixture.writeApp(at: fixture.destination, build: build, marker: "installed")
            let result = try fixture.installer.install()
            XCTAssertNil(result.backupURL)
            XCTAssertEqual(try fixture.marker(at: result.applicationURL), "installed")
        }
    }

    // 다른 앱이나 심볼릭 링크는 자동 교체 대상으로 취급하지 않는다.
    func testUnrelatedAppAndSymlinkAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeApp(at: fixture.destination, build: 1, marker: "other", identifier: "other.app")
        XCTAssertThrowsError(try fixture.installer.install())
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "other")
        try FileManager.default.removeItem(at: fixture.destination)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: fixture.source)
        XCTAssertThrowsError(try fixture.installer.install())
        XCTAssertEqual(try fixture.marker(at: fixture.source), "new")
    }

    // 복사본 서명이 맞지 않으면 기존 설치본을 건드리지 않는다.
    func testFailedCopyValidationPreservesInstalledApp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeApp(at: fixture.destination, build: 5, marker: "old")
        var installer = fixture.installer
        let allowed = [fixture.source, fixture.destination]
        installer.validate = { url, _ in
            if !allowed.contains(url) { throw AppInstaller.InstallationError.invalidSignature }
        }
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try fixture.marker(at: fixture.destination), "old")
        XCTAssertEqual(try fixture.marker(at: fixture.source), "new")
    }

    // 실제 서명 검증은 단순히 Info.plist만 갖춘 가짜 앱을 허용하지 않는다.
    func testSignatureValidationRejectsUnsignedApplication() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        XCTAssertThrowsError(try AppInstaller.validateSignature(at: fixture.source, identifier: "com.bluepin.CodexSwitch"))
    }

    // 설치·복구 화면의 문구와 컨트롤이 두 테마에서 고정 창 안에 들어가는지 확인한다.
    @MainActor
    func testInstallationViewLayouts() throws {
        for scheme in [ColorScheme.light, .dark] {
            for hasError in [false, true] {
                let startup = AppStartup()
                if hasError {
                    startup.showInstallationError("실행 중인 CodexSwitch의 메뉴에서 ‘종료’를 누른 뒤 다시 시도해 주세요.")
                }
                let view = NSHostingView(rootView: InstallationView(startup: startup).environment(\.colorScheme, scheme))
                let size = view.fittingSize
                XCTAssertEqual(size.width, 460, accuracy: 1)
                XCTAssertLessThanOrEqual(size.height, 330)
                if let root = ProcessInfo.processInfo.environment["CODEXSWITCH_INSTALL_SNAPSHOT_ROOT"] {
                    view.frame = NSRect(origin: .zero, size: size)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: "\(root)-\(scheme)-\(hasError).png"))
                }
            }
        }
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexSwitchInstall-\(UUID().uuidString)")
        var source: URL { root.appendingPathComponent("Downloads/CodexSwitch.app") }
        var systemDirectory: URL { root.appendingPathComponent("SystemApplications") }
        var userDirectory: URL { root.appendingPathComponent("UserApplications") }
        var destination: URL { systemDirectory.appendingPathComponent("CodexSwitch.app") }
        var installer: AppInstaller {
            AppInstaller(sourceURL: source, systemApplicationsURL: systemDirectory,
                         userApplicationsURL: userDirectory, validate: { _, _ in })
        }

        init() throws {
            try FileManager.default.createDirectory(at: systemDirectory, withIntermediateDirectories: true)
            try writeApp(at: source, build: 6, marker: "new")
        }

        func writeApp(at url: URL, build: Int, marker: String, identifier: String = "com.bluepin.CodexSwitch") throws {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleVersion": "\(build)"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
        }

        func marker(at url: URL) throws -> String {
            try String(contentsOf: url.appendingPathComponent("Contents/marker"), encoding: .utf8)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
