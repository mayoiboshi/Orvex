import Flutter
import UIKit
import AVFAudio

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audioQueue = DispatchQueue(label: "dev.orvex.audio-session")
  private var audioChannel: FlutterMethodChannel?
  private var audioObservers: [NSObjectProtocol] = []

  deinit {
    for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OrvexAudioSession") else { return }
    let channel = FlutterMethodChannel(name: "dev.orvex/audio-session", binaryMessenger: registrar.messenger())
    audioChannel = channel
    audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
    audioObservers = [
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(), queue: .main
      ) { [weak channel] notification in
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        channel?.invokeMethod("interruption", arguments: "audioFocusLost")
      },
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: AVAudioSession.sharedInstance(), queue: .main
      ) { [weak channel] notification in
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        channel?.invokeMethod("interruption", arguments: "headphonesDisconnected")
      },
    ]
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "isSimulator" {
        #if targetEnvironment(simulator)
        result(true)
        #else
        result(false)
        #endif
        return
      }
      guard call.method == "activate" || call.method == "deactivate" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.audioQueue.async {
        do {
          let session = AVAudioSession.sharedInstance()
          if call.method == "activate" {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
          } else {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
          }
          DispatchQueue.main.async { result(nil) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "audio_session", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}
