// Subtitles for videos and audio, made on the device with whisper.cpp
// (docs/architecture.md, 8.3). The speech models are not shipped with the
// app: the user downloads one, sized for the device, from Arca's releases.
// The audio track is decoded to 16 kHz WAV through libmpv, which the app
// already carries for playback, so this works where there is no ffmpeg
// (Android). Subtitles are stored by the file's SHA-256 like previews.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as c;
import 'package:ffi/ffi.dart';

/// Where the models are downloaded from: release assets of Arca's
/// repository, copied there unchanged from ggerganov/whisper.cpp on
/// Hugging Face. Each download is checked against [WhisperModel.sha256].
const modelReleaseUrl = 'https://github.com/x1watt/arca/releases/download/models-v1';

class WhisperModel {
  const WhisperModel(this.id, this.file, this.bytes, this.sha256, this.label, this.detail);
  final String id;
  final String file;
  final int bytes;
  final String sha256;
  final String label;
  final String detail;

  String get url => '$modelReleaseUrl/$file';
}

/// Smallest first. Quantized whisper models: the quality loss is small and
/// they need a third of the memory.
const whisperModels = [
  WhisperModel(
    'tiny',
    'ggml-tiny-q5_1.bin',
    32152673,
    '818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7',
    'Tiny',
    'Fastest, for older phones. Rough on names and noisy audio.',
  ),
  WhisperModel(
    'base',
    'ggml-base-q5_1.bin',
    59707625,
    '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898',
    'Base',
    'Good for phones. Clear speech comes out well.',
  ),
  WhisperModel(
    'small',
    'ggml-small-q5_1.bin',
    190085487,
    'ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb',
    'Small',
    'Better accuracy; for recent phones and older computers.',
  ),
  WhisperModel(
    'turbo',
    'ggml-large-v3-turbo-q5_0.bin',
    574041195,
    '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2',
    'Large (turbo)',
    'Best quality, many languages. For computers with 8 GB of memory or more.',
  ),
];

WhisperModel? modelById(String? id) => whisperModels.where((m) => m.id == id).firstOrNull;

bool get isMobile => Platform.isAndroid || Platform.isIOS;

/// Total memory in bytes, from /proc/meminfo where there is one.
int? totalMemory() {
  try {
    final line = File('/proc/meminfo').readAsLinesSync().firstWhere((l) => l.startsWith('MemTotal:'));
    return int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!) * 1024;
  } catch (_) {
    return null;
  }
}

/// The model that fits the device: small models on phones, the large one
/// on computers with the memory for it.
String recommendedModel({bool? mobile, int? memory}) {
  mobile ??= isMobile;
  memory ??= totalMemory() ?? 0;
  const gb = 1024 * 1024 * 1024;
  if (mobile) return memory >= 6 * gb ? 'base' : 'tiny';
  return memory >= 7 * gb ? 'turbo' : 'small';
}

/// Threads for transcription: leave room for the rest of the system.
int transcribeThreads() {
  final n = Platform.numberOfProcessors;
  return isMobile ? n.clamp(1, 4) : (n ~/ 2).clamp(2, 8);
}

/// Downloads and keeps the models in [dir].
class ModelStore {
  ModelStore(this.dir, {HttpClient? client}) : _client = client ?? HttpClient();
  final String dir;
  final HttpClient _client;

  File file(WhisperModel m) => File('$dir/${m.file}');
  File _part(WhisperModel m) => File('$dir/${m.file}.part');

  bool installed(WhisperModel m) => file(m).existsSync();

  /// Bytes already fetched of an interrupted download.
  int partial(WhisperModel m) => _part(m).existsSync() ? _part(m).lengthSync() : 0;

