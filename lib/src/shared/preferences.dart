import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local key-value storage for small settings. Loaded once in `main()` and
/// injected with `overrideWithValue`, so reads are synchronous everywhere.
final preferencesProvider = Provider<SharedPreferencesWithCache>(
  (ref) => throw UnimplementedError('preferencesProvider must be overridden in main()'),
);
