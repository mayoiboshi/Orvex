import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'app/orvex_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  String? startupError;
  try {
    MediaKit.ensureInitialized();
  } catch (error) {
    startupError = '播放内核未能启动：$error';
  }
  runApp(ProviderScope(child: OrvexApp(startupError: startupError)));
}
