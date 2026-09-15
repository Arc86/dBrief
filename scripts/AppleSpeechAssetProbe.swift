import Foundation
import Speech

@main struct Probe {
 static func main() async {
  print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
  print("Available: \(SpeechTranscriber.isAvailable)")
  print("Installed: \(await SpeechTranscriber.installedLocales.map(\.identifier).sorted())")
  print("Reserved: \(await AssetInventory.reservedLocales.map(\.identifier)) / \(AssetInventory.maximumReservedLocales)")
  for id in ["nl", "nl-NL", "nl-BE", "en-US"] {
   guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else { print("\(id): unsupported"); continue }
   let module = SpeechTranscriber(locale: locale, preset: .transcription)
   print("\(id) -> \(locale.identifier), status: \(await AssetInventory.status(forModules: [module]))")
   if CommandLine.arguments.contains("--install"), id == "nl-NL" {
    do {
     if CommandLine.arguments.contains("--reserve") { print("reserve: \(try await AssetInventory.reserve(locale: locale))") }
     if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await request.downloadAndInstall() }
     print("after install: \(await AssetInventory.status(forModules: [module]))")
    } catch { print("INSTALL ERROR: \(String(reflecting: error)) / \((error as NSError).userInfo)") }
   }
  }
 }
}
