import UIKit

final class VoiceDownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        VoiceAssetDownloads.shared.reconnect()
        if #available(iOS 26, *) { SpeechComputeJob.register() }
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == VoiceAssetDownloads.identifier else { completionHandler(); return }
        VoiceAssetDownloads.shared.handleBackgroundEvents(completion: completionHandler)
    }
}
