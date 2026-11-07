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
    let granted = try XCTUnwrap(try access.handle("acquire", ["grant": selected["grant"]!]) as? [String: Any])
    let handle = try XCTUnwrap(granted["handle"] as? String)
    let children = try XCTUnwrap(try access.handle("list", ["handle": handle, "path": "TV"]) as? [[String: Any]])
    XCTAssertEqual(Set(children.compactMap { $0["name"] as? String }), Set(["0001-0123", "0124-0173"]))
    XCTAssertThrowsError(try access.handle("resolve", ["handle": handle, "path": "../outside.mp4"]))
    let thumbnail = try XCTUnwrap(try access.handle("thumbnail", ["handle": handle, "path": "TV/0001-0123/第1集.mp4"]) as? [String: Any])
    XCTAssertGreaterThan(try XCTUnwrap(thumbnail["duration"] as? Int), 10000)
    XCTAssertGreaterThan(try XCTUnwrap(thumbnail["bytes"] as? FlutterStandardTypedData).data.count, 1000)
    _ = try access.handle("release", ["handle": handle])
    XCTAssertThrowsError(try access.handle("list", ["handle": handle, "path": ""]))
    // New adapter instance models process-scope loss; the persisted bookmark
    // must independently resolve without the previous live scope.
    #if os(iOS)
    let restored = MediaFolderAccess(messenger: messenger, presenter: { nil })
    #else
    let restored = MediaFolderAccess(messenger: messenger)
    #endif
    let reopened = try XCTUnwrap(try restored.handle("acquire", ["grant": selected["grant"]!]) as? [String: Any])
    _ = try restored.handle("release", ["handle": reopened["handle"]!])
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
