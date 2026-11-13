import AVFoundation
import AVKit
import Flutter
import UIKit
import ObjectiveC
import Darwin

private final class AirPlayInterruptionState {
  private(set) var active = false
  private var observer: NSObjectProtocol?
  init() {
    observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
      guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
      if type == .began { self?.active = true }
      else if type == .ended { self?.active = false }
    }
  }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// Candidate AVPlayer for explicit AirPlay handoff. Ownership of the media URL
/// and its security-scoped lease stays with the Dart playback session.
final class AirPlayVideoBridge: NSObject, FlutterStreamHandler {
  private static var owner: AirPlayVideoBridge?
  private static let interruptionState = AirPlayInterruptionState()
  private let bridgeID = UUID().uuidString
  private var claimID: String?
  private var pendingWork = 0
  private var pendingOwnerRelease: FlutterResult?
  private static var sourceAssociationKey: UInt8 = 0
  private let folders: MediaFolderAccess
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var subscriptionID: String?
  private var player: AVPlayer?
  private var asset: AVURLAsset?
  private var itemObservation: NSKeyValueObservation?
  private var externalObservation: NSKeyValueObservation?
  private var controlObservation: NSKeyValueObservation?
  private var durationObservation: NSKeyValueObservation?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var interruptionObserver: NSObjectProtocol?
  private var pendingPrepare: FlutterResult?
  private var pendingSeek: FlutterResult?
  private var timeout: DispatchWorkItem?
  private var token: Int64?
  private var revision: UInt64 = 0
  private var eventSequence: Int64 = 0
  private var ready = false
  private var preparingSeek = false
  private var probing = false
  private var seeking = false
  private var seekRevision: UInt64 = 0
  private var completed = false
  private var hadExternal = false
  private var routeClaimed = false
  private var interruptionActive = false
  private var requiresUserResume = false

