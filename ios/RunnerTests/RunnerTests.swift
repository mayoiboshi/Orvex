import Flutter
import AVFoundation
import UIKit
import XCTest
@testable import Runner

private final class BridgeTestMessenger: NSObject, FlutterBinaryMessenger {
  private var handlers: [String: FlutterBinaryMessageHandler] = [:]
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) { callback?(nil) }
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    handlers[channel] = handler
    return 1
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}

  func call(_ method: String, _ args: [String: Any] = [:]) -> Any? {
    var result: Any?
    send(method, args) { result = $0 }
    return result
  }

  func send(_ method: String, _ args: [String: Any], completion: @escaping (Any?) -> Void) {
    let codec = FlutterStandardMethodCodec.sharedInstance()
    let call = FlutterMethodCall(methodName: method, arguments: args)
    let message = codec.encode(call)
    handlers["dev.orvex/airplay"]?(message) { reply in
      if let reply { completion(codec.decodeEnvelope(reply)) }
      else { completion(nil) }
    }
  }
}

class RunnerTests: XCTestCase {

  func testNativeInterruptionRequiresExplicitResume() throws {
    #if !targetEnvironment(simulator)
    throw XCTSkip("Generated media is restricted to the iOS simulator")
    #else
    let engine = FlutterEngine(name: "orvex-interruption-test")
    let registrar = try XCTUnwrap(engine.registrar(forPlugin: "interruption-test"))
    let messenger = BridgeTestMessenger()
    let folders = MediaFolderAccess(messenger: messenger, presenter: { nil })
    let bridge = AirPlayVideoBridge(messenger: messenger, registrar: registrar, folders: folders)
    let bridgeID = try XCTUnwrap(messenger.call("identity") as? String)
    let claim = try XCTUnwrap(messenger.call("claimPlayback", ["bridgeId": bridgeID]) as? String)
    let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    let relative = "Imports/\(UUID().uuidString)/sample.mp4"
    let target = documents.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
    let files = try XCTUnwrap(FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil))
    var fixture: URL?
    for case let url as URL in files where url.lastPathComponent == "generated.mp4" { fixture = url; break }
    try FileManager.default.copyItem(at: XCTUnwrap(fixture), to: target)
    let args: [String: Any] = ["bridgeId": bridgeID, "claimId": claim, "token": 1]
    var prepareArgs = args
    prepareArgs["uri"] = target.absoluteString
    prepareArgs["importPath"] = relative
    prepareArgs["positionMs"] = 0
    let prepared = expectation(description: "native candidate prepared")
    messenger.send("prepare", prepareArgs) { value in
      XCTAssertNil(value as? FlutterError)
      prepared.fulfill()
    }
    wait(for: [prepared], timeout: 15)
    func post(_ type: AVAudioSession.InterruptionType) {
      NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
    }
    post(.began)
    XCTAssertEqual((messenger.call("probe", args) as? FlutterError)?.code, "interrupted")
    XCTAssertEqual((messenger.call("play", args) as? FlutterError)?.code, "interrupted")
    var explicitArgs = args
    explicitArgs["userInitiated"] = true
    XCTAssertEqual((messenger.call("play", explicitArgs) as? FlutterError)?.code, "interrupted")
    post(.ended)
    XCTAssertEqual((messenger.call("probe", args) as? FlutterError)?.code, "interrupted")
    XCTAssertEqual((messenger.call("play", args) as? FlutterError)?.code, "interrupted")
    XCTAssertEqual((messenger.call("play", explicitArgs) as? FlutterError)?.code, "route_unavailable")
    _ = messenger.call("close", args)
    let released = expectation(description: "native owner released")
    messenger.send("releasePlayback", ["bridgeId": bridgeID, "claimId": claim]) { _ in released.fulfill() }
    wait(for: [released], timeout: 5)
    withExtendedLifetime((bridge, engine)) {}
    #endif
  }

  func testPickerIgnoresIdentityFromPreviousCandidate() throws {
    #if !targetEnvironment(simulator)
    throw XCTSkip("Native ownership tests run only on the iOS simulator")
    #else
    let engine = FlutterEngine(name: "orvex-picker-identity-test")
    let registrar = try XCTUnwrap(engine.registrar(forPlugin: "picker-identity-test"))
    let messenger = BridgeTestMessenger()
    let folders = MediaFolderAccess(messenger: messenger, presenter: { nil })
    let bridge = AirPlayVideoBridge(messenger: messenger, registrar: registrar, folders: folders)
    let bridgeID = try XCTUnwrap(messenger.call("identity") as? String)
    var claim = try XCTUnwrap(messenger.call("claimPlayback", ["bridgeId": bridgeID]) as? String)
    let listenArgs = ["bridgeId": bridgeID, "claimId": claim, "subscriptionId": "picker-test"]
    var received: [String] = []
    XCTAssertNil(bridge.onListen(withArguments: listenArgs) { value in
      if let event = (value as? [String: Any])?["event"] as? String { received.append(event) }
    })
    func begin(_ token: Int) {
      _ = messenger.call("prepare", ["bridgeId": bridgeID, "claimId": claim, "uri": "file:///missing.mp4", "importPath": "Imports/missing.mp4", "positionMs": 0, "token": token])
    }
    func close(_ token: Int) {
      _ = messenger.call("close", ["bridgeId": bridgeID, "claimId": claim, "token": token])
    }
    begin(1)
    let oldIdentity = try XCTUnwrap(bridge.pickerIdentity())
    close(1)
    let released = expectation(description: "old candidate native work drained")
    messenger.send("releasePlayback", ["bridgeId": bridgeID, "claimId": claim]) { result in
      XCTAssertNil(result)
      released.fulfill()
    }
    wait(for: [released], timeout: 5)
    claim = try XCTUnwrap(messenger.call("claimPlayback", ["bridgeId": bridgeID]) as? String)
    let nextListenArgs = ["bridgeId": bridgeID, "claimId": claim, "subscriptionId": "picker-test-next"]
    XCTAssertNil(bridge.onListen(withArguments: nextListenArgs) { value in
      if let event = (value as? [String: Any])?["event"] as? String { received.append(event) }
    })
    begin(2)
    let newIdentity = try XCTUnwrap(bridge.pickerIdentity())
    received.removeAll()
    bridge.pickerEvent("pickerOpened", identity: oldIdentity)
    XCTAssertTrue(received.isEmpty, "A stale picker must not send events for the new candidate")
    bridge.pickerEvent("pickerOpened", identity: newIdentity)
    XCTAssertEqual(received, ["pickerOpened"])
    close(2)
    XCTAssertNil(bridge.onCancel(withArguments: nextListenArgs))
    _ = messenger.call("releasePlayback", ["bridgeId": bridgeID, "claimId": claim])
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    withExtendedLifetime((bridge, engine)) {}
    #endif
  }

  func testIndependentAirPlayBridgesRejectStaleOwnersAndCancel() throws {
    #if !targetEnvironment(simulator)
    throw XCTSkip("Native ownership tests run only on the iOS simulator")
    #else
    let engineA = FlutterEngine(name: "orvex-owner-test-a")
    let engineB = FlutterEngine(name: "orvex-owner-test-b")
    let registrarA = try XCTUnwrap(engineA.registrar(forPlugin: "owner-test-a"))
    let registrarB = try XCTUnwrap(engineB.registrar(forPlugin: "owner-test-b"))
    let messengerA = BridgeTestMessenger()
    let messengerB = BridgeTestMessenger()
    let foldersA = MediaFolderAccess(messenger: messengerA, presenter: { nil })
    let foldersB = MediaFolderAccess(messenger: messengerB, presenter: { nil })
    let bridgeA = AirPlayVideoBridge(messenger: messengerA, registrar: registrarA, folders: foldersA)
    let bridgeB = AirPlayVideoBridge(messenger: messengerB, registrar: registrarB, folders: foldersB)
    let idA = try XCTUnwrap(messengerA.call("identity") as? String)
    let idB = try XCTUnwrap(messengerB.call("identity") as? String)
    XCTAssertNotEqual(idA, idB)
    let claimA = try XCTUnwrap(messengerA.call("claimPlayback", ["bridgeId": idA]) as? String)
    defer { _ = messengerA.call("releasePlayback", ["bridgeId": idA, "claimId": claimA]) }
    XCTAssertEqual((messengerB.call("claimPlayback", ["bridgeId": idB]) as? FlutterError)?.code, "owner_busy")
    XCTAssertEqual((messengerA.call("releasePlayback", ["bridgeId": idB, "claimId": claimA]) as? FlutterError)?.code, "stale_bridge")
    XCTAssertEqual((messengerA.call("releasePlayback", ["bridgeId": idA, "claimId": "wrong"]) as? FlutterError)?.code, "stale_owner")
    let oldArgs = ["bridgeId": idA, "claimId": claimA, "subscriptionId": "old"]
    let newArgs = ["bridgeId": idA, "claimId": claimA, "subscriptionId": "new"]
    var oldEvents = 0
    var newEvents = 0
    XCTAssertNil(bridgeA.onListen(withArguments: oldArgs) { _ in oldEvents += 1 })
    XCTAssertNil(bridgeA.onListen(withArguments: newArgs) { _ in newEvents += 1 })
    XCTAssertNil(bridgeA.onCancel(withArguments: oldArgs))
    let result = messengerA.call("prepare", ["bridgeId": idA, "claimId": claimA, "uri": "file:///missing.mp4", "positionMs": 0, "token": 1])
    XCTAssertEqual((result as? FlutterError)?.code, "prepare_failed")
    XCTAssertEqual(oldEvents, 0)
    XCTAssertEqual(newEvents, 1)
    XCTAssertNil(bridgeA.onCancel(withArguments: newArgs))
    _ = messengerA.call("releasePlayback", ["bridgeId": idA, "claimId": claimA])
    let claimB = try XCTUnwrap(messengerB.call("claimPlayback", ["bridgeId": idB]) as? String)
    XCTAssertEqual((messengerB.call("close", ["bridgeId": idB, "claimId": claimA, "token": 1]) as? FlutterError)?.code, "stale_owner")
    XCTAssertNil(messengerB.call("releasePlayback", ["bridgeId": idB, "claimId": claimB]))
    withExtendedLifetime((bridgeA, bridgeB, engineA, engineB)) {}
    #endif
  }

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

}
