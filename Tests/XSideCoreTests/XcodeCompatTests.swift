import Foundation
import Testing
@testable import XSideCore

struct XcodeCompatTests {
    @Test func comparesMajorMinor() {
        #expect(XcodeCompat.isNewer("27.0", than: "26.4"))
        #expect(XcodeCompat.isNewer("26.2", than: "26.1"))
        #expect(!XcodeCompat.isNewer("26.1.1", than: "26.1"))
        #expect(!XcodeCompat.isNewer("26.0", than: "26.4"))
        #expect(!XcodeCompat.isNewer("26", than: "26.0"))
    }

    @Test func comparesMajorOnly() {
        #expect(XcodeCompat.isNewerMajor("27.0", than: "26.4"))
        #expect(!XcodeCompat.isNewerMajor("26.1", than: "26.0"))
        #expect(!XcodeCompat.isNewerMajor("26.4.1", than: "26.4"))
        #expect(!XcodeCompat.isNewerMajor("26.0", than: "27.0"))
    }

    @Test func recognizesBetaBuilds() {
        #expect(XcodeCompat.isBetaBuild("25A5279m"))
        #expect(XcodeCompat.isBetaBuild("26A5310"))
        #expect(XcodeCompat.isBetaBuild("17A5241e"))
        #expect(XcodeCompat.isBetaBuild("16A5171c"))
        // Releases ending with a lowercase letter: Xcode 16.0, Xcode 15.4, a macOS RSR.
        #expect(!XcodeCompat.isBetaBuild("16A242d"))
        #expect(!XcodeCompat.isBetaBuild("15F31d"))
        #expect(!XcodeCompat.isBetaBuild("22E772610a"))
        #expect(!XcodeCompat.isBetaBuild("26B123"))
        #expect(!XcodeCompat.isBetaBuild("21G1974"))
        #expect(!XcodeCompat.isBetaBuild(""))
    }

    @Test func explainsFailuresOnNewerIOS() {
        let failure = XSideError.installFailed("x")
        #expect(XcodeCompat.explain(failure, deviceOS: "27.0", sdkVersion: "26.4") as? XSideError
                == .xcodeTooOld(deviceOS: "27.0"))
        #expect(XcodeCompat.explain(failure, deviceOS: "26.4", sdkVersion: "26.4") as? XSideError == failure)
        // A minor gap usually deploys fine: the original error is kept.
        #expect(XcodeCompat.explain(failure, deviceOS: "26.1", sdkVersion: "26.0") as? XSideError == failure)
        #expect(XcodeCompat.explain(failure, deviceOS: nil, sdkVersion: "26.4") as? XSideError == failure)
        #expect(XcodeCompat.explain(XSideError.deviceLocked, deviceOS: "27.0", sdkVersion: "26.4") as? XSideError
                == .deviceLocked)
    }

    @Test func readsSDKVersion() throws {
        let dev = FileManager.default.temporaryDirectory.appendingPathComponent("dev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dev) }
        let sdk = dev.appendingPathComponent("Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Version": "26.4"], format: .xml, options: 0)
        try data.write(to: sdk.appendingPathComponent("SDKSettings.plist"))
        #expect(XcodeCompat.iOSSDKVersion(developerDir: dev) == "26.4")
        #expect(XcodeCompat.iOSSDKVersion(developerDir: dev.appendingPathComponent("none")) == nil)
    }

    @Test func readsXcodeVersionAndBeta() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ app: String, build: String) throws -> URL {
            let contents = root.appendingPathComponent("\(app)/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Developer"), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": "27.2", "ProductBuildVersion": build], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("version.plist"))
            return contents.appendingPathComponent("Developer")
        }
        let release = XcodeCompat.xcodeVersion(developerDir: try make("Xcode.app", build: "27B48"))
        #expect(release?.version == "27.2" && release?.build == "27B48" && release?.isBeta == false)
        #expect(XcodeCompat.xcodeVersion(developerDir: try make("Xcode2.app", build: "27A5241e"))?.isBeta == true)
        #expect(XcodeCompat.xcodeVersion(developerDir: try make("Xcode-beta.app", build: "27B48"))?.isBeta == true)
        #expect(XcodeCompat.xcodeVersion(developerDir: root.appendingPathComponent("none")) == nil)
    }

    @Test func explainsFailuresOnMacBetaWithReleaseXcode() {
        let failure = XSideError.provisioningFailed("x")
        #expect(XcodeCompat.explain(failure, deviceOS: "26.0", sdkVersion: "26.4", macBetaWithReleaseXcode: true)
                as? XSideError == .xcodeNeedsBetaForMac)
        // A newer iOS is the more specific cause.
        #expect(XcodeCompat.explain(failure, deviceOS: "27.0", sdkVersion: "26.4", macBetaWithReleaseXcode: true)
                as? XSideError == .xcodeTooOld(deviceOS: "27.0"))
        #expect(XcodeCompat.explain(failure, deviceOS: "26.0", sdkVersion: "26.4") as? XSideError == failure)
        #expect(XcodeCompat.explain(XSideError.deviceLocked, deviceOS: nil, sdkVersion: nil, macBetaWithReleaseXcode: true)
                as? XSideError == .deviceLocked)
    }
}
