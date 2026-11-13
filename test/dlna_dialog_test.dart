import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orvex/features/player/presentation/dlna_dialog.dart';

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
}
