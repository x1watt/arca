// Needs the native libraries: libmpv from the system and libarca_whisper.so
// from ARCA_WHISPER_LIB, plus a model at ARCA_WHISPER_MODEL. Skipped
// otherwise; the model catalog tests always run.
import 'dart:io';

import 'package:arca_core/src/library/subtitles.dart';
import 'package:test/test.dart';

void main() {
  test('recommends small models on phones and the large one on big desktops', () {
    const gb = 1024 * 1024 * 1024;
    expect(recommendedModel(mobile: true, memory: 4 * gb), 'tiny');
    expect(recommendedModel(mobile: true, memory: 8 * gb), 'base');
    expect(recommendedModel(mobile: false, memory: 4 * gb), 'small');
    expect(recommendedModel(mobile: false, memory: 16 * gb), 'turbo');
    for (final m in whisperModels) {
      expect(m.sha256, hasLength(64));
      expect(m.url, startsWith('https://github.com/x1watt/arca/releases/download/'));
    }
  });

  test('download resumes and rejects a wrong checksum', () async {
    final tmp = await Directory.systemTemp.createTemp('arca_models');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final body = List<int>.generate(3 << 20, (i) => i % 251);
    server.listen((r) async {
      final range = r.headers.value(HttpHeaders.rangeHeader);
      final from = range == null ? 0 : int.parse(range.substring(6, range.length - 1));
      r.response.statusCode = range == null ? 200 : 206;
      r.response.add(body.sublist(from));
      await r.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/m.bin';
    const fake = WhisperModel('t', 'm.bin', 3 << 20, 'badbad', 'T', '');
    final store = ModelStore(tmp.path);
    expect(await store.download(fake, url: url), contains('checksum'));
    expect(store.installed(fake), isFalse);
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  final lib = Platform.environment['ARCA_WHISPER_LIB'];
  final model = Platform.environment['ARCA_WHISPER_MODEL'];
  final sample = Platform.environment['ARCA_WHISPER_SAMPLE'];
  test(
    'transcribes a clip',
    () async {
      final tmp = await Directory.systemTemp.createTemp('arca_subs');
      final t = Transcriber(SubtitleStore(tmp.path));
      expect(t.available(), isTrue);
      final r = await t.run(sample!, 'abc', model!, language: 'auto');
      expect(r.error, isNull);
      expect(r.language, 'en');
      final srt = await t.store.srt('abc').readAsString();
      expect(srt, contains('-->'));
      expect(srt.toLowerCase(), contains('country'));
      await tmp.delete(recursive: true);
    },
    skip: lib == null || model == null || sample == null ? 'native libraries not given' : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
