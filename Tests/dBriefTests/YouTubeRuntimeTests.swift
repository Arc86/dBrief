import Foundation
import Testing
@testable import dBrief

@Suite("YouTube JavaScript runtime discovery")
struct YouTubeRuntimeTests {
    @Test func homebrewRuntimeIsFoundWithAnAppLaunchPath() {
        let args = YouTubeDownloadService.javaScriptRuntimeArguments(
            searchPath: "/usr/bin:/bin:/usr/sbin:/sbin",
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/opt/homebrew/bin/deno" })
        #expect(args == ["--js-runtimes", "deno:/opt/homebrew/bin/deno"])
    }

    @Test func nodeIsExplicitlyEnabledWhenDenoIsMissing() {
        let args = YouTubeDownloadService.javaScriptRuntimeArguments(
            searchPath: "/usr/bin:/bin",
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/usr/local/bin/node" })
        #expect(args == ["--js-runtimes", "node:/usr/local/bin/node"])
    }

    @Test func userDenoAndCustomNodePathsArePassedAsSingleArguments() {
        let args = YouTubeDownloadService.javaScriptRuntimeArguments(
            searchPath: "/Tools/Node Runtime/bin:/usr/bin",
            homeDirectory: "/Users/Test Person",
            isExecutable: {
                ["/Users/Test Person/.deno/bin/deno", "/Tools/Node Runtime/bin/node"].contains($0)
            })
        #expect(args == [
            "--js-runtimes", "deno:/Users/Test Person/.deno/bin/deno",
            "--js-runtimes", "node:/Tools/Node Runtime/bin/node",
        ])
    }

    @Test func absentRuntimePreservesDownloaderDefaultsAndUserConfiguration() {
        let args = YouTubeDownloadService.javaScriptRuntimeArguments(
            searchPath: "", homeDirectory: "/Users/test", isExecutable: { _ in false })
        #expect(args.isEmpty)
    }

    @Test func relativeSearchPathsAreNotUsedForRuntimeDiscovery() {
        let args = YouTubeDownloadService.javaScriptRuntimeArguments(
            searchPath: ":.:relative/bin", homeDirectory: "/Users/test",
            isExecutable: { !$0.hasPrefix("/") })
        #expect(args.isEmpty)
    }
}
