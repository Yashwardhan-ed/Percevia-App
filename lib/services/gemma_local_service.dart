import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'perf_log.dart';

/// Shared local Gemma runtime used by all on-device LLM features.
class GemmaLocalService {
  GemmaLocalService._();

  static final GemmaLocalService instance = GemmaLocalService._();

  // Filename of the Gemma .litertlm model expected on the device. The file is
  // staged into the app's external files dir via adb and then copied into the
  // app documents directory on first run. It is intentionally NOT bundled into
  // the Flutter asset bundle: at ~2.5 GB it exceeds Android APK packaging limits.
  static const String modelFileName = 'gemma-4-E2B-it.litertlm';

  Future<void>? _initFuture;
  InferenceModel? _model;

  // Serializes every generation against the single native model. The
  // LiteRT-LM engine crashes hard (SIGSEGV in ThreadPool::RunWorker) if a
  // second session touches the model while another is still active — e.g.
  // tapping Describe again before the previous run finished. Each
  // generation holds this lock for its entire lifetime: createSession …
  // session.close(). A queued request cannot create its session until the
  // previous session has fully closed (native teardown complete).
  Future<void> _modelLock = Future<void>.value();

  Future<void Function()> _acquireModelLock() {
    final release = Completer<void>();
    final previous = _modelLock;
    _modelLock = release.future;
    return previous.then((_) => () {
          if (!release.isCompleted) release.complete();
        });
  }

  Future<void> initialize() async {
    if (_model != null) return;
    if (_initFuture != null) {
      await _initFuture;
      return;
    }

    _initFuture = _initializeInternal();
    try {
      await _initFuture;
    } catch (_) {
      _initFuture = null;
      rethrow;
    }
  }

  Future<void> _initializeInternal() async {
    await FlutterGemma.initialize();

    final modelPath = await _resolveModelFilePath();

    await Perf.time('Gemma install', () async {
      await FlutterGemma.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(modelPath).install();
    });

    _model = await Perf.time(
      'Gemma getActiveModel',
      () => FlutterGemma.getActiveModel(
        maxTokens: 3072,
        preferredBackend: PreferredBackend.gpu,
        supportImage: true,
        maxNumImages: 1,
      ),
    );
  }

