#if os(iOS)
import Foundation
import AVFoundation

/// "Play video sound only through headphones" (iPhone and iPad only): when on and a video with sound plays while no
/// headphones (wired, AirPods/Bluetooth, USB headset) are the output, the player starts muted
/// and asks whether to turn the sound on (for that video only). Connecting headphones turns the
/// sound on; disconnecting them mutes again and asks again.
enum AudioPolicy {
    static let changed = Notification.Name("AudioPolicyChanged")

    static var headphonesOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "audio.headphonesOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "audio.headphonesOnly"); NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// Whether a player should be muted now (`allowSpeaker`: the user said yes for this video).
    static func shouldMute(allowSpeaker: Bool) -> Bool { headphonesOnly && !headphonesConnected && !allowSpeaker }
    static let promptText = L("audio.prompt")

    /// Whether a media file has a sound track (no prompt for silent videos).
    static func hasAudio(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty == false) ?? true
    }

    static var headphonesConnected: Bool {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outs.contains { [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio].contains($0.portType) }
    }

    /// Starts observing output-route changes (call once at launch).
    static func observe() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}
#endif
