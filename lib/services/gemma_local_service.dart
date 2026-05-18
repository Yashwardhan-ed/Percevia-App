import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'perf_log.dart';

/// Thrown by [GemmaLocalService.downloadModel] when the user cancels an
/// in-flight download. The partial `.part` file is intentionally kept so the
/// next attempt resumes from where it stopped.
class ModelDownloadCancelled implements Exception {
  const ModelDownloadCancelled();
  @override
  String toString() => 'ModelDownloadCancelled';
}

/// Shared local Gemma runtime used by all on-device LLM features.
class GemmaLocalService {
  GemmaLocalService._();

  static final GemmaLocalService instance = GemmaLocalService._();

  // Filename of the Gemma .litertlm model expected on the device. The file is
  // staged into the app's external files dir via adb and then copied into the
  // app documents directory on first run. It is intentionally NOT bundled into
  // the Flutter asset bundle: at ~2.5 GB it exceeds Android APK packaging limits.
  static const String modelFileName = 'gemma-4-E2B-it.litertlm';

  // Public HuggingFace mirror of the model. The repo is public (no token
  // required) and the CDN honours HTTP Range requests, so downloads can be
  // resumed after an interruption.
  static const String modelDownloadUrl =
      'https://huggingface.co/Yash-ed/gemma-4-E2B-it.litertlm/resolve/main/'
      'gemma-4-E2B-it.litertlm?download=true';

  Future<void>? _initFuture;
  InferenceModel? _model;
  bool _downloadCancelRequested = false;

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

  /// The canonical on-device location the model is loaded from.
  Future<File> _docsModelFile() async {
    final docsRoot = await getApplicationDocumentsDirectory();
    return File(p.join(docsRoot.path, 'models', modelFileName));
  }

  /// Optional dev/side-load location (Android external app files dir). When a
  /// model is staged here it is copied into the documents dir on first use.
  Future<File?> _externalModelFile() async {
    if (!Platform.isAndroid) return null;
    final ext = await getExternalStorageDirectory();
    if (ext == null) return null;
    return File(p.join(ext.path, 'models', modelFileName));
  }

  /// Non-throwing presence check used to decide whether to offer the in-app
  /// download. If a side-loaded copy exists in the external dir it is promoted
  /// into the documents dir so subsequent loads are fast.
  Future<bool> isModelPresent() async {
    final docsFile = await _docsModelFile();
    if (await docsFile.exists() && await docsFile.length() > 0) return true;

    final externalFile = await _externalModelFile();
    if (externalFile != null &&
        await externalFile.exists() &&
        await externalFile.length() > 0) {
      await _copyModelToDocuments(source: externalFile, target: docsFile);
      return true;
    }
    return false;
  }

  /// Locates the on-device Gemma .litertlm file. Prefers the app documents dir
  /// and copies from the app external files dir if needed. Throws a
  /// [FileSystemException] if the model has not been downloaded yet.
  Future<String> _resolveModelFilePath() async {
    final docsFile = await _docsModelFile();
    if (await isModelPresent()) {
      debugPrint('[GemmaLocal] Loading model from ${docsFile.path}');
      return docsFile.path;
    }
    throw FileSystemException(
      'Gemma model not downloaded yet. Use the in-app download prompt.',
      docsFile.path,
    );
  }

  /// Requests cancellation of an in-flight [downloadModel]. The partial file
  /// is kept so the next call resumes.
  void cancelModelDownload() => _downloadCancelRequested = true;

  /// Streams the model from [modelDownloadUrl] into the documents dir.
  ///
  /// Downloads into a `.part` sidecar and atomically renames on completion, so
  /// an interrupted run never leaves a truncated file at the load path. If a
  /// `.part` already exists the download resumes via an HTTP Range request.
  /// [onProgress] reports `(received, total)` bytes; `total` is 0 if the
  /// server does not advertise a length. Throws [ModelDownloadCancelled] if
  /// [cancelModelDownload] is called mid-flight.
  Future<void> downloadModel({
    required void Function(int received, int total) onProgress,
  }) async {
    _downloadCancelRequested = false;

    final target = await _docsModelFile();
    if (await target.exists() && await target.length() > 0) return;
    await target.parent.create(recursive: true);
    final partFile = File('${target.path}.part');

    var existing =
        await partFile.exists() ? await partFile.length() : 0;

    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(modelDownloadUrl))
        ..followRedirects = true;
      if (existing > 0) request.headers['range'] = 'bytes=$existing-';

      final response = await client.send(request);

      if (existing > 0 && response.statusCode == 416) {
        // Requested range is past the end: the `.part` already holds the
        // whole file (a prior run finished downloading but died before the
        // rename). Promote it as-is.
        await response.stream.drain<void>();
        onProgress(existing, existing);
        await partFile.rename(target.path);
        debugPrint('[GemmaLocal] Resumed completed model to ${target.path}');
        return;
      }

      if (existing > 0 && response.statusCode == 200) {
        // Server (or a redirect hop) ignored the Range header and is sending
        // the whole file again — restart cleanly from byte 0.
        existing = 0;
      } else if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException(
          'Model download failed: HTTP ${response.statusCode}',
          uri: Uri.parse(modelDownloadUrl),
        );
      }

      final total = existing + (response.contentLength ?? 0);
      var received = existing;
      onProgress(received, total);

      final out = partFile.openWrite(
        mode: existing > 0 ? FileMode.append : FileMode.write,
      );
      sink = out;

      await for (final chunk in response.stream) {
        if (_downloadCancelRequested) {
          await out.flush();
          await out.close();
          sink = null;
          throw const ModelDownloadCancelled();
        }
        out.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }

      await out.flush();
      await out.close();
      sink = null;

      await partFile.rename(target.path);
      debugPrint('[GemmaLocal] Model downloaded to ${target.path}');
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      client.close();
    }
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
