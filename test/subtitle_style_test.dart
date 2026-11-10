import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/application/playback_session.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/domain/subtitle_style.dart';
import 'package:orvex/features/player/infrastructure/subtitle_style_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';

class FailingStyleStore implements SubtitleStyleStore {
  @override
  Future<SubtitleStyle> read() async => const SubtitleStyle();
  @override
  Future<void> write(SubtitleStyle value) async =>
      throw StateError('disk full');
}

void main() {
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );

  test(
    'style preferences tolerate missing and invalid fields and persist choices',
    () async {
      final store = SubtitleStylePreferences();
      expect((await store.read()).overrideAss, false);
      final preferences = SharedPreferencesAsync();
      await preferences.setString(
        SubtitleStylePreferences.key,
        '{"delay":1000,"scale":"bad","color":"not a color","bold":true}',
      );
      final old = await store.read();
      expect(old.delay, 0);
      expect(old.scale, 1);
      expect(old.color, '#FFFFFFFF');
      expect(old.bold, true);
      expect(old.overrideAss, false);
      final chosen = old.copyWith(
        delay: -1.5,
        scale: 1.5,
        overrideAss: true,
        color: '#FFFFFF00',
      );
      await store.write(chosen);
      expect(
        (await SubtitleStylePreferences().read()).toJson(),
        chosen.toJson(),
      );
    },
  );

  test('changes apply and persist, reopen retains settings, engine failures are visible', () async {
    final store = SubtitleStylePreferences();
    final engines = <FakeEngine>[];
    final session = PlaybackSession(
      createEngine: () {
        final e = FakeEngine();
        engines.add(e);
        return e;
      },
      resumeStore: MemoryResumeStore(),
      subtitleStyleStore: store,
    );
    final first = LocalMedia(uri: Uri.file('/first.mp4'), name: 'first.mp4');
    final second = LocalMedia(uri: Uri.file('/second.mp4'), name: 'second.mp4');
    await session.open(first);
    final value = session.subtitleStyle.copyWith(
      delay: 1.5,
      scale: 1.3,
      bold: true,
      overrideAss: true,
    );
    await session.setSubtitleStyle(value);
    expect(engines.last.subtitleStyles.last.toJson(), value.toJson());
    expect((await store.read()).toJson(), value.toJson());
    await session.open(second);
    expect(engines.last.subtitleStyles.last.toJson(), value.toJson());
    engines.last.failSubtitleStyle = true;
    await session.setSubtitleStyle(value.copyWith(delay: 2));
    expect(session.subtitleStyleIssue, contains('未完全应用'));
    expect((await store.read()).delay, 2);
    await session.shutdown();
    session.dispose();
    for (final e in engines) {
      await e.cleanUp();
    }
  });

  test('save failure is reported after engine application', () async {
    final engine = FakeEngine();
    final session = PlaybackSession(
      createEngine: () => engine,
      resumeStore: MemoryResumeStore(),
      subtitleStyleStore: FailingStyleStore(),
    );
    await session.open(
      LocalMedia(uri: Uri.file('/first.mp4'), name: 'first.mp4'),
    );
    await session.setSubtitleStyle(session.subtitleStyle.copyWith(delay: 2));
    expect(engine.subtitleStyles.last.delay, 2);
    expect(session.subtitleStyleIssue, contains('保存失败'));
    await session.shutdown();
    session.dispose();
    await engine.cleanUp();
  });

  test('changing style during a switch keeps settings for the next engine and restart', () async {
    final store = SubtitleStylePreferences();
    final engines = <FakeEngine>[];
    final session = PlaybackSession(
      createEngine: () {
        final engine = FakeEngine();
        engines.add(engine);
        return engine;
      },
      resumeStore: MemoryResumeStore(),
      subtitleStyleStore: store,
    );
    await session.open(
      LocalMedia(uri: Uri.file('/first.mp4'), name: 'first.mp4'),
    );
    engines.first.subtitleStyleGate = Completer<void>();
    final change = session.setSubtitleStyle(
      session.subtitleStyle.copyWith(delay: 2),
    );
    await Future<void>.delayed(Duration.zero);
    final switching = session.open(
      LocalMedia(uri: Uri.file('/second.mp4'), name: 'second.mp4'),
    );
    engines.first.subtitleStyleGate!.complete();
    await Future.wait([change, switching]);
    expect((await store.read()).delay, 2);
    expect(engines.last.subtitleStyles.last.delay, 2);
    await session.shutdown();
    session.dispose();
    for (final engine in engines) {
      await engine.cleanUp();
    }
  });

  test('preview does not persist and commit supersedes it', () async {
    final store = SubtitleStylePreferences();
    final engine = FakeEngine();
    final session = PlaybackSession(
      createEngine: () => engine,
      resumeStore: MemoryResumeStore(),
      subtitleStyleStore: store,
    );
    await session.open(
      LocalMedia(uri: Uri.file('/first.mp4'), name: 'first.mp4'),
    );
    final preview = session.subtitleStyle.copyWith(scale: 1.5);
    await session.previewSubtitleStyle(preview);
    expect(engine.subtitleStyles.last.scale, 1.5);
    expect(session.subtitleStyle.scale, 1);
    expect((await store.read()).scale, 1);
    await session.setSubtitleStyle(preview.copyWith(scale: 1.8));
    expect(engine.subtitleStyles.last.scale, 1.8);
    expect((await store.read()).scale, 1.8);
    await session.shutdown();
    session.dispose();
    await engine.cleanUp();
  });

  test(
    'slow previews restore on dismiss and never overwrite a new session',
    () async {
      final engines = <FakeEngine>[];
      final session = PlaybackSession(
        createEngine: () {
          final engine = FakeEngine();
          engines.add(engine);
          return engine;
        },
        resumeStore: MemoryResumeStore(),
      );
      await session.open(
        LocalMedia(uri: Uri.file('/first.mp4'), name: 'first.mp4'),
      );
      final old = engines.first;
      old.subtitleStyleGate = Completer<void>();
      final preview = session.previewSubtitleStyle(
        session.subtitleStyle.copyWith(scale: 1.5),
      );
      await Future<void>.delayed(Duration.zero);
      final restore = session.previewSubtitleStyle(session.subtitleStyle);
      old.subtitleStyleGate!.complete();
      await Future.wait([preview, restore]);
      expect(old.subtitleStyles.last.scale, 1);

      old.subtitleStyleGate = Completer<void>();
      final stale = session.previewSubtitleStyle(
        session.subtitleStyle.copyWith(scale: 1.7),
      );
      await Future<void>.delayed(Duration.zero);
      final switching = session.open(
        LocalMedia(uri: Uri.file('/second.mp4'), name: 'second.mp4'),
      );
      old.subtitleStyleGate!.complete();
      await Future.wait([stale, switching]);
      expect(engines.last.subtitleStyles.last.scale, 1);
      await session.shutdown();
      session.dispose();
      for (final engine in engines) {
        await engine.cleanUp();
      }
    },
  );
}
