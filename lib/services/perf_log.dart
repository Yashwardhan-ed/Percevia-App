import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Debug-only performance instrumentation for the model-loading and
/// inference hot paths. Every call is a no-op in release builds, so it
/// can stay in the codebase as a permanent diagnostic.
class Perf {
  Perf._();

  static const MethodChannel _channel = MethodChannel('percevia/perf');

  /// Times an async [body], logging `[Perf] <tag>: <ms>ms`.
  static Future<T> time<T>(String tag, Future<T> Function() body) async {
    if (!kDebugMode) return body();
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      sw.stop();
      debugPrint('[Perf] $tag: ${sw.elapsedMilliseconds}ms');
    }
  }

  /// Logs a pre-measured duration (for hot paths that already time
  /// themselves, e.g. the recognition tick).
  static void mark(String tag, int millis) {
    if (kDebugMode) debugPrint('[Perf] $tag: ${millis}ms');
  }

  /// Samples process + system memory via the native bridge.
  static Future<void> mem(String tag) async {
    if (!kDebugMode) return;
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('memoryInfo');
      if (info != null) {
        debugPrint(
          '[Perf][mem] $tag: pss=${info['totalPssMb']}MB '
          'nativeHeap=${info['nativeHeapMb']}MB dalvik=${info['dalvikMb']}MB '
          'availSys=${info['availMb']}MB low=${info['lowMemory']}',
        );
      }
    } catch (e) {
      debugPrint('[Perf][mem] $tag failed: $e');
    }
  }
}