  /// Fetches [m], continuing an interrupted download, and checks its hash.
  /// [onProgress] gets the bytes received so far. Returns null or a message.
  Future<String?> download(
    WhisperModel m, {
    void Function(int)? onProgress,
    bool Function()? cancelled,
    String? url,
  }) async {
    await Directory(dir).create(recursive: true);
    final part = _part(m);
    var have = await part.exists() ? await part.length() : 0;
    if (have > m.bytes) {
      await part.delete();
      have = 0;
    }
    try {
      final req = await _client.getUrl(Uri.parse(url ?? m.url));
      if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      final res = await req.close();
      if (res.statusCode == 200) {
        have = 0; // the server sent the whole file
      } else if (res.statusCode != 206) {
        await res.drain<void>();
        return 'The download failed (HTTP ${res.statusCode}).';
      }
      final digest = _Digest();
      final hash = c.sha256.startChunkedConversion(digest);
      if (have > 0) {
        await for (final chunk in part.openRead()) {
          hash.add(chunk);
        }
      }
      final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var got = have;
      var lastReport = 0;
      try {
        await for (final chunk in res) {
          if (cancelled?.call() ?? false) return 'Download stopped.';
          sink.add(chunk);
          hash.add(chunk);
          got += chunk.length;
          if (got - lastReport >= 1 << 20) {
            lastReport = got;
            onProgress?.call(got);
          }
        }
      } finally {
        await sink.close();
      }
      hash.close();
      if (got != m.bytes || digest.value.toString() != m.sha256) {
        await part.delete();
        return 'The downloaded model did not match its checksum; try again.';
      }
      await part.rename(file(m).path);
      onProgress?.call(got);
      return null;
    } on SocketException catch (e) {
      return 'No connection to the download server (${e.message}).';
    } on HttpException catch (e) {
      return 'The download was interrupted (${e.message}); it continues where it stopped.';
    }
  }

  Future<void> delete(WhisperModel m) async {
    for (final f in [file(m), _part(m)]) {
      if (await f.exists()) await f.delete();
    }
  }
}

class _Digest implements Sink<c.Digest> {
  late c.Digest value;
  @override
  void add(c.Digest data) => value = data;
  @override
  void close() {}
}

/// Subtitles made for each file, by SHA-256: `<sha>.srt` and `<sha>.json`
/// (language, model, time), or `<sha>.failed` when a file cannot be done.
class SubtitleStore {
  SubtitleStore(this.dir);
  final String dir;

  File srt(String sha256) => File('$dir/$sha256.srt');
  File _meta(String sha256) => File('$dir/$sha256.json');
  File _failed(String sha256) => File('$dir/$sha256.failed');

  bool has(String sha256) => srt(sha256).existsSync();
  bool failed(String sha256) => _failed(sha256).existsSync();

  Map<String, Object?> meta(String sha256) {
    try {
      return (jsonDecode(_meta(sha256).readAsStringSync()) as Map).cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }

  String? failure(String sha256) => failed(sha256) ? _failed(sha256).readAsStringSync() : null;

  Future<void> markFailed(String sha256, String why) async {
    await Directory(dir).create(recursive: true);
    await _failed(sha256).writeAsString(why);
  }

  Future<void> clearFailure(String sha256) async {
    if (await _failed(sha256).exists()) await _failed(sha256).delete();
  }

  Future<void> saveMeta(String sha256, Map<String, Object?> m) => _meta(sha256).writeAsString(jsonEncode(m));
}

/// Finds the native libraries: next to the app (Linux bundle `lib/`), in
/// the APK (Android, by name), or where an environment variable says.
abstract final class NativeLibs {
  static String get _appLib => '${File(Platform.resolvedExecutable).parent.path}/lib';

  static List<String> get whisper => [
    ?Platform.environment['ARCA_WHISPER_LIB'],
    if (Platform.isAndroid) 'libarca_whisper.so' else '$_appLib/libarca_whisper.so',
  ];

  static List<String> get mpv => [
    ?Platform.environment['LIBMPV_LIBRARY_PATH'],
    if (Platform.isAndroid) 'libmpv.so' else ...['$_appLib/libmpv.so.2', 'libmpv.so.2', 'libmpv.so'],
  ];

