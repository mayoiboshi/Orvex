import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/folder_library/media_kit_preview.dart';
import 'package:orvex/features/folder_library/thumbnail_cache.dart';
import 'package:orvex/features/media_sources/imported_file_store.dart';

import '../test/fixtures/preview_mkv.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'native failure falls back to libmpv for genuine MKV without a visible video widget',
    (tester) async {
      if (Platform.isIOS) {
        expect(
          await const MethodChannel('dev.orvex/audio-session')
              .invokeMethod<bool>('isSimulator'),
          isTrue,
          reason: 'Generated fixtures are forbidden on physical iOS devices',
        );
      }
      MediaKit.ensureInitialized();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final directory = await Directory.systemTemp.createTemp(
        'orvex-mkv-preview-',
      );
      final file = await File('${directory.path}/actual.mkv')
          .writeAsBytes(base64Decode(previewMkvBase64));
      final imports = ImportedFileStore();
      final media = await imports.import(XFile(file.path));
      final library = FolderLibrary(directory: () async => directory);
      await library.initialize();
      final cache = ThumbnailCache(
        library,
        imports: imports,
        fallback: MediaKitPreview().extract,
      );
      try {
        final request = cache.requestImported(media);
        final end = DateTime.now().add(const Duration(seconds: 40));
        while (!request.completer.isCompleted && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(request.completer.isCompleted, isTrue);
        final result = await request.result;
        expect(result, isNotNull, reason: request.issue);
        expect(request.backend, 'libmpv');
        expect(request.nativeFailure, 'thumbnail_unavailable');
        expect(request.duration, inInclusiveRange(2900, 3100));
        final codec = await ui.instantiateImageCodec(
          await result!.readAsBytes(),
        );
        final frame = await codec.getNextFrame();
        expect(frame.image.width, lessThanOrEqualTo(480));
        expect(frame.image.height, lessThanOrEqualTo(270));
        final pixels = await frame.image.toByteData();
        final i =
            ((frame.image.height ~/ 2) * frame.image.width +
                frame.image.width ~/ 2) *
            4;
        expect(
          pixels!.getUint8(i + 2),
          greaterThan(180),
          reason: 'The decoded fixture is blue',
        );
        expect(pixels.getUint8(i), lessThan(70));
        frame.image.dispose();
        codec.dispose();
        await File('${directory.path}/results.txt').writeAsString(
          'Actual Matroska/H.264, generated blue 160x90, 3s; no audio.\nNative Apple decoder rejected MKV, libmpv fallback produced an actual frame without a Video widget.\nBounded output dimensions and decoded blue pixels checked; main PlaybackSession is not used.\nPhysical device is not this experiment.\n',
        );
        debugPrint('ORVEX_MKV_EVIDENCE=${directory.path}');
      } finally {
        cache.dispose();
        library.dispose();
      }
    },
  );
}
