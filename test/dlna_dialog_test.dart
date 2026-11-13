import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/airplay_playback_engine.dart';
import 'package:orvex/features/player/infrastructure/dlna/dlna_playback_engine.dart';
import 'package:orvex/features/player/presentation/dlna_dialog.dart';

import 'support/fakes.dart';

class _Transport implements AirPlayTransport {
  @override
  Stream<AirPlayNativeEvent> get events => const Stream.empty();
  @override
  Future<void> close(int token) async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> pause(int token) async {}
  @override
  Future<void> play(int token, {bool userInitiated = false}) async {}
  @override
  Future<void> prepare(LocalMedia media, Duration position, int token) async {}
  @override
  Future<void> probe(int token) async {}
  @override
  Future<void> seek(Duration position, int token) async {}
  @override
  Future<AirPlayNativeEvent> snapshot(int token) async =>
      AirPlayNativeEvent(token: token, kind: 'state');
}

class _StubAirPlay extends AirPlayPlaybackEngine {
  _StubAirPlay() : super(FakeEngine(), transport: _Transport());

  // No native session is opened by this dialog-only test fake.
  @override
  Future<void> dispose() async {
    await local.dispose();
    await transport.dispose();
  }
}

class _RetryEngine extends DlnaPlaybackEngine {
  _RetryEngine() : super(_StubAirPlay(), NativePlaybackReservation());

  bool cleaned = false;
  @override
  Future<void> dispose() async {
    // This test double never opens a remote session or a file service.
    phase.dispose();
    await airplay.dispose();
    cleaned = true;
  }

  Completer<void>? attempt;
  @override
  Future<void> connect(String address) async {
    await attempt!.future;
    phase.value = DlnaPhase.active;
  }
}

void main() {
  testWidgets('dialog displays the precise local recovery issue', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: dlnaIssueMessage('接收设备已停止，本地恢复或文件清理失败，请重启应用')),
      ),
    );
    expect(find.textContaining('接收设备已停止，本地恢复'), findsOneWidget);
    expect(find.textContaining('无法确认设备状态'), findsNothing);
  });

  testWidgets('retry replaces a previous connection error', (tester) async {
    final engine = _RetryEngine();
    addTearDown(() async {
      await engine.dispose().timeout(const Duration(seconds: 2));
      expect(engine.cleaned, isTrue);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDlnaDialog(context, engine),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    engine.attempt = Completer<void>();
    await tester.tap(find.text('连接'));
    await tester.pump();
    engine.attempt!.completeError(StateError('首次失败'));
    await tester.pump();
    expect(find.textContaining('首次失败'), findsOneWidget);

    engine.attempt = Completer<void>();
    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(find.textContaining('首次失败'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    engine.attempt!.completeError(StateError('再次失败'));
    await tester.pump();
    expect(find.textContaining('再次失败'), findsOneWidget);
    expect(find.textContaining('首次失败'), findsNothing);

    engine.attempt = Completer<void>();
    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(find.textContaining('再次失败'), findsNothing);
    engine.attempt!.complete();
    await tester.pump();
    expect(find.textContaining('已发送给设备'), findsOneWidget);
    expect(find.textContaining('连接失败'), findsNothing);
  });

  testWidgets('dismissed dialog ignores a late connection failure', (
    tester,
  ) async {
    final engine = _RetryEngine()..attempt = Completer<void>();
    addTearDown(() async {
      await engine.dispose().timeout(const Duration(seconds: 2));
      expect(engine.cleaned, isTrue);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDlnaDialog(context, engine),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接'));
    await tester.pump();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    engine.attempt!.completeError(StateError('迟到失败'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('迟到失败'), findsNothing);
  });
}
