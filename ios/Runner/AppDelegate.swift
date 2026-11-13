import Flutter
import UIKit
import AVFAudio
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let audioQueue = DispatchQueue(label: "dev.orvex.audio-session")
  private var folderAccess: MediaFolderAccess?
  private var audioChannel: FlutterMethodChannel?
  private var audioObservers: [NSObjectProtocol] = []
  private var playbackVolume: PlaybackVolumeBridge?
  private var displayChannel: FlutterMethodChannel?
  private var appearanceChannel: FlutterMethodChannel?
  private var airPlayVideo: AirPlayVideoBridge?
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
    let folders = MediaFolderAccess(messenger: registrar.messenger(), presenter: { registrar.viewController })
    folderAccess = folders
    airPlayVideo = AirPlayVideoBridge(messenger: registrar.messenger(), registrar: registrar, folders: folders)
    let channel = FlutterMethodChannel(name: "dev.orvex/audio-session", binaryMessenger: registrar.messenger())
    audioChannel = channel
    playbackVolume = PlaybackVolumeBridge(messenger: registrar.messenger()) {
      registrar.viewController?.viewIfLoaded
    }
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
      ) { [weak self] _ in
        self?.restoreBrightness()
        self?.playbackVolume?.suspend()
      },
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

private final class PlaybackVolumeBridge: NSObject, FlutterStreamHandler {
  private let host: () -> UIView?
  private let session = AVAudioSession.sharedInstance()
  private var observation: NSKeyValueObservation?
  private var routeObserver: NSObjectProtocol?
  private var emit: FlutterEventSink?
  private var generation = 0
  private var route = [String]()
  private var playbackActive = false
  private var ignoreSamplesUntil: TimeInterval = 0
  private var detachWork: DispatchWorkItem?
  private var volumeView: MPVolumeView?

  private func makeVolumeView() -> MPVolumeView {
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 160, height: 44))
    let clear = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
    view.setMinimumVolumeSliderImage(clear, for: .normal)
    view.setMaximumVolumeSliderImage(clear, for: .normal)
    view.setVolumeThumbImage(clear, for: .normal)
    view.showsRouteButton = false
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    return view
  }

  init(messenger: FlutterBinaryMessenger, host: @escaping () -> UIView?) {
    self.host = host
    super.init()
    let methods = FlutterMethodChannel(name: "dev.orvex/volume", binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(false); return }
      switch call.method {
      case "isAvailable":
        #if targetEnvironment(simulator)
        result(false)
        #else
        result(true)
        #endif
      case "currentLevel":
        result(Double(self.session.outputVolume))
      case "present":
        self.playbackActive = (call.arguments as? Bool == true) && self.emit != nil
        if self.playbackActive {
          self.detachWork?.cancel()
          self.attach()
        } else {
          self.suspend()
        }
        result(nil)
      case "set":
        guard let level = call.arguments as? Double, level.isFinite,
              self.emit != nil, UIApplication.shared.applicationState == .active else {
          result(false)
          return
        }
        result(self.setVolume(Float(min(1, max(0, level)))))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(name: "dev.orvex/volume-events", binaryMessenger: messenger)
      .setStreamHandler(self)
  }

  private func attach() {
    guard let view = host(), view.window != nil else { return }
    let control = volumeView ?? makeVolumeView()
    guard control.superview !== view else { return }
    volumeView = control
    view.insertSubview(control, at: 0)
    control.layoutIfNeeded()
  }

  func suspend() {
    playbackActive = false
    detachWork?.cancel()
    volumeView?.removeFromSuperview()
  }

  private func setVolume(_ level: Float) -> Bool {
    attach()
    // MPVolumeView exposes appearance customization, but no public setter.
    // Forward the user's on-screen gesture through its native slider.
    guard let volumeView, volumeView.superview != nil,
          let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first,
          slider.isEnabled else {
      if !playbackActive { suspend() }
      return false
    }
    ignoreSamplesUntil = ProcessInfo.processInfo.systemUptime + 0.4
    slider.setValue(level, animated: false)
    slider.sendActions(for: .valueChanged)
    slider.sendActions(for: .touchUpInside)
    if !playbackActive {
      detachWork?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.suspend() }
      detachWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
    return true
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    stopObserving()
    emit = events
    route = session.currentRoute.outputs.map(\.uid)
    let token = generation
    observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
      guard let level = change.newValue else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == token else { return }
        let currentRoute = self.session.currentRoute.outputs.map(\.uid)
        let routeChanged = self.route != currentRoute
        self.route = currentRoute
        let previous = change.oldValue ?? level
        let sample = !routeChanged &&
          ProcessInfo.processInfo.systemUptime >= self.ignoreSamplesUntil &&
          previous > 0 && previous < 1 && level > 0 && level < 1
        self.send(level, delta: sample ? abs(level - previous) : nil, reset: routeChanged)
      }
    }
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
    ) { [weak self] _ in
      guard let self, self.generation == token else { return }
      self.route = self.session.currentRoute.outputs.map(\.uid)
      self.ignoreSamplesUntil = ProcessInfo.processInfo.systemUptime + 0.4
      self.send(self.session.outputVolume, reset: true)
    }
    send(session.outputVolume, reset: true)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopObserving()
    return nil
  }

  private func stopObserving() {
    generation += 1
    emit = nil
    observation?.invalidate()
    observation = nil
    if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    routeObserver = nil
    suspend()
  }

  private func send(_ level: Float, delta: Float? = nil, reset: Bool) {
    var value: [String: Any] = ["level": Double(level), "reset": reset]
    if let delta { value["delta"] = Double(delta) }
    emit?(value)
  }
}
