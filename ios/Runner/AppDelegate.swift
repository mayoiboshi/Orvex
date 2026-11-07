import Flutter
import UIKit
import AVFAudio

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audioQueue = DispatchQueue(label: "dev.orvex.audio-session")
  private var folderAccess: MediaFolderAccess?
  private var audioChannel: FlutterMethodChannel?
  private var audioObservers: [NSObjectProtocol] = []
  private var displayChannel: FlutterMethodChannel?
  private var appearanceChannel: FlutterMethodChannel?
  private var brightnessScreen: UIScreen?
  private var originalBrightness: CGFloat?

  private func restoreBrightness() {
    if let screen = brightnessScreen, let value = originalBrightness {
      screen.brightness = value
    }
    brightnessScreen = nil
    originalBrightness = nil
  }

  deinit {
    for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OrvexAudioSession") else { return }
    folderAccess = MediaFolderAccess(messenger: registrar.messenger(), presenter: { registrar.viewController })
    let channel = FlutterMethodChannel(name: "dev.orvex/audio-session", binaryMessenger: registrar.messenger())
    audioChannel = channel
    let appearance = FlutterMethodChannel(name: "dev.orvex/appearance", binaryMessenger: registrar.messenger())
    appearanceChannel = appearance
    appearance.setMethodCallHandler { call, result in
      guard call.method == "accessibilityPreferences" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result([
        "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
        "reduceMotion": UIAccessibility.isReduceMotionEnabled,
      ])
    }
    let display = FlutterMethodChannel(name: "dev.orvex/display", binaryMessenger: registrar.messenger())
    displayChannel = display
    display.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "restoreBrightness" {
        self.restoreBrightness()
        result(nil)
        return
      }
      guard call.method == "getBrightness" || call.method == "setBrightness" else {
        result(FlutterMethodNotImplemented)
        return
      }
      #if targetEnvironment(simulator)
      // A simulator does not provide a physical display brightness control.
      result(nil)
      #else
      guard let screen = registrar.viewController?.view.window?.windowScene?.screen,
            screen === UIScreen.main else {
        result(FlutterError(code: "display_unavailable", message: "当前屏幕不支持亮度调节", details: nil))
        return
      }
      if call.method == "getBrightness" {
        result(Double(screen.brightness))
      } else if let value = call.arguments as? Double, value.isFinite {
        if self.brightnessScreen !== screen { self.restoreBrightness() }
        if self.originalBrightness == nil {
          self.originalBrightness = screen.brightness
          self.brightnessScreen = screen
        }
        screen.brightness = CGFloat(min(1.0, max(0.05, value)))
        result(nil)
      } else {
        result(FlutterError(code: "invalid_brightness", message: "无效亮度", details: nil))
      }
      #endif
    }
    audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
    audioObservers = [
      NotificationCenter.default.addObserver(
        forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
        object: nil, queue: .main
      ) { [weak appearance] _ in appearance?.invokeMethod("accessibilityChanged", arguments: nil) },
      NotificationCenter.default.addObserver(
        forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
        object: nil, queue: .main
      ) { [weak appearance] _ in appearance?.invokeMethod("accessibilityChanged", arguments: nil) },
      NotificationCenter.default.addObserver(
        forName: UIApplication.willResignActiveNotification,
        object: nil, queue: .main
      ) { [weak self] _ in self?.restoreBrightness() },
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