  static DynamicLibrary? open(List<String> candidates) {
    for (final p in candidates) {
      try {
        return DynamicLibrary.open(p);
      } on ArgumentError {
        continue;
      }
    }
    return null;
  }
}

class TranscribeResult {
  const TranscribeResult({this.language, this.error, this.cancelled = false});
  final String? language;
  final String? error;
  final bool cancelled;
}

/// One transcription at a time, on a worker isolate: decoding and whisper
/// both block their thread for minutes.
class Transcriber {
  Transcriber(this.store);
  final SubtitleStore store;

  bool? _available;

  /// Whether the whisper library and libmpv can be loaded here.
  bool available() =>
      _available ??= NativeLibs.open(NativeLibs.whisper) != null && NativeLibs.open(NativeLibs.mpv) != null;

  // [progress, cancel], shared with the worker by address.
  Pointer<Int32>? _shared;

  /// Progress of the running job: -1 while the audio is being decoded,
  /// then 0 to 100.
  int get progress => _shared == null ? 0 : _shared![0];

  void cancel() {
    final s = _shared;
    if (s != null) s[1] = 1;
  }

  Future<TranscribeResult> run(String input, String sha256, String modelPath, {String language = 'auto'}) async {
    if (!available()) return const TranscribeResult(error: 'Speech recognition is not available in this build.');
    await Directory(store.dir).create(recursive: true);
    final shared = calloc<Int32>(2);
    shared[0] = -1;
    _shared = shared;
    final wav = '${store.dir}/$sha256.tmp.wav';
    final out = '${store.dir}/$sha256.tmp.srt';
    final addr = shared.address;
    final threads = transcribeThreads();
    try {
      final (code, lang, detail) = await Isolate.run(
        () => _transcribeInWorker(input, wav, out, modelPath, language, threads, addr),
      );
      switch (code) {
        case 0:
          await File(out).rename(store.srt(sha256).path);
          return TranscribeResult(language: lang);
        case 4:
          return const TranscribeResult(cancelled: true);
        default:
          return TranscribeResult(error: detail);
      }
    } finally {
      _shared = null;
      calloc.free(shared);
      for (final p in [wav, out]) {
        final f = File(p);
        if (await f.exists()) await f.delete();
      }
    }
  }
}

typedef _TranscribeC =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Int32,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Utf8>,
      Int32,
    );
typedef _TranscribeDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Utf8>,
      int,
    );

/// Runs on the worker isolate. Returns (code, language, message).
(int, String?, String) _transcribeInWorker(
  String input,
  String wav,
  String out,
  String model,
  String language,
  int threads,
  int sharedAddr,
) {
  final shared = Pointer<Int32>.fromAddress(sharedAddr);
  final decodeError = decodeAudio(input, wav, cancelled: () => shared[1] != 0);
  if (shared[1] != 0) return (4, null, 'Cancelled.');
  if (decodeError != null) return (2, null, decodeError);
  shared[0] = 0;

  final lib = NativeLibs.open(NativeLibs.whisper)!;
  final transcribe = lib.lookupFunction<_TranscribeC, _TranscribeDart>('arca_whisper_transcribe');
  return using((arena) {
    final lang = arena<Uint8>(16).cast<Utf8>();
    final code = transcribe(
      model.toNativeUtf8(allocator: arena),
      wav.toNativeUtf8(allocator: arena),
      out.toNativeUtf8(allocator: arena),
      language.toNativeUtf8(allocator: arena),
      threads,
      shared,
      shared + 1,
      lang,
      16,
    );
    final message = switch (code) {
      0 => '',
      1 => 'The speech model could not be loaded; download it again.',
      2 => 'The audio could not be read.',
      4 => 'Cancelled.',
      5 => 'The subtitles could not be written.',
      _ => 'Speech recognition failed.',
    };
    return (code, code == 0 ? lang.toDartString() : null, message);
  });
}

