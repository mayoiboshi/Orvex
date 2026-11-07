import Foundation
import AVFoundation
#if os(iOS)
import Flutter
import UIKit
import UniformTypeIdentifiers
#else
import FlutterMacOS
import AppKit
#endif

/// Read-only access. Every live bookmark scope has a matching release after
/// the scan, thumbnail request or playback engine has finished using it.
final class MediaFolderAccess: NSObject {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "dev.orvex.folders", qos: .utility)
  private var scopes: [String: (URL, Bool)] = [:]
  private var pickerResult: FlutterResult?
  #if os(iOS)
  private let presenter: () -> UIViewController?
  init(messenger: FlutterBinaryMessenger, presenter: @escaping () -> UIViewController?) {
    self.presenter = presenter
    channel = FlutterMethodChannel(name: "dev.orvex/folders", binaryMessenger: messenger)
    super.init()
    install()
  }
  #else
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.orvex/folders", binaryMessenger: messenger)
    super.init()
    install()
  }
  #endif

  deinit {
    for scope in scopes.values where scope.1 { scope.0.stopAccessingSecurityScopedResource() }
  }

  private func bookmark(_ url: URL) throws -> String {
    #if os(iOS)
    let options: URL.BookmarkCreationOptions = .minimalBookmark
    #else
    let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
    #endif
    return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
  }

  private func identity(_ url: URL) -> String? {
    guard let values = try? url.resourceValues(forKeys: [.documentIdentifierKey, .volumeUUIDStringKey]),
          let id = values.documentIdentifier, id > 0,
          let volume = values.volumeUUIDString else { return nil }
    return "\(volume):\(id)"
  }

  func selection(_ url: URL) throws -> [String: Any] {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    var value: [String: Any] = ["name": url.lastPathComponent, "grant": try bookmark(url), "location": url.absoluteString]
    if let id = identity(url) { value["identity"] = id }
    return value
  }

  private func install() {
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      if call.method == "pick" { self.pick(result); return }
      let args = call.arguments as? [String: Any] ?? [:]
      self.queue.async {
        do {
          let value = try self.handle(call.method, args)
          DispatchQueue.main.async { result(value) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: call.method.hasPrefix("thumbnail") && (error as NSError).domain != "OrvexFolders" ? "thumbnail_unavailable" : "folder_access", message: error.localizedDescription, details: nil)) }
        }
      }
    }
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard pickerResult == nil else { result(FlutterError(code: "busy", message: "目录选择器已打开", details: nil)); return }
    #if os(iOS)
    guard let view = presenter() else { result(FlutterError(code: "no_window", message: "无法打开目录选择器", details: nil)); return }
    pickerResult = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    view.present(picker, animated: true)
    #else
    pickerResult = result
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "添加媒体文件夹"
    panel.begin { [weak self] response in
      guard let self else { return }
      let callback = self.pickerResult
      self.pickerResult = nil
      do { callback?(try response == .OK ? self.selection(panel.url!) : nil) }
      catch { callback?(FlutterError(code: "folder_access", message: error.localizedDescription, details: nil)) }
    }
    #endif
  }

  private func url(_ args: [String: Any]) throws -> URL {
    guard let handle = args["handle"] as? String, let root = scopes[handle]?.0 else { throw failure("目录授权已失效，请重新授权") }
    let relative = args["path"] as? String ?? ""
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard relative.isEmpty || parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { throw failure("无效的相对路径") }
    let target = relative.isEmpty ? root : root.appendingPathComponent(relative)
    // Refuse symlink traversal, including links introduced after a scan.
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else { throw failure("文件超出授权目录") }
    return target
  }

  func handle(_ method: String, _ args: [String: Any]) throws -> Any? {
    switch method {
    case "acquire":
      guard let raw = args["grant"] as? String, let data = Data(base64Encoded: raw) else { throw failure("目录书签无效，请重新授权") }
      var stale = false
      #if os(iOS)
      let options: URL.BookmarkResolutionOptions = [.withoutUI]
      #else
      let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
      #endif
      let root = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
      let scoped = root.startAccessingSecurityScopedResource()
      do {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw failure("目录不存在，请重新授权") }
        let handle = UUID().uuidString
        scopes[handle] = (root, scoped)
        var value: [String: Any] = ["handle": handle, "location": root.absoluteString]
        if stale { value["grant"] = try bookmark(root) }
        if let id = identity(root) { value["identity"] = id }
        return value
      } catch { if scoped { root.stopAccessingSecurityScopedResource() }; throw error }
    case "release":
      if let key = args["handle"] as? String, let scope = scopes.removeValue(forKey: key), scope.1 { scope.0.stopAccessingSecurityScopedResource() }
      return nil
    case "list":
      let directory = try url(args)
      var coordinationError: NSError?
      var output: [[String: Any]] = []
      var readError: Error?
      NSFileCoordinator().coordinate(readingItemAt: directory, options: [], error: &coordinationError) { readable in
        do {
          let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .documentIdentifierKey, .volumeUUIDStringKey]
          for child in try FileManager.default.contentsOfDirectory(at: readable, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            do {
              let values = try child.resourceValues(forKeys: keys)
              if values.isSymbolicLink == true || values.isPackage == true { continue }
              if values.isDirectory != true && values.isRegularFile != true { continue }
              var entry: [String: Any] = ["name": child.lastPathComponent, "directory": values.isDirectory == true, "size": values.fileSize ?? 0, "modified": Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)]
              if let id = self.identity(child) { entry["identity"] = id }
              output.append(entry)
            } catch { output.append(["name": child.lastPathComponent, "error": error.localizedDescription]) }
          }
        } catch { readError = error }
      }
      if let error = coordinationError ?? readError as NSError? { throw error }
      return output
    case "resolve":
      let target = try url(args)
      guard FileManager.default.isReadableFile(atPath: target.path) else { throw failure("视频不存在或无法读取，请重新扫描或授权") }
      if let expected = args["identity"] as? String, identity(target) != expected { throw failure("文件身份已变化，请重新扫描") }
      return target.absoluteString
    case "thumbnail":
      return try thumbnail(url(args))
    case "thumbnailImported":
      guard let path = args["path"] as? String else { throw failure("导入文件位置无效") }
      let parts = path.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count >= 2, parts.first == "Imports", parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else { throw failure("导入文件位置无效") }
      let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      let source = documents.appendingPathComponent(path)
      let imports = documents.appendingPathComponent("Imports").resolvingSymlinksInPath().standardizedFileURL.path
      guard source.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(imports + "/") else { throw failure("文件超出导入目录") }
      return try thumbnail(source)
    default: return FlutterMethodNotImplemented
    }
  }

  private func thumbnail(_ source: URL) throws -> [String: Any] {
      let asset = AVURLAsset(url: source)
      let loaded = DispatchSemaphore(value: 0)
      asset.loadValuesAsynchronously(forKeys: ["duration"]) { loaded.signal() }
      guard loaded.wait(timeout: .now() + 15) == .success else { asset.cancelLoading(); throw previewFailure("预览读取超时") }
      var loadError: NSError?
      guard asset.statusOfValue(forKey: "duration", error: &loadError) == .loaded else { throw loadError ?? previewFailure("无法读取视频时长") }
      let duration = CMTimeGetSeconds(asset.duration)
      guard duration.isFinite && duration > 0 else { throw previewFailure("当前格式无法提取预览") }
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 480, height: 270)
      let time = CMTime(seconds: min(90, max(1, duration * 0.15)), preferredTimescale: 600)
      let semaphore = DispatchSemaphore(value: 0)
      let lock = NSLock()
      var image: CGImage?
      generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, frame, _, _, _ in
        lock.lock(); image = frame; lock.unlock(); semaphore.signal()
      }
      let status = semaphore.wait(timeout: .now() + 15)
      generator.cancelAllCGImageGeneration()
      lock.lock(); let frame = image; lock.unlock()
      guard status == .success, let frame else { throw previewFailure("预览提取失败") }
      #if os(iOS)
      let data = UIImage(cgImage: frame).jpegData(compressionQuality: 0.78)
      #else
      let data = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.78])
      #endif
      guard let bytes = data else { throw previewFailure("预览编码失败") }
      return ["bytes": FlutterStandardTypedData(bytes: bytes), "duration": Int(duration * 1000)]
  }

  private func previewFailure(_ message: String) -> NSError { NSError(domain: "OrvexPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

  private func failure(_ message: String) -> NSError { NSError(domain: "OrvexFolders", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

#if os(iOS)
extension MediaFolderAccess: UIDocumentPickerDelegate {
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let callback = pickerResult; pickerResult = nil; callback?(nil)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let callback = pickerResult; pickerResult = nil
    do { callback?(try urls.first.map { try selection($0) }) }
    catch { callback?(FlutterError(code: "folder_access", message: error.localizedDescription, details: nil)) }
  }
}
#endif
