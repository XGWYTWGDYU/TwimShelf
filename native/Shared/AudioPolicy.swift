import Foundation
import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// "Play video sound only through headphones": when on and a video with sound plays while no
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
    static var shouldMute: Bool { shouldMute(allowSpeaker: false) }
    static let promptText = L("audio.prompt")

    /// Whether a media file has a sound track (no prompt for silent videos).
    static func hasAudio(_ url: URL) async -> Bool {
        (try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty == false) ?? true
    }

    static var headphonesConnected: Bool {
        #if os(iOS)
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outs.contains { [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio].contains($0.portType) }
        #else
        return macHeadphones()
        #endif
    }

    /// Starts observing output-route changes (call once at launch).
    static func observe() {
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            NotificationCenter.default.post(name: changed, object: nil)
        }
        #else
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { _, _ in
            watchDataSource()
            NotificationCenter.default.post(name: changed, object: nil)
        }
        watchDataSource()
        #endif
    }

    #if os(macOS)
    private static var watchedDevices = Set<AudioDeviceID>()

    /// Plugging into the jack of a built-in output changes that device's data source, not which
    /// device is the default: each output in use is watched too (always on the main queue).
    private static func watchDataSource() {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, watchedDevices.insert(dev).inserted else { return }
        addr.mSelector = kAudioDevicePropertyDataSource
        addr.mScope = kAudioDevicePropertyScopeOutput
        AudioObjectAddPropertyListenerBlock(dev, &addr, .main) { _, _ in
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private static func macHeadphones() -> Bool {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyTransportType
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &transport) == noErr,
           [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB].contains(transport) { return true }
        // Built-in output: the "hdpn" data source means the headphone jack is in use.
        var source = UInt32(0)
        addr.mSelector = kAudioDevicePropertyDataSource
        addr.mScope = kAudioDevicePropertyScopeOutput
        if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &source) == noErr { return source == 0x6864_706E } // 'hdpn'
        return false
    }
    #endif
}
