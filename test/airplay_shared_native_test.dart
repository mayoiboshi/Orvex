import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/airplay_playback_engine.dart';

import 'support/fakes.dart';

// Models one native bridge and FIFO method delivery. As in the Swift bridge,
// prepare installs its token synchronously, while its result may arrive later.
class _SharedNative {
  final events = StreamController<AirPlayNativeEvent>.broadcast(sync: true);
  final firstPrepare = Completer<void>();
  final received = <String>[];
  int? token;
  int? firstToken;
  bool failClose = false;

  Future<void> prepare(int requested) {
    received.add('prepare:$requested');
    token = requested;
    if (firstToken == null) {
      firstToken = requested;
      return firstPrepare.future;
    }
    return Future.value();
  }

  Future<void> close(int requested) async {
    received.add('close:$requested');
    if (failClose) throw StateError('native close failed');
    if (token == null) return;
    if (token != requested) throw StateError('stale_session');
    token = null;
  }
}

class _Transport implements AirPlayTransport {
  _Transport(this.native);
  final _SharedNative native;
  @override
  Stream<AirPlayNativeEvent> get events => native.events.stream;
  @override
  Future<void> prepare(LocalMedia media, Duration position, int token) =>
      native.prepare(token);
  @override
  Future<void> close(int token) => native.close(token);
  @override
  Future<void> probe(int token) async {}
  @override
  Future<void> seek(Duration position, int token) async {}
  @override
  Future<void> play(int token, {bool userInitiated = false}) async {}
  @override
  Future<void> pause(int token) async {}
  @override
  Future<AirPlayNativeEvent> snapshot(int token) async =>
      AirPlayNativeEvent(token: token, kind: 'state', external: true);
  @override
  Future<void> dispose() async {}
}

void main() {
  test(
    'late old prepare result, close command and event cannot affect new token',
    () async {
      final native = _SharedNative();
      final oldLocal = FakeEngine();
      final newLocal = FakeEngine();
      final oldTransport = _Transport(native);
      final newTransport = _Transport(native);
      final oldEngine = AirPlayPlaybackEngine(
        oldLocal,
        transport: oldTransport,
      );
      final newEngine = AirPlayPlaybackEngine(
        newLocal,
        transport: newTransport,
      );
      final media = LocalMedia(
        uri: Uri.file('/example.mp4'),
        name: 'example.mp4',
      );
      await oldEngine.open(media, start: Duration.zero);
      final oldPreparing = oldEngine.prepareRoute();
      await Future<void>.delayed(Duration.zero);
      final oldToken = native.firstToken!;
      await oldEngine.dispose();
      expect(native.token, isNull);
      await newEngine.open(media, start: Duration.zero);
      expect(await newEngine.prepareRoute(), isTrue);
      final newToken = native.token!;
      expect(newToken, isNot(oldToken));
      native.firstPrepare.complete();
      expect(await oldPreparing, isFalse);
      await expectLater(oldTransport.close(oldToken), throwsStateError);
      native.events.add(
        AirPlayNativeEvent(token: oldToken, kind: 'state', external: true),
      );
      await Future<void>.delayed(Duration.zero);
      expect(native.token, newToken);
      expect(newEngine.externalActive, isFalse);
      expect(native.received.take(3), [
        'prepare:$oldToken',
        'close:$oldToken',
        'prepare:$newToken',
      ]);
      await newEngine.dispose();
      await native.events.close();
      await oldLocal.cleanUp();
      await newLocal.cleanUp();
    },
  );
}
