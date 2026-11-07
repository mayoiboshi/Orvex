import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/appearance_controller.dart';
import '../design/orvex_theme.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/anime_metadata/application/anime_metadata_controller.dart';
import '../features/library/infrastructure/playback_history_store.dart';
import '../features/media_sources/local_file_source.dart';
import '../features/folder_library/folder_library.dart';
import '../features/folder_library/thumbnail_cache.dart';
import '../features/folder_library/media_kit_preview.dart';
import '../features/subtitles/infrastructure/local_subtitles.dart';
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
  final folders = ref.read(folderLibraryProvider);
  final metadata = AnimeMetadataController(
    queryResolver: (media) => folders.identityFor(media).query,
    groupResolver: (media) => folders.identityFor(media).key,
  );
  ref.onDispose(metadata.dispose);
  return metadata;
});

final folderLibraryProvider = Provider<FolderLibrary>((ref) {
  final library = FolderLibrary();
  unawaited(library.initialize());
  ref.onDispose(library.dispose);
  return library;
});
final thumbnailCacheProvider = Provider<ThumbnailCache>((ref) {
  final cache = ThumbnailCache(
    ref.read(folderLibraryProvider),
    imports: ref.read(localFilesProvider).imports,
    fallback: Platform.isIOS || Platform.isMacOS
        ? MediaKitPreview().extract
        : null,
  );
  ref.onDispose(cache.dispose);
  return cache;
});

final sessionProvider = Provider<PlaybackSession>((ref) {
  final session = PlaybackSession(
    createEngine: () => MediaKitEngine(
      silentAudioForTesting: const bool.fromEnvironment(
        'ORVEX_SILENT_SIMULATOR_TEST',
      ),
    ),
    resumeStore: PreferencesResumeStore(),
    subtitleSupport: LocalSubtitles(
      folders: ref.read(folderLibraryProvider),
      imports: ref.read(localFilesProvider).imports,
    ),
    prepare: (source) async {
      if (source.folderRoot != null) {
        final result = await ref.read(folderLibraryProvider).prepare(source);
        return PreparedPlayback(result.media, result.release);
      }
      return PreparedPlayback(
        await ref.read(localFilesProvider).imports.resolve(source),
      );
    },
    onCheckpoint: ref.read(historyStoreProvider).record,
  );
  ref.onDispose(session.dispose);
  return session;
});

final appearanceProvider = Provider<AppearanceController>((ref) {
  final appearance = AppearanceController();
  unawaited(appearance.initialize());
  ref.onDispose(appearance.dispose);
  return appearance;
});

class OrvexApp extends ConsumerWidget {
  const OrvexApp({super.key, this.startupError});
  final String? startupError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(appearanceProvider);
    return AppearanceScope(
      controller: appearance,
      child: ListenableBuilder(
        listenable: appearance,
        builder: (context, _) => MaterialApp(
          title: 'Orvex',
          debugShowCheckedModeBanner: false,
          theme: OrvexTheme.create(Brightness.light),
          darkTheme: OrvexTheme.create(Brightness.dark),
          themeMode: appearance.mode,
          themeAnimationDuration: appearance.reduceMotion
              ? Duration.zero
              : OrvexMetrics.motion,
          themeAnimationCurve: OrvexMetrics.curve,
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: OrvexTheme.systemOverlay(Theme.of(context).brightness),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations:
                    MediaQuery.disableAnimationsOf(context) ||
                    appearance.reduceMotion,
              ),
              child: child!,
            ),
          ),
          home: PlayerPage(startupError: startupError),
        ),
      ),
    );
  }
}