// libmpv, just enough to decode an audio track to a WAV file.

final class _MpvEvent extends Struct {
  @Int32()
  external int eventId;
  @Int32()
  external int error;
  @Uint64()
  external int replyUserdata;
  external Pointer<Void> data;
}

final class _MpvEndFile extends Struct {
  @Int32()
  external int reason;
  @Int32()
  external int error;
}

/// Decodes the first audio track of [input] to 16 kHz mono 16-bit WAV at
/// [wav] with libmpv. Blocking: call it on a worker isolate. Returns null
/// or a message.
String? decodeAudio(String input, String wav, {bool Function()? cancelled}) {
  final lib = NativeLibs.open(NativeLibs.mpv);
  if (lib == null) return 'The media library (libmpv) is missing.';
  final create = lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('mpv_create');
  final setOption = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
      >('mpv_set_option_string');
  final initialize = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('mpv_initialize');
  final command = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>),
        int Function(Pointer<Void>, Pointer<Pointer<Utf8>>)
      >('mpv_command');
  final waitEvent = lib
      .lookupFunction<
        Pointer<_MpvEvent> Function(Pointer<Void>, Double),
        Pointer<_MpvEvent> Function(Pointer<Void>, double)
      >('mpv_wait_event');
  final destroy = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'mpv_terminate_destroy',
  );

  var mpv = create();
  if (mpv == nullptr) {
    // libmpv refuses to start under a locale that writes numbers with a
    // decimal comma.
    _cNumericLocale();
    mpv = create();
    if (mpv == nullptr) return 'The media library (libmpv) could not start.';
  }
  return using((arena) {
    Pointer<Utf8> s(String v) => v.toNativeUtf8(allocator: arena);
    const options = {
      'config': 'no',
      'terminal': 'no',
      'idle': 'no',
      'load-scripts': 'no',
      'ytdl': 'no',
      'vid': 'no',
      'sid': 'no',
      'audio-display': 'no',
      'ao': 'pcm',
      'ao-pcm-waveheader': 'yes',
      'audio-samplerate': '16000',
      'audio-channels': 'mono',
      'audio-format': 's16',
    };
    try {
      for (final e in {...options, 'ao-pcm-file': wav}.entries) {
        setOption(mpv, s(e.key), s(e.value));
      }
      if (initialize(mpv) < 0) return 'The media library (libmpv) could not start.';
      final args = arena<Pointer<Utf8>>(3);
      args[0] = s('loadfile');
      args[1] = s(input);
      args[2] = nullptr;
      if (command(mpv, args) < 0) return 'The file could not be opened.';
      var hadAudio = false;
      while (true) {
        final e = waitEvent(mpv, 0.5).ref;
        if (cancelled?.call() ?? false) return 'Cancelled.';
        switch (e.eventId) {
          case 8: // file loaded
            hadAudio = true;
          case 7: // end of file
            final reason = e.data.cast<_MpvEndFile>().ref.reason;
            if (reason == 4 || !hadAudio) return 'The file could not be decoded.';
            final f = File(wav);
            if (!f.existsSync() || f.lengthSync() <= 44) return 'The file has no sound to transcribe.';
            return null;
          case 1: // shutdown
            return 'The media library stopped unexpectedly.';
        }
      }
    } finally {
      destroy(mpv);
    }
  });
}

void _cNumericLocale() {
  try {
    final setlocale = DynamicLibrary.process()
        .lookupFunction<Pointer<Utf8> Function(Int32, Pointer<Utf8>), Pointer<Utf8> Function(int, Pointer<Utf8>)>(
          'setlocale',
        );
    using((a) => setlocale(1 /* LC_NUMERIC on glibc and bionic */, 'C'.toNativeUtf8(allocator: a)));
  } catch (_) {}
}
