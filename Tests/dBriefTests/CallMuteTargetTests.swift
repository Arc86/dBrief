import Foundation
import Testing
@testable import dBrief

@MainActor
struct CallMuteTargetTests {
    @Test
    func nativeAppMutesItsOwnId() {
        let target = CallDetectionService.muteTarget(forBundleId: "us.zoom.xos")
        #expect(target == .init(bundleId: "us.zoom.xos", name: "Zoom"))
    }

    @Test
    func webCallMutesTheBrowser() {
        let target = CallDetectionService.muteTarget(forBundleId: "com.google.Chrome")
        #expect(target == .init(bundleId: "com.google.Chrome", name: "Chrome"))
    }

    @Test
    func meetAppKeepsItsOwnIdNotChrome() {
        let meet = "com.google.Chrome.app.kjgfgldnnfobanfaklcjnmoidpaoolgp"
        #expect(CallDetectionService.muteTarget(forBundleId: meet)?.bundleId == meet)
    }

    @Test
    func unknownOrMissingAppHasNoTarget() {
        #expect(CallDetectionService.muteTarget(forBundleId: "com.example.notes") == nil)
        #expect(CallDetectionService.muteTarget(forBundleId: nil) == nil)
    }

    @Test
    func watchableAppsListsCallAppsThenInstalledBrowsers() {
        let ids = CallDetectionService.watchableApps(isInstalled: { $0 == "com.apple.Safari" }, disabled: [])
            .map(\.bundleId)
        #expect(ids == CallDetectionService.knownCallApps.map(\.bundleId) + ["com.apple.Safari"])
    }

    @Test
    func mutedBrowserStaysListedWhenNotInstalled() {
        let ids = CallDetectionService.watchableApps(isInstalled: { _ in false }, disabled: ["com.brave.Browser"])
            .map(\.bundleId)
        #expect(ids.contains("com.brave.Browser"))
        #expect(!ids.contains("com.google.Chrome"))
    }

    @Test
    func everyStoredMuteIdAppearsInAppsToWatch() {
        let all = CallDetectionService.knownCallApps.map(\.bundleId) + CallDetectionService.knownBrowsers.map(\.bundleId)
        for id in all {
            let stored = CallDetectionService.muteTarget(forBundleId: id)!.bundleId
            let listed = CallDetectionService.watchableApps(isInstalled: { _ in false }, disabled: [stored])
            #expect(listed.contains { $0.bundleId == stored }, "\(id) can be muted but not turned back on")
        }
    }
}
