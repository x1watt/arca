import 'dart:io';

import 'package:arca_core/src/library/library.dart';
import 'package:arca_core/src/library/previews.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_prev'));
  tearDown(() async => tmp.delete(recursive: true));

  test('makes a still and an animated GIF for a video', () async {
    final previews = VideoPreviews('${tmp.path}/previews');
    if (!await previews.available()) {
      markTestSkipped('ffmpeg is not installed');
      return;
    }
    final video = File('${tmp.path}/clip.webm');
    final r = await Process.run('ffmpeg', [
      '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=duration=6:size=320x180:rate=10', '-c:v', 'libvpx', video.path,
    ]);
    expect(r.exitCode, 0);
    expect(await detectMime(video), 'video/webm');
    final (sha, _, _) = await hashFile(video);
    expect(await previews.ensure(video.path, sha), isTrue);
    final still = previews.still(sha), gif = previews.animated(sha);
    expect(still.readAsBytesSync().take(3), [0xFF, 0xD8, 0xFF]);
    expect(String.fromCharCodes(gif.readAsBytesSync().take(6)), 'GIF89a');
    // A second call reuses the files.
    final before = gif.lastModifiedSync();
    expect(await previews.ensure(video.path, sha), isTrue);
    expect(gif.lastModifiedSync(), before);
  });

  test('reports failure for something that is not a video', () async {
    final previews = VideoPreviews('${tmp.path}/previews');
    if (!await previews.available()) {
      markTestSkipped('ffmpeg is not installed');
      return;
    }
    final junk = File('${tmp.path}/junk.mkv')..writeAsStringSync('not a video');
    expect(await previews.ensure(junk.path, 'ab' * 32), isFalse);
  });
}
