import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/folder_library/folder_library.dart';
import 'package:orvex/features/player/domain/playback_engine.dart';
import 'package:orvex/features/player/presentation/episode_picker.dart';

void main() {
  testWidgets(
    'queue shows current item and selects another without playback side effects',
    (tester) async {
      final library = FolderLibrary();
      addTearDown(library.dispose);
      final items = [
        LocalMedia(uri: Uri.file('/show 01.mkv'), name: 'show 01.mkv'),
        LocalMedia(uri: Uri.file('/show 02.mkv'), name: 'show 02.mkv'),
      ];
      LocalMedia? selected;
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 740,
              height: 350,
              child: EpisodePicker(
                items: items,
                currentKey: items.first.resumeKey,
                library: library,
                thumbnails: null,
                titleFor: (media) => media.name,
                onSelect: (media) => selected = media,
                onClose: () => closed = true,
              ),
            ),
          ),
        ),
      );
      expect(
        find.byKey(ValueKey('episode-${items.first.resumeKey}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('episode-${items.last.resumeKey}')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.equalizer_rounded), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('episode-${items.last.resumeKey}')));
      expect(selected?.resumeKey, items.last.resumeKey);
      await tester.tap(find.byTooltip('关闭选集'));
      expect(closed, isTrue);
      closed = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('picker remains usable in a narrow landscape viewport', (
    tester,
  ) async {
    final library = FolderLibrary();
    addTearDown(library.dispose);
    final item = LocalMedia(uri: Uri.file('/one.mkv'), name: 'one.mkv');
    var selected = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 190,
              height: 200,
              child: EpisodePicker(
                items: [item],
                currentKey: item.resumeKey,
                library: library,
                thumbnails: null,
                titleFor: (media) => media.name,
                onSelect: (_) => selected = true,
                onClose: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('one.mkv'));
    expect(selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'short viewport follows current item after it changes with large text',
    (tester) async {
      final library = FolderLibrary();
      addTearDown(library.dispose);
      final items = List.generate(
        50,
        (i) => LocalMedia(uri: Uri.file('/show_$i.mkv'), name: 'show_$i.mkv'),
      );
      var current = 35;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                height: 180,
                child: MediaQuery(
                  data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      update = setState;
                      return EpisodePicker(
                        items: items,
                        currentKey: items[current].resumeKey,
                        library: library,
                        thumbnails: null,
                        titleFor: (media) => media.name,
                        onSelect: (_) {},
                        onClose: () {},
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final card = find.byKey(ValueKey('episode-${items[35].resumeKey}'));
      expect(card, findsOneWidget);
      expect(tester.getRect(card).left, lessThan(320));
      update(() => current = 12);
      await tester.pump();
      await tester.pump();
      final next = find.byKey(ValueKey('episode-${items[12].resumeKey}'));
      expect(next, findsOneWidget);
      expect(tester.getRect(next).left, lessThan(320));
      expect(tester.takeException(), isNull);
    },
  );
}