  /// Locates the on-device Gemma .litertlm file. Prefers the app documents dir
  /// and copies from the app external files dir if needed.
  /// Throws a [FileSystemException] with the expected push command if missing.
  Future<String> _resolveModelFilePath() async {
    final docsRoot = await getApplicationDocumentsDirectory();
    final docsDir = Directory(p.join(docsRoot.path, 'models'));
    final docsFile = File(p.join(docsDir.path, modelFileName));

    if (await docsFile.exists()) {
      debugPrint('[GemmaLocal] Loading model from ${docsFile.path}');
      return docsFile.path;
    }

    Directory? externalDir;
    File? externalFile;
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        externalDir = Directory(p.join(ext.path, 'models'));
        externalFile = File(p.join(externalDir.path, modelFileName));
      }
    }

    if (externalFile != null && await externalFile.exists()) {
      await _copyModelToDocuments(source: externalFile, target: docsFile);
      debugPrint('[GemmaLocal] Loading model from ${docsFile.path}');
      return docsFile.path;
    }

    final searched = <String>[docsFile.path];
    if (externalFile != null) searched.add(externalFile.path);
    final searchedText = searched.join('\n  ');

    final instructions = StringBuffer('Gemma model not found on device.\n')
      ..writeln('Searched:')
      ..writeln('  $searchedText')
      ..writeln();

    if (Platform.isAndroid) {
      final externalPath = externalDir?.path ??
          '/sdcard/Android/data/<package>/files/models';
      instructions
        ..writeln('Dev helper:')
        ..writeln('  scripts/push_gemma_model.sh')
        ..writeln()
        ..writeln('Manual adb:')
        ..writeln('  adb shell mkdir -p $externalPath')
        ..write('  adb push models_local/$modelFileName '
            '$externalPath/$modelFileName');
    } else if (Platform.isIOS) {
      instructions
        ..writeln('Push the file into the app sandbox via Finder:')
        ..writeln('  1. Connect the device, open Finder, select the device')
        ..writeln('  2. Click the "Files" tab and find Percevia')
        ..writeln('  3. Drag models_local/$modelFileName into Percevia/models/')
        ..writeln('     (UIFileSharingEnabled must be true in Info.plist)')
        ..writeln()
        ..write('Or use the Files app on the device under '
            'On My iPhone > Percevia > models/.');
    } else {
      instructions.write('Place $modelFileName in:\n  ${docsFile.path}');
    }

    throw FileSystemException(instructions.toString());
  }

  Future<void> _copyModelToDocuments({
    required File source,
    required File target,
  }) async {
    await target.parent.create(recursive: true);
    debugPrint('[GemmaLocal] Copying model from ${source.path} to ${target.path}');
    await source.copy(target.path);
  }

  Future<String?> generateTextResponse({
    required String prompt,
    double temperature = 0.2,
    int topK = 40,
    double topP = 0.9,
    int maxTokens = 3072,
  }) async {
    return _runSession(
      message: Message.text(text: prompt, isUser: true),
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxTokens: maxTokens,
      supportImage: false,
    );
  }

  Future<String?> generateImageResponse({
    required List<int> imageBytes,
    required String prompt,
    double temperature = 0.2,
    int topK = 40,
    double topP = 0.9,
    int maxTokens = 3072,
  }) async {
    return _runSession(
      message: Message.withImage(
        text: prompt,
        imageBytes: Uint8List.fromList(imageBytes),
        isUser: true,
      ),
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxTokens: maxTokens,
      supportImage: true,
    );
  }

  Future<String?> _runSession({
    required Message message,
    required double temperature,
    required int topK,
    required double topP,
    required int maxTokens,
    required bool supportImage,
  }) async {
    await initialize();
    final model = _model;
    if (model == null) return null;

    final release = await _acquireModelLock();
    InferenceModelSession? session;
    try {
      session = await model.createSession(
        temperature: temperature,
        randomSeed: 1,
        topK: topK,
        topP: topP,
        enableVisionModality: supportImage,
      );

      await session.addQueryChunk(message);
      final response = await Perf.time(
        'Gemma generate (image=$supportImage)',
        () => session!.getResponse(),
      );
      final cleaned = _cleanResponse(response);
      return cleaned.isEmpty ? null : cleaned;
    } catch (e) {
      debugPrint('[GemmaLocal] Inference failed: $e');
      return null;
    } finally {
      if (session != null) {
        try {
          await session.close();
        } catch (e) {
          debugPrint('[GemmaLocal] Session close failed: $e');
        }
      }
      release();
    }
  }

  /// Streaming variant of [generateTextResponse] that yields token deltas as
  /// they arrive from the model. The stream completes when the model emits
  /// its end-of-sequence token (or on error, after which the stream closes).
  Stream<String> generateTextResponseStream({
    required String prompt,
    double temperature = 0.2,
    int topK = 40,
    double topP = 0.9,
    int maxTokens = 3072,
  }) {
    return _runSessionStream(
      message: Message.text(text: prompt, isUser: true),
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxTokens: maxTokens,
      supportImage: false,
    );
  }

  /// Streaming variant of [generateImageResponse]. See [generateTextResponseStream].
  Stream<String> generateImageResponseStream({
    required List<int> imageBytes,
    required String prompt,
    double temperature = 0.2,
    int topK = 40,
    double topP = 0.9,
    int maxTokens = 3072,
  }) {
    return _runSessionStream(
      message: Message.withImage(
        text: prompt,
        imageBytes: Uint8List.fromList(imageBytes),
        isUser: true,
      ),
      temperature: temperature,
      topK: topK,
      topP: topP,
      maxTokens: maxTokens,
      supportImage: true,
    );
  }

  Stream<String> _runSessionStream({
    required Message message,
    required double temperature,
    required int topK,
    required double topP,
    required int maxTokens,
    required bool supportImage,
  }) async* {
    await initialize();
    final model = _model;
    if (model == null) return;

    // Hold the model lock for the whole stream lifetime. If the caller
    // cancels the subscription (e.g. user re-taps Describe), Dart runs
    // this finally — closing the session and releasing the lock — before
    // the next queued generation is allowed to create its session.
    final release = await _acquireModelLock();
    InferenceModelSession? session;
    try {
      session = await model.createSession(
        temperature: temperature,
        randomSeed: 1,
        topK: topK,
        topP: topP,
        enableVisionModality: supportImage,
      );

      await session.addQueryChunk(message);
      yield* session.getResponseAsync();
    } catch (e) {
      debugPrint('[GemmaLocal] Streaming inference failed: $e');
    } finally {
      if (session != null) {
        try {
          await session.close();
        } catch (e) {
          debugPrint('[GemmaLocal] Session close failed: $e');
        }
      }
      release();
    }
  }

  String _cleanResponse(String response) {
    var out = response.trim();
    if (out.startsWith('```')) {
      out = out.replaceFirst(RegExp(r'^```[a-zA-Z0-9_-]*\n?'), '');
      out = out.replaceAll(RegExp(r'```$'), '').trim();
    }
    return out;
  }

  Future<void> dispose() async {
    final model = _model;
    _model = null;
    _initFuture = null;
    if (model != null) {
      await model.close();
    }
  }
}