  init(messenger: FlutterBinaryMessenger, registrar: FlutterPluginRegistrar, folders: MediaFolderAccess) {
    self.folders = folders
    _ = Self.interruptionState
    methods = FlutterMethodChannel(name: "dev.orvex/airplay", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "dev.orvex/airplay/events", binaryMessenger: messenger)
    super.init()
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "closed", message: "投屏组件已关闭", details: nil)); return }
      self.handle(call, result: result)
    }
    events.setStreamHandler(self)
    registrar.register(AirPlayRoutePickerFactory(bridge: self), withId: "dev.orvex/airplay-picker")
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    guard (arguments as? [String: Any])?["bridgeId"] as? String == bridgeID else {
      return FlutterError(code: "stale_bridge", message: "投屏组件已失效", details: nil)
    }
    guard Self.owner === self, let claimID,
          (arguments as? [String: Any])?["claimId"] as? String == claimID else {
      return FlutterError(code: "stale_owner", message: "播放会话所有权已失效", details: nil)
    }
    subscriptionID = (arguments as? [String: Any])?["subscriptionId"] as? String
    sink = events
    emit("snapshot")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    guard (arguments as? [String: Any])?["bridgeId"] as? String == bridgeID else { return nil }
    guard let claimID, (arguments as? [String: Any])?["claimId"] as? String == claimID else { return nil }
    let canceled = (arguments as? [String: Any])?["subscriptionId"] as? String
    if canceled == subscriptionID { sink = nil; subscriptionID = nil }
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "identity" { result(bridgeID); return }
    guard args["bridgeId"] as? String == bridgeID else {
      result(FlutterError(code: "stale_bridge", message: "投屏组件已失效", details: nil)); return
    }
    if call.method == "localRouteForIPv4" {
      guard let targetText = args["target"] as? String else {
        result(FlutterError(code: "invalid_argument", message: "设备地址无效", details: nil)); return
      }
      var target = in_addr()
      guard targetText.withCString({ inet_pton(AF_INET, $0, &target) }) == 1 else {
        result(FlutterError(code: "invalid_address", message: "请输入 IPv4 地址", details: nil)); return
      }
      let firstOctet = UInt8((UInt32(bigEndian: target.s_addr) >> 24) & 0xff)
      guard firstOctet > 0, firstOctet < 224, firstOctet != 127 else {
        result(FlutterError(code: "invalid_address", message: "请输入局域网单播地址", details: nil)); return
      }
      var head: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&head) == 0 else {
        result(FlutterError(code: "network_unavailable", message: "无法读取局域网", details: nil)); return
      }
      defer { freeifaddrs(head) }
      var cursor = head
      while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        let flags = Int32(entry.pointee.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
              String(cString: entry.pointee.ifa_name).hasPrefix("en"),
              let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
              let mask = entry.pointee.ifa_netmask else { continue }
        let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        let remote = target.s_addr
        guard netmask != 0, (local & netmask) == (remote & netmask),
              remote != local, remote != (local & netmask), remote != ((local & netmask) | ~netmask) else { continue }
        var localIP = in_addr(s_addr: local)
        var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &localIP, &chars, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        result(String(cString: chars)); return
      }
      result(FlutterError(code: "not_local", message: "设备不在直连局域网中", details: nil)); return
    }
    if call.method == "claimPlayback" {
      guard Self.owner == nil, claimID == nil else {
        result(FlutterError(code: "owner_busy", message: "其他播放器尚未关闭", details: nil)); return
      }
      let claim = UUID().uuidString
      Self.owner = self
      claimID = claim
      result(claim)
      return
    }
    guard Self.owner === self, let claimID, args["claimId"] as? String == claimID else {
      result(FlutterError(code: "stale_owner", message: "播放会话所有权已失效", details: nil)); return
    }
    if call.method == "releasePlayback" {
      guard token == nil, player == nil, pendingPrepare == nil else {
        result(FlutterError(code: "owner_busy", message: "投屏尚未关闭", details: nil)); return
      }
      guard pendingOwnerRelease == nil else {
        result(FlutterError(code: "owner_busy", message: "播放器资源仍在释放", details: nil)); return
      }
      if pendingWork > 0 {
        pendingOwnerRelease = result
      } else {
        finishOwnerRelease(result)
      }
      return
    }
    if call.method == "prepare" {
      guard let requested = (args["token"] as? NSNumber)?.int64Value,
            let text = args["uri"] as? String,
            let uri = URL(string: text), uri.isFileURL,
            let ms = (args["positionMs"] as? NSNumber)?.doubleValue,
            ms.isFinite, ms >= 0 else {
        result(FlutterError(code: "invalid_argument", message: "无效的媒体或播放位置", details: nil)); return
      }
      guard token == nil, pendingWork == 0, pendingOwnerRelease == nil else {
        result(FlutterError(code: "owner_busy", message: "其他投屏会话尚未关闭", details: nil)); return
      }
      revision &+= 1
      let reservation = revision
      token = requested
      pendingPrepare = result
      let begin: (URL, MediaFolderAccess.PlaybackSource?) -> Void = { [weak self] resolved, source in
        guard let self, Self.owner === self, self.revision == reservation, self.token == requested else { return }
        guard resolved.standardizedFileURL == uri.standardizedFileURL else {
          self.failPrepare("投屏文件身份不匹配"); return
        }
        self.prepare(uri: resolved, positionMs: ms, token: requested, source: source)
      }
      if let handle = args["handle"] as? String, let path = args["path"] as? String {
        pendingWork += 1
        folders.retainPlaybackSource(handle: handle, path: path, identity: args["identity"] as? String) { [weak self] outcome in
          guard let self else { return }
          defer { DispatchQueue.main.async { self.finishNativeWork() } }
          guard Self.owner === self, self.revision == reservation else { return }
          switch outcome {
          case .success(let source): begin(source.url, source)
          case .failure: self.failPrepare("目录授权无效或视频已变化")
          }
        }
      } else if let path = args["importPath"] as? String {
        pendingWork += 1
        folders.resolveImportedPlaybackSource(path: path) { [weak self] outcome in
          guard let self else { return }
          defer { DispatchQueue.main.async { self.finishNativeWork() } }
          guard Self.owner === self, self.revision == reservation else { return }
          switch outcome {
          case .success(let source): begin(source, nil)
          case .failure: self.failPrepare("导入的视频无法访问")
          }
        }
      } else {
        failPrepare("投屏视频缺少有效的文件授权")
      }
      return
    }
    if call.method == "close", token == nil {
      result(nil)
      return
    }
    guard let requested = (args["token"] as? NSNumber)?.int64Value,
          requested == token else {
      result(FlutterError(code: "stale_session", message: "投屏会话已失效", details: nil)); return
    }
    switch call.method {
    case "probe":
      guard !Self.interruptionState.active, !requiresUserResume else {
        result(FlutterError(code: "interrupted", message: "播放中断，请在中断结束后手动继续", details: nil)); return
      }
      guard let player, ready, !seeking else {
        result(FlutterError(code: "not_ready", message: "视频尚未准备好", details: nil)); return
      }
      player.isMuted = true
      probing = true
      routeClaimed = player.isExternalPlaybackActive
      hadExternal = player.isExternalPlaybackActive
      player.play()
      let currentRevision = revision
      timeout?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.revision == currentRevision, self.probing else { return }
        self.stopCandidate()
        self.emit("timeout", error: "等待视频投屏超时")
      }
      timeout = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
      emit("probing")
      result(nil)
    case "seek":
      guard let value = (args["positionMs"] as? NSNumber)?.doubleValue,
            value.isFinite, value >= 0, player != nil, ready else {
        result(FlutterError(code: "not_ready", message: "无法定位投屏视频", details: nil)); return
      }
      seek(ms: value, result: result)
    case "play":
      guard !Self.interruptionState.active, !interruptionActive, !requiresUserResume || args["userInitiated"] as? Bool == true else {
        result(FlutterError(code: "interrupted", message: "播放中断，请在中断结束后手动继续", details: nil)); return
      }
      guard let player, ready, !seeking, routeClaimed, player.isExternalPlaybackActive else {
        result(FlutterError(code: "route_unavailable", message: "视频投屏尚未连接", details: nil)); return
      }
      timeout?.cancel()
      timeout = nil
      probing = false
      completed = false
      requiresUserResume = false
      player.isMuted = false
      player.play()
      emit("playing")
      result(nil)
    case "pause":
      guard let player else {
        result(FlutterError(code: "not_ready", message: "投屏视频已关闭", details: nil)); return
      }
      player.pause()
      player.isMuted = true
      probing = false
      timeout?.cancel()
      timeout = nil
      emit("paused")
      result(nil)
    case "status":
      result(snapshot("snapshot"))
    case "close":
      clear(reason: "投屏会话已关闭")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func prepare(uri: URL, positionMs: Double, token requested: Int64, source: MediaFolderAccess.PlaybackSource?) {
    let currentRevision = revision
    let candidate = AVURLAsset(url: uri)
    if let source {
      objc_setAssociatedObject(candidate, &AirPlayVideoBridge.sourceAssociationKey, source, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    asset = candidate
    let keys = ["playable", "compatibleWithAirPlayVideo"]
    pendingWork += 1
    candidate.loadValuesAsynchronously(forKeys: keys) { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        defer { DispatchQueue.main.async { self.finishNativeWork() } }
        guard self.revision == currentRevision else { return }
        for key in keys {
          var error: NSError?
          guard candidate.statusOfValue(forKey: key, error: &error) == .loaded else {
            self.failPrepare("无法读取投屏视频")
            return
          }
        }
        guard candidate.isPlayable, candidate.isCompatibleWithAirPlayVideo else {
          self.failPrepare("此视频无法通过 AirPlay 播放")
          return
        }
        let item = AVPlayerItem(asset: candidate)
        let player = AVPlayer()
        player.isMuted = true
        player.allowsExternalPlayback = true
        self.player = player
        self.installObservers(player: player, item: item, revision: currentRevision)
        self.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
          DispatchQueue.main.async {
            guard let self, self.revision == currentRevision else { return }
            if item.status == .failed {
              if self.pendingPrepare != nil {
                self.failPrepare("投屏视频准备失败")
              } else {
                self.stopCandidate()
                self.emit("failed", error: "投屏播放失败")
              }
            } else if item.status == .readyToPlay, !self.ready, !self.preparingSeek, self.pendingPrepare != nil {
              self.preparingSeek = true
              self.seek(ms: positionMs) { [weak self] value in
                guard let self, self.revision == currentRevision else { return }
                self.preparingSeek = false
                if let error = value as? FlutterError {
                  self.failPrepare(error.message ?? "无法定位投屏视频")
                } else {
                  self.ready = true
                  let callback = self.pendingPrepare
                  self.pendingPrepare = nil
                  self.emit("ready")
                  callback?(self.snapshot("ready"))
                }
              }
            }
          }
        }
        player.replaceCurrentItem(with: item)
      }
    }
  }

  private func finishNativeWork() {
    pendingWork -= 1
    if pendingWork == 0, let release = pendingOwnerRelease {
      pendingOwnerRelease = nil
      finishOwnerRelease(release)
    }
  }

  private func finishOwnerRelease(_ result: @escaping FlutterResult) {
    claimID = nil
    if Self.owner === self { Self.owner = nil }
    result(nil)
  }

  private func installObservers(player: AVPlayer, item: AVPlayerItem, revision currentRevision: UInt64) {
    externalObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self, weak player] _, _ in
      DispatchQueue.main.async {
        guard let self, let player, self.revision == currentRevision else { return }
        if player.isExternalPlaybackActive {
          self.hadExternal = true
          if self.probing { self.routeClaimed = true }
          self.emit("routeChanged")
        } else if self.hadExternal {
          self.hadExternal = false
          self.routeClaimed = false
          player.pause()
          player.isMuted = true
          self.probing = false
          self.timeout?.cancel()
          self.timeout = nil
          self.emit("routeLost")
        } else {
          self.emit("routeChanged")
        }
      }
    }
    controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        guard let self, self.revision == currentRevision else { return }
        self.emit("state")
      }
    }
    durationObservation = item.observe(\.duration, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async {
        guard let self, self.revision == currentRevision else { return }
        self.emit("state")
      }
    }
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
      guard let self, self.revision == currentRevision else { return }
      self.emit("state")
    }
    endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
      guard let self, self.revision == currentRevision else { return }
      self.completed = true
      self.pauseRetainingRoute()
      self.emit("completed")
    }
    interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
      guard let self, self.revision == currentRevision,
            let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
      if type == .began {
        self.interruptionActive = true
        self.requiresUserResume = true
        self.pauseRetainingRoute()
        self.emit("interrupted")
      } else if type == .ended {
        self.interruptionActive = false
      }
    }
  }

  private func seek(ms: Double, result: @escaping FlutterResult) {
    guard let player else { result(FlutterError(code: "not_ready", message: "投屏视频已关闭", details: nil)); return }
    if let previous = pendingSeek {
      pendingSeek = nil
      previous(FlutterError(code: "canceled", message: "定位已取消", details: nil))
    }
    pendingSeek = result
    seeking = true
    let currentRevision = revision
    seekRevision &+= 1
    let currentSeek = seekRevision
    pendingWork += 1
    player.seek(to: CMTime(seconds: ms / 1000, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] success in
      DispatchQueue.main.async {
        guard let self else { return }
        defer { DispatchQueue.main.async { self.finishNativeWork() } }
        guard self.revision == currentRevision, self.seekRevision == currentSeek,
              let callback = self.pendingSeek else { return }
        self.pendingSeek = nil
        self.seeking = false
        if success {
          self.completed = false
          callback(self.snapshot("seeked"))
          self.emit("seeked")
        }
        else { callback(FlutterError(code: "seek_failed", message: "无法定位投屏视频", details: nil)) }
      }
    }
  }

  private func failPrepare(_ message: String) {
    let callback = pendingPrepare
    pendingPrepare = nil
    emit("failed", error: message)
    clear(reason: message)
    callback?(FlutterError(code: "prepare_failed", message: message, details: nil))
  }

  private func stopCandidate() {
    pauseRetainingRoute()
    routeClaimed = false
  }

  private func pauseRetainingRoute() {
    player?.pause()
    player?.isMuted = true
    probing = false
    timeout?.cancel()
    timeout = nil
  }

  private func clear(reason: String) {
    revision &+= 1
    stopCandidate()
    asset?.cancelLoading()
    itemObservation?.invalidate(); itemObservation = nil
    externalObservation?.invalidate(); externalObservation = nil
    controlObservation?.invalidate(); controlObservation = nil
    durationObservation?.invalidate(); durationObservation = nil
    if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    interruptionObserver = nil
    player?.replaceCurrentItem(with: nil)
    player = nil
    asset = nil
    ready = false
    preparingSeek = false
    seeking = false
    completed = false
    interruptionActive = false
    requiresUserResume = false
    hadExternal = false
    token = nil
    let prepare = pendingPrepare; pendingPrepare = nil
    let seek = pendingSeek; pendingSeek = nil
    prepare?(FlutterError(code: "canceled", message: reason, details: nil))
    seek?(FlutterError(code: "canceled", message: reason, details: nil))
  }

  private func milliseconds(_ time: CMTime) -> Int64 {
    let value = CMTimeGetSeconds(time)
    return value.isFinite && value >= 0 ? Int64(min(value * 1000, 1_000_000_000_000)) : 0
  }

  private func snapshot(_ event: String, error: String? = nil) -> [String: Any] {
    eventSequence &+= 1
    let position = player?.currentTime()
    let duration = player?.currentItem?.duration
    func valid(_ time: CMTime?) -> Bool {
      guard let time else { return false }
      let seconds = CMTimeGetSeconds(time)
      return time.isValid && seconds.isFinite && seconds >= 0
    }
    var value: [String: Any] = [
      "event": event,
      "sequence": eventSequence,
      "token": token as Any,
      "positionMs": player.map { milliseconds($0.currentTime()) } ?? 0,
      "durationMs": player?.currentItem.map { milliseconds($0.duration) } ?? 0,
      "positionValid": valid(position),
      "durationValid": valid(duration),
      "ready": ready,
      "external": player?.isExternalPlaybackActive ?? false,
      "playing": player?.timeControlStatus == .playing,
      "buffering": player?.timeControlStatus == .waitingToPlayAtSpecifiedRate,
      "probing": probing,
      "completed": completed,
    ]
    if let error { value["error"] = error }
    return value
  }

  private func emit(_ event: String, error: String? = nil) {
    guard token != nil else { return }
    sink?(snapshot(event, error: error))
  }

  func pickerIdentity() -> (String, Int64)? {
    guard let claimID, let token else { return nil }
    return (claimID, token)
  }
  func pickerEvent(_ event: String, identity: (String, Int64)?) {
    guard let identity, identity.0 == claimID, identity.1 == token else { return }
    emit(event)
  }
}

private final class AirPlayRoutePickerFactory: NSObject, FlutterPlatformViewFactory {
  private weak var bridge: AirPlayVideoBridge?
  init(bridge: AirPlayVideoBridge) { self.bridge = bridge }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    AirPlayRoutePicker(frame: frame, bridge: bridge)
  }
}

private final class AirPlayRoutePicker: NSObject, FlutterPlatformView, AVRoutePickerViewDelegate {
  private let picker: AVRoutePickerView
  private weak var bridge: AirPlayVideoBridge?
  private let identity: (String, Int64)?
  init(frame: CGRect, bridge: AirPlayVideoBridge?) {
    picker = AVRoutePickerView(frame: frame)
    self.bridge = bridge
    identity = bridge?.pickerIdentity()
    super.init()
    picker.prioritizesVideoDevices = true
    picker.tintColor = .white
    picker.activeTintColor = .systemBlue
    picker.delegate = self
    picker.accessibilityLabel = "选择 AirPlay 视频设备"
  }
  func view() -> UIView { picker }
  func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { bridge?.pickerEvent("pickerOpened", identity: identity) }
  func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { bridge?.pickerEvent("pickerClosed", identity: identity) }
}
