import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/infrastructure/preferences_resume_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );
  const relative = 'Imports/media-a/Conan 0615.mkv';
  final old = LocalMedia(
    uri: Uri.file(
      '/private/var/mobile/Containers/Data/Application/OLD/Documents/$relative',
    ),
    name: 'Conan 0615.mkv',
  );
  final recent = LocalMedia(
    uri: Uri.file(
      '/private/var/mobile/Containers/Data/Application/RECENT/Documents/$relative',
    ),
    name: old.name,
  );
  final current = LocalMedia(
    uri: Uri.file(
      '/private/var/mobile/Containers/Data/Application/CURRENT/Documents/$relative',
    ),
    name: old.name,
    importPath: relative,
  );

  test('migrates the most recent viewing position, then stable progress survives another container move', () async {
    final preferences = SharedPreferencesAsync();
    await preferences.setInt('orvex.resume.v1.${old.uri}', 42000);
    await preferences.setInt('orvex.resume.v1.${recent.uri}', 33000);
    await preferences.setStringList('orvex.history.v1', [
      jsonEncode({
        'uri': old.uri.toString(),
        'name': old.name,
        'position': 42000,
        'updatedAt': '2026-11-05T14:26:14Z',
        'completed': false,
      }),
      jsonEncode({
        'uri': recent.uri.toString(),
        'name': recent.name,
        'position': 33000,
        'updatedAt': '2026-11-05T15:16:01Z',
        'completed': false,
      }),
    ]);
    final store = PreferencesResumeStore();
    expect(old.resumeKey, current.resumeKey);
    expect(await store.read(current.resumeKey), const Duration(seconds: 33));
    await store.write(current.resumeKey, const Duration(seconds: 12));
    final moved = LocalMedia(
      uri: Uri.file(
        '/private/var/mobile/Containers/Data/Application/NEXT/Documents/$relative',
      ),
      name: old.name,
    );
    expect(
      await PreferencesResumeStore().read(moved.resumeKey),
      const Duration(seconds: 12),
    );
    expect(
      await preferences.getInt('orvex.resume.v1.${old.uri}'),
      42000,
      reason: 'legacy progress is retained as a recovery source',
    );
  });

  test('rebased completed history restarts at zero instead of reviving an older checkpoint', () async {
    final preferences = SharedPreferencesAsync();
    await preferences.setInt('orvex.resume.v1.${old.uri}', 42000);
    await preferences.setStringList('orvex.history.v2', [
      jsonEncode({
        'uri': current.uri.toString(),
        'importPath': relative,
        'name': current.name,
        'position': 1452000,
        'updatedAt': '2026-11-05T15:16:01Z',
        'completed': true,
      }),
    ]);
    expect(
      await PreferencesResumeStore().read(current.resumeKey),
      Duration.zero,
    );
  });

  test('a single pre-history checkpoint migrates without mixing same-name independent files', () async {
    final preferences = SharedPreferencesAsync();
    await preferences.setInt('orvex.resume.v1.${old.uri}', 42000);
    final other = Uri.file(
      '/private/var/mobile/Containers/Data/Application/OLD/Documents/Imports/media-b/Conan 0615.mkv',
    );
    await preferences.setInt('orvex.resume.v1.$other', 90000);
    expect(
      await PreferencesResumeStore().read(current.resumeKey),
      const Duration(seconds: 42),
    );
    final desktop = LocalMedia(
      uri: Uri.file('/Volumes/library/Imports/media-a/Conan 0615.mkv'),
      name: old.name,
    );
    expect(desktop.relativeImportPath, isNull);
    expect(desktop.resumeKey, desktop.uri.toString());
  });
}
