import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/core_client.dart';
import '../core/playback.dart';
import '../models/kinds.dart';
import 'cards.dart';

/// Subtitles the way films and TV show them: white semi-bold text with a
/// thin black outline and a soft shadow, no box behind it, centered near the
/// bottom. media_kit scales the text with the player (1.0 at 1920x1080,
/// 16:9), so 52 comes out at about 5% of the picture height at any size,
/// fullscreen included.
const subtitleLook = SubtitleViewConfiguration(
  style: TextStyle(
    fontSize: 52,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: Colors.white,
    shadows: [
      // Four hard offsets make the outline, the blurred one the shadow.
      Shadow(offset: Offset(-1.5, -1.5)),
      Shadow(offset: Offset(1.5, -1.5)),
      Shadow(offset: Offset(-1.5, 1.5)),
      Shadow(offset: Offset(1.5, 1.5)),
      Shadow(offset: Offset(0, 2), blurRadius: 6, color: Color(0xCC000000)),
    ],
  ),
  padding: EdgeInsets.fromLTRB(48, 0, 48, 36),
);

const _desktopControls = MaterialDesktopVideoControlsThemeData(
  playAndPauseOnTap: true,
);

/// Plays a video or audio file in place, on the app's shared player
/// (core/playback.dart), which started loading it when its card was
/// tapped. The still preview stays up until the first frame is on screen,
/// so there is never a black box. When another page takes the player, this
/// one shows its still with a play button.
class MediaPlayer extends StatefulWidget {
  const MediaPlayer({super.key, required this.file});
  final FileView file;

  @override
  State<MediaPlayer> createState() => _MediaPlayerState();
}

class _MediaPlayerState extends State<MediaPlayer> {
  final _playback = Playback.instance;
  StreamSubscription<Duration>? _duration;
  String? _loadedSubtitles;

  String get _path => widget.file.absolutePath;
  bool get _mine => _playback.current.value == _path;

  @override
  void initState() {
    super.initState();
    _play();
  }

  Future<void> _play() async {
    _loadedSubtitles = null;
    await _playback.prepare(widget.file);
    final player = _playback.player;
    if (!mounted || player == null) return;
    // Subtitles can only be added once the file is loaded.
    await _duration?.cancel();
    _duration = player.stream.duration.listen((d) {
      if (d > Duration.zero && _mine) _fileLoaded();
    });
    if (player.state.duration > Duration.zero && _mine) _fileLoaded();
  }

  bool _logged = false;

  Future<void> _fileLoaded() async {
    final player = _playback.player;
    if (player == null) return;
    if (!_logged) {
      _logged = true;
      unawaited(_logDecoder(player));
    }
    await _loadSubtitles();
  }

  /// One line per video, once its picture is up, to tell GPU decoding
  /// (nvdec, vaapi, mediacodec) from CPU decoding ("no") in the app's output.
  Future<void> _logDecoder(Player player) async {
    for (var i = 0; i < 100 && mounted && !_playback.showing.value; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted || !_mine || player.platform is! NativePlayer) return;
    final native = player.platform as NativePlayer;
    final decoder = await native.getProperty('hwdec-current');
    final w = await native.getProperty('width');
    final h = await native.getProperty('height');
    debugPrint('video ${w}x$h, decoding: ${decoder.isEmpty ? 'no' : decoder}');
  }

  /// Shows the file's subtitles, also when they are made while it plays.
  Future<void> _loadSubtitles() async {
    final player = _playback.player, path = widget.file.subtitles;
    if (player == null || !_mine || player.state.duration <= Duration.zero) {
      return;
    }
    if (path == null || path == _loadedSubtitles) return;
    _loadedSubtitles = path;
    // A subtitle file that cannot be read leaves the video playing.
    try {
      await player.setSubtitleTrack(
        SubtitleTrack.uri(
          path,
          title: 'Subtitles',
          language: widget.file.subtitleLanguage,
        ),
      );
    } catch (_) {}
  }

  @override
  void didUpdateWidget(MediaPlayer old) {
    super.didUpdateWidget(old);
    _loadSubtitles();
  }

  @override
  void dispose() {
    _duration?.cancel();
    _playback.release(widget.file);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAudio = kindForMime(widget.file.mime) == FileKind.audio;
    return ListenableBuilder(
      listenable: Listenable.merge([
        _playback.controller,
        _playback.current,
        _playback.showing,
        _playback.error,
      ]),
      builder: (context, _) {
        final controller = _playback.controller.value;
        final error = _playback.error.value;
        final mine = _mine;
        final waiting = !mine || !_playback.showing.value;
        return AspectRatio(
          aspectRatio: isAudio ? 16 / 5 : 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (controller != null && mine)
                  // A click on the picture plays or pauses, as on video
                  // sites; a double click still goes fullscreen.
                  MaterialDesktopVideoControlsTheme(
                    normal: _desktopControls,
                    fullscreen: _desktopControls,
                    child: Video(
                      controller: controller,
                      controls: AdaptiveVideoControls,
                      subtitleViewConfiguration: subtitleLook,
                    ),
                  ),
                // The still until the picture is there; it fades out.
                IgnorePointer(
                  ignoring: !waiting,
                  child: AnimatedOpacity(
                    opacity: waiting ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Stack(
                      alignment: Alignment.center,
                      fit: StackFit.expand,
                      children: [
                        FileThumbnail(
                          widget.file,
                          badge: false,
                          animateOnHover: false,
                        ),
                        if (error != null)
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: 12,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              color: Colors.black87,
                              child: Text(
                                error,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          )
                        else if (!mine)
                          Center(
                            child: Material(
                              color: Colors.black54,
                              shape: const CircleBorder(),
                              child: IconButton(
                                iconSize: 56,
                                color: Colors.white,
                                tooltip: 'Play',
                                icon: const Icon(Icons.play_arrow_rounded),
                                onPressed: _play,
                              ),
                            ),
                          )
                        else
                          const Center(
                            child: SizedBox(
                              width: 32,
                              height: 32,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
