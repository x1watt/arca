// Picture previews for videos: a still frame and a short animated GIF made
// of frames from across the clip, like a video site's hover preview. Made
// with ffmpeg, the copy shipped next to the app when there is one, else the
// system's; files are named by the video's SHA-256 so every collection
// holding the same clip shares them.

import 'dart:io';

class VideoPreviews {
  VideoPreviews(this.dir, {String? ffmpeg, String? ffprobe})
    : ffmpeg = ffmpeg ?? bundledTool('ffmpeg'),
      ffprobe = ffprobe ?? bundledTool('ffprobe');

  /// `<app dir>/bin/<name>` when the app ships it (the Linux bundle does),
  /// otherwise [name] for the system's PATH.
  static String bundledTool(String name) {
    final exe = File(Platform.resolvedExecutable).parent.path;
    final shipped = File('$exe/bin/$name');
    return shipped.existsSync() ? shipped.path : name;
  }

  /// Folder that holds `<sha256>.jpg` and `<sha256>.gif`.
  final String dir;
  final String ffmpeg;
  final String ffprobe;

  bool? _available;
  final _running = <String, Future<bool>>{};

  File still(String sha256) => File('$dir/$sha256.jpg');
  File animated(String sha256) => File('$dir/$sha256.gif');

  bool hasStill(String sha256) => still(sha256).existsSync();
  bool hasAnimated(String sha256) => animated(sha256).existsSync();

  /// Whether ffmpeg and ffprobe can be run on this system.
  Future<bool> available() async {
    if (_available != null) return _available!;
    try {
      final a = await Process.run(ffmpeg, ['-version']);
      final b = await Process.run(ffprobe, ['-version']);
      _available = a.exitCode == 0 && b.exitCode == 0;
    } on ProcessException {
      _available = false;
    }
    return _available!;
  }

  /// Makes both previews for the video at [path] unless they exist. Returns
  /// true when both exist afterwards. Concurrent calls for one video share
  /// the work.
  Future<bool> ensure(String path, String sha256) {
    if (hasStill(sha256) && hasAnimated(sha256)) return Future.value(true);
    return _running[sha256] ??= _make(path, sha256).whenComplete(() {
      // A block, not an arrow: returning the removed future would make this
      // future wait for itself.
      _running.remove(sha256);
    });
  }

  Future<bool> _make(String path, String sha256) async {
    if (!await available()) return false;
    await Directory(dir).create(recursive: true);
    final duration = await _duration(path);
    if (duration == null || duration <= 0) return false;

    // The still: a frame a tenth of the way in, past intros and black frames.
    final stillTmp = File('$dir/$sha256.tmp.jpg');
    final s = await Process.run(ffmpeg, [
      '-nostdin',
      '-v',
      'error',
      '-y',
      '-ss',
      (duration * 0.1).toStringAsFixed(2),
      '-i',
      path,
      '-frames:v',
      '1',
      '-vf',
      'scale=640:-2',
      '-q:v',
      '4',
      stillTmp.path,
    ]);
    if (s.exitCode != 0 || !await stillTmp.exists()) return false;
    await stillTmp.rename(still(sha256).path);

    // The animation: 10 frames spread across the clip, shown two per second.
    final frames = Directory('$dir/$sha256.frames');
    await frames.create(recursive: true);
    try {
      const count = 10;
      for (var i = 0; i < count; i++) {
        final t = duration * (i + 0.5) / count;
        await Process.run(ffmpeg, [
          '-nostdin',
          '-v',
          'error',
          '-y',
          '-ss',
          t.toStringAsFixed(2),
          '-i',
          path,
          '-frames:v',
          '1',
          '-vf',
          'scale=480:-2',
          '-q:v',
          '5',
          '${frames.path}/f${i.toString().padLeft(2, '0')}.jpg',
        ]);
      }
      final gifTmp = File('$dir/$sha256.tmp.gif');
      final g = await Process.run(ffmpeg, [
        '-nostdin',
        '-v',
        'error',
        '-y',
        '-framerate',
        '2',
        '-i',
        '${frames.path}/f%02d.jpg',
        '-vf',
        'split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer',
        '-loop',
        '0',
        gifTmp.path,
      ]);
      if (g.exitCode != 0 || !await gifTmp.exists()) return false;
      await gifTmp.rename(animated(sha256).path);
      return true;
    } finally {
      if (await frames.exists()) await frames.delete(recursive: true);
    }
  }

  Future<double?> _duration(String path) async {
    final r = await Process.run(ffprobe, [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=nokey=1:noprint_wrappers=1',
      path,
    ]);
    if (r.exitCode != 0) return null;
    return double.tryParse((r.stdout as String).trim());
  }
}
