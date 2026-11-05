import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/anime_metadata/application/anime_metadata_controller.dart';
import '../features/library/infrastructure/playback_history_store.dart';
import '../features/media_sources/local_file_source.dart';
import '../features/player/application/playback_session.dart';
import '../features/player/infrastructure/media_kit_engine.dart';
import '../features/player/infrastructure/preferences_resume_store.dart';
import '../features/player/presentation/player_page.dart';

final localFilesProvider = Provider<LocalFileSource>(
  (ref) => LocalFileSource(),
);
final historyStoreProvider = Provider<PlaybackHistoryStore>(
  (ref) => PlaybackHistoryStore(),
);
final animeMetadataProvider = Provider<AnimeMetadataController>((ref) {
  final metadata = AnimeMetadataController();
  ref.onDispose(metadata.dispose);
  return metadata;
});

final sessionProvider = Provider<PlaybackSession>((ref) {
  final session = PlaybackSession(
    createEngine: () => MediaKitEngine(
      silentAudioForTesting: const bool.fromEnvironment(
        'ORVEX_SILENT_SIMULATOR_TEST',
      ),
    ),
    resumeStore: PreferencesResumeStore(),
    onCheckpoint: ref.read(historyStoreProvider).record,
  );
  ref.onDispose(session.dispose);
  return session;
});

class OrvexApp extends StatelessWidget {
  const OrvexApp({super.key, this.startupError});
  final String? startupError;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Orvex',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF0B0D12),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFF4B763),
        brightness: Brightness.dark,
        surface: const Color(0xFF17191F),
      ),
      fontFamilyFallback: const [
        'PingFang SC',
        'Microsoft YaHei',
        'sans-serif',
      ],
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    ),
    home: PlayerPage(startupError: startupError),
  );
}
