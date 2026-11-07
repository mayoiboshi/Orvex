import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/design/back_navigation.dart';

class _StackFixture extends StatefulWidget {
  const _StackFixture({required this.name, this.nested = false});
  final String name;
  final bool nested;
  @override
  State<_StackFixture> createState() => _StackFixtureState();
}

class _StackFixtureState extends State<_StackFixture> {
  bool detail = false;
  @override
  Widget build(BuildContext context) => OrvexBackStack(
    pages: [
      orvexNavigationPage(
        context: context,
        key: ValueKey('${widget.name}-root'),
        child: Center(
          child: TextButton(
            onPressed: () => setState(() => detail = true),
            child: Text('open-${widget.name}'),
          ),
        ),
      ),
      if (detail)
        orvexNavigationPage(
          context: context,
          key: ValueKey('${widget.name}-detail'),
          child: widget.nested
              ? const _StackFixture(name: 'inner')
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('detail-${widget.name}'),
                      TextField(key: ValueKey('${widget.name}-editor')),
                    ],
                  ),
                ),
        ),
    ],
    onRemoved: (page) {
      if (page.key == ValueKey('${widget.name}-detail') && detail) {
        setState(() => detail = false);
      }
    },
  );
}

void main() {
  testWidgets(
    'desktop back shortcuts navigate but leave editable inputs alone',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: _StackFixture(name: 'outer')),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> shortcut() async {
        final mac =
            Theme.of(tester.element(find.byType(Scaffold))).platform ==
            TargetPlatform.macOS;
        final modifier = mac
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.altLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(
          mac ? LogicalKeyboardKey.bracketLeft : LogicalKeyboardKey.arrowLeft,
        );
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('open-outer'));
      await tester.pumpAndSettle();
      await shortcut();
      expect(find.text('open-outer'), findsOneWidget);
      await tester.tap(find.text('open-outer'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('outer-editor')),
        '正在输入',
      );
      await shortcut();
      expect(find.text('detail-outer'), findsOneWidget);
      expect(find.text('正在输入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

  testWidgets('one mouse back event pops only the deepest active stack', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: _StackFixture(name: 'outer', nested: true)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-outer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-inner'));
    await tester.pumpAndSettle();
    final pointer = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kBackMouseButton,
    );
    await pointer.down(const Offset(200, 200));
    await pointer.up();
    await tester.pumpAndSettle();
    expect(find.text('open-inner'), findsOneWidget);
    expect(find.text('open-outer'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
