import Foundation
import XCTest
#if os(iOS)
import Flutter
@testable import Runner
#else
import FlutterMacOS
@testable import Orvex
#endif

/// App-owned generated fixtures only. This does not test a File Provider grant.
final class MediaFolderAccessTests: XCTestCase {
  private func retain(_ access: MediaFolderAccess, handle: String, path: String, identity: String? = nil) throws -> MediaFolderAccess.PlaybackSource {
    let finished = expectation(description: "retain playback source")
    var outcome: Result<MediaFolderAccess.PlaybackSource, Error>?
    access.retainPlaybackSource(handle: handle, path: path, identity: identity) {
      outcome = $0
      finished.fulfill()
    }
    wait(for: [finished], timeout: 5)
    return try XCTUnwrap(outcome).get()
  }

  func testRetainedPlaybackSourceOwnsScopeAndRejectsInvalidSources() throws {
    #if os(iOS) && !targetEnvironment(simulator)
    throw XCTSkip("Generated fixtures are restricted to an iOS simulator")
    #else
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let file = root.appendingPathComponent("video.mp4")
    try Data([1, 2, 3]).write(to: file)
    let messenger = FolderTestMessenger()
    #if os(iOS)
    let access = MediaFolderAccess(messenger: messenger, presenter: { nil })
    #else
    let access = MediaFolderAccess(messenger: messenger)
    #endif
    let selected = try access.selection(root)
    let granted = try XCTUnwrap(try request(access, "acquire", ["grant": selected["grant"]!]) as? [String: Any])
    let handle = try XCTUnwrap(granted["handle"] as? String)
    XCTAssertThrowsError(try retain(access, handle: handle, path: "../outside.mp4"))
    XCTAssertThrowsError(try retain(access, handle: handle, path: "video.mp4", identity: "incorrect-identity"))
    var source: MediaFolderAccess.PlaybackSource? = try retain(access, handle: handle, path: "video.mp4")
    XCTAssertEqual(source?.url.standardizedFileURL, file.standardizedFileURL)
    weak var scope = Mirror(reflecting: try XCTUnwrap(source)).children.first { $0.label == "retainedScope" }?.value as AnyObject?
    XCTAssertNotNil(scope, "The opaque source must own the original scope object")
    _ = try request(access, "release", ["handle": handle])
    XCTAssertNotNil(scope, "Releasing the handle must not release a retained scope")
    XCTAssertThrowsError(try retain(access, handle: handle, path: "video.mp4"))
    source = nil
    XCTAssertNil(scope, "The scope must be released after its last owner")
    #endif
  }
  private func request(_ access: MediaFolderAccess, _ method: String, _ args: [String: Any]) throws -> Any? {
    let finished = expectation(description: method)
    var outcome: Any?
    access.enqueue(method, args) {
      outcome = $0
      finished.fulfill()
    }
    wait(for: [finished], timeout: 5)
    if let error = outcome as? FlutterError {
      throw NSError(domain: error.code, code: 1)
    }
    return outcome
  }

  func testResolveAndReleaseDoNotWaitForThumbnail() throws {
    #if os(iOS) && !targetEnvironment(simulator)
    throw XCTSkip("Generated fixtures are restricted to an iOS simulator")
    #else
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let preview = Data([1])
    let selectedVideo = root.appendingPathComponent("next.mp4")
    try preview.write(to: root.appendingPathComponent("preview.mp4"))
    try Data([2]).write(to: selectedVideo)

    let started = expectation(description: "thumbnail worker entered")
    let proceed = DispatchSemaphore(value: 0)
    defer { proceed.signal() }
    let extractor: (URL) throws -> [String: Any] = { url in
      started.fulfill()
      guard proceed.wait(timeout: .now() + 25) == .success else {
        throw NSError(domain: "ThumbnailTestTimeout", code: 1)
      }
      return ["bytes": try Data(contentsOf: url)]
    }
    let messenger = FolderTestMessenger()
    #if os(iOS)
    let access = MediaFolderAccess(messenger: messenger, presenter: { nil }, thumbnailExtractor: extractor)
    #else
    let access = MediaFolderAccess(messenger: messenger, thumbnailExtractor: extractor)
    #endif
    let selected = try access.selection(root)
    let granted = try XCTUnwrap(try request(access, "acquire", ["grant": selected["grant"]!]) as? [String: Any])
    let handle = try XCTUnwrap(granted["handle"] as? String)
    let finished = expectation(description: "accepted thumbnail completed after release")
    let thumbnailArgs = ["handle": handle, "path": "preview.mp4"]
    access.enqueue("thumbnail", thumbnailArgs) { result in
      XCTAssertEqual((result as? [String: Any])?["bytes"] as? Data, preview)
      finished.fulfill()
    }
    wait(for: [started], timeout: 5)

    let args = ["handle": handle, "path": "next.mp4"]
    let resolved = try XCTUnwrap(try request(access, "resolve", args) as? String)
    XCTAssertEqual(URL(string: resolved)?.resolvingSymlinksInPath(), selectedVideo.resolvingSymlinksInPath())
    _ = try request(access, "release", ["handle": handle])
    XCTAssertThrowsError(try request(access, "resolve", args)) {
      XCTAssertEqual(($0 as NSError).domain, "folder_access")
    }
    XCTAssertThrowsError(try request(access, "thumbnail", thumbnailArgs)) {
      XCTAssertEqual(($0 as NSError).domain, "folder_access")
    }
    proceed.signal()
    wait(for: [finished], timeout: 5)
    #endif
  }

