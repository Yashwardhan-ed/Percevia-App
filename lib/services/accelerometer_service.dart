import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';

class AccelerometerService {
  final double _threshold = 0.5; // low threshold for steady hand
  final int _requiredStableCount = 15; // requires stability for a short duration

  Future<bool> waitForStability({Duration timeout = const Duration(seconds: 5)}) async {
    Completer<bool> completer = Completer<bool>();
    StreamSubscription<AccelerometerEvent>? subscription;
    Timer? timer;

    int stableCount = 0;
    double? lastMagnitude;

    void cleanup() {
      timer?.cancel();
      subscription?.cancel();
    }

    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        cleanup();
        completer.complete(false);
      }
    });

    try {
      subscription = accelerometerEventStream().listen(
        (AccelerometerEvent event) {
          double magnitude = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
          
          if (lastMagnitude != null) {
            double diff = (magnitude - lastMagnitude!).abs();
            if (diff < _threshold) {
              stableCount++;
              if (stableCount >= _requiredStableCount) {
                if (!completer.isCompleted) {
                  cleanup();
                  completer.complete(true);
                }
              }
            } else {
              stableCount = 0; // reset
            }
          }
          lastMagnitude = magnitude;
        },
        onError: (error) {
          if (!completer.isCompleted) {
            cleanup();
            completer.completeError(error);
          }
        },
        cancelOnError: true,
      );

      return await completer.future;
    } catch (e) {
      cleanup();
      rethrow;
    }
  }
}
