import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/receiver/receiver_app.dart';
import 'src/sender/sender_app.dart';
import 'src/shared/preferences.dart';

/// One codebase, two apps:
///  * Android -> the **sender** (captures and streams the screen).
///  * macOS   -> the **receiver** (shows the stream).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferencesWithCache.create(cacheOptions: const SharedPreferencesWithCacheOptions());

  runApp(
    ProviderScope(
      overrides: [preferencesProvider.overrideWithValue(preferences)],
      child: Platform.isMacOS ? const ReceiverApp() : const SenderApp(),
    ),
  );
}