  func testBookmarkTraversalThumbnailAndRelease() throws {
    #if os(iOS) && !targetEnvironment(simulator)
    throw XCTSkip("Generated fixtures are restricted to an iOS simulator")
    #else
    let messenger = FolderTestMessenger()
    #if os(iOS)
    let access = MediaFolderAccess(messenger: messenger, presenter: { nil })
    #else
    let access = MediaFolderAccess(messenger: messenger)
    #endif
    let manager = FileManager.default
    let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let fixture = documents.appendingPathComponent("OrvexFolderTestFixture")
    if manager.fileExists(atPath: fixture.path) { try manager.removeItem(at: fixture) }
    let root = fixture.appendingPathComponent("名侦探柯南")
    let bundleFiles = manager.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)!
    var video: URL?
    for case let candidate as URL in bundleFiles {
      if candidate.lastPathComponent == "generated.mp4" { video = candidate; break }
    }
    let sample = try XCTUnwrap(video, "Compiled Flutter fixture must be available")
    for path in ["TV/0001-0123/第1集.mp4", "TV/0001-0123/第2集.mp4", "TV/0001-0123/第10集.mp4", "TV/0124-0173/第124集.mkv", "TV/0124-0173/第125集.mkv", "剧场版/剧场版1.mp4", "剧场版/剧场版2.mkv"] {
      let target = root.appendingPathComponent(path)
      try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      // Containers are the same generated MP4, even for the .mkv filenames;
      // this tests navigation, not genuine MKV codec/container coverage.
      try manager.copyItem(at: sample, to: target)
    }
    try manager.createSymbolicLink(at: root.appendingPathComponent("TV/loop"), withDestinationURL: root)
    let selected = try access.selection(root)
    let granted = try XCTUnwrap(try request(access, "acquire", ["grant": selected["grant"]!]) as? [String: Any])
    let handle = try XCTUnwrap(granted["handle"] as? String)
    let children = try XCTUnwrap(try request(access, "list", ["handle": handle, "path": "TV"]) as? [[String: Any]])
    XCTAssertEqual(Set(children.compactMap { $0["name"] as? String }), Set(["0001-0123", "0124-0173"]))
    XCTAssertThrowsError(try request(access, "resolve", ["handle": handle, "path": "../outside.mp4"]))
    XCTAssertThrowsError(try request(access, "thumbnail", ["handle": handle, "path": "../outside.mp4"])) {
      XCTAssertEqual(($0 as NSError).domain, "folder_access")
    }
    XCTAssertThrowsError(try request(access, "thumbnailImported", ["path": "Imports/../outside.mp4"])) {
      XCTAssertEqual(($0 as NSError).domain, "folder_access")
    }
    let thumbnail = try XCTUnwrap(try request(access, "thumbnail", ["handle": handle, "path": "TV/0001-0123/第1集.mp4"]) as? [String: Any])
    XCTAssertGreaterThan(try XCTUnwrap(thumbnail["duration"] as? Int), 10000)
    XCTAssertGreaterThan(try XCTUnwrap(thumbnail["bytes"] as? FlutterStandardTypedData).data.count, 1000)
    _ = try request(access, "release", ["handle": handle])
    XCTAssertThrowsError(try request(access, "list", ["handle": handle, "path": ""]))
    // New adapter instance models process-scope loss; the persisted bookmark
    // must independently resolve without the previous live scope.
    #if os(iOS)
    let restored = MediaFolderAccess(messenger: messenger, presenter: { nil })
    #else
    let restored = MediaFolderAccess(messenger: messenger)
    #endif
    let reopened = try XCTUnwrap(try request(restored, "acquire", ["grant": selected["grant"]!]) as? [String: Any])
    _ = try request(restored, "release", ["handle": reopened["handle"]!])
    let exported: [String: Any] = ["id": "native-fixture-root", "name": selected["name"]!, "grant": selected["grant"]!, "location": selected["location"]!, "identity": selected["identity"] ?? NSNull()]
    try JSONSerialization.data(withJSONObject: exported).write(to: documents.appendingPathComponent("orvex-folder-native-test.json"), options: .atomic)
    #endif
  }
}

private final class FolderTestMessenger: NSObject, FlutterBinaryMessenger {
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) { callback?(nil) }
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { 1 }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}
