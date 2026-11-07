import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/design/orvex_theme.dart';
import 'package:orvex/features/player/presentation/watch_information.dart';

void main() {
  testWidgets(
    'watch information keeps every action usable on small screens and large text',
    (tester) async {
      var previous = 0, next = 0, metadata = 0;
      var automatic = false;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final width in [360.0, 800.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        for (final brightness in Brightness.values) {
          for (final scale in [1.0, 2.5]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: OrvexTheme.create(brightness),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 900),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Scaffold(
                    body: SingleChildScrollView(
                      child: WatchInformation(
                        title: '名侦探柯南 Detective Conan · 很长的作品标题与季度信息',
                        episode: '第 626 集',
                        progress: '11:18 / 24:12',
                        linked: false,
                        onMetadata: () => metadata++,
                        onPrevious: () => previous++,
                        onNext: () => next++,
                        autoNext: automatic,
                        onAutoNext: (value) => automatic = value,
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            for (final action in [
              find.byTooltip('上一集'),
              find.byTooltip('下一集'),
              find.byKey(const ValueKey('watch-metadata')),
              find.byKey(const ValueKey('watch-auto-next')),
            ]) {
              await tester.ensureVisible(action);
              await tester.pumpAndSettle();
              await tester.tap(action);
              await tester.pumpAndSettle();
            }
            expect(tester.takeException(), isNull);
          }
        }
      }
      expect(previous, 8);
      expect(next, 8);
      expect(metadata, 8);
      expect(automatic, isFalse);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
