import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/core_client.dart';
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

/// Plays a video or audio file in place, starting as soon as the page
/// opens. Uses libmpv through media_kit (bundled on Android and in the
/// Linux bundle). The preview stays up until the first frame is ready.
class MediaPlayer extends StatefulWidget {
  const MediaPlayer({super.key, required this.file});
  final FileView file;

  @override
  State<MediaPlayer> createState() => _MediaPlayerState();
}

class _MediaPlayerState extends State<MediaPlayer> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  String? _loadedSubtitles;
  bool _fileLoaded = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      // ARCA_MPV_LOG=1 prints libmpv's log, for diagnosing playback.
      final log = Platform.environment['ARCA_MPV_LOG'] == '1';
      final player = Player(
        configuration: PlayerConfiguration(
          logLevel: log ? MPVLogLevel.v : MPVLogLevel.error,
        ),
      );
      if (log) {
        player.stream.log.listen(
          (l) => stderr.writeln('mpv ${l.prefix}: ${l.text}'),
        );
      }
      final controller = VideoController(player);
      // Put the video surface on screen before opening the file: on Linux
      // its GPU setup runs on the first frame Flutter draws of it, and mpv
      // needs that output when it starts the video.
      setState(() {
        _player = player;
        _controller = controller;
      });
      if (player.platform case final NativePlayer native
          when Platform.isLinux) {
        // The plugin says when its GPU output is ready; give up waiting
        // after three seconds and let it attach late.
        for (var i = 0; i < 100 && mounted; i++) {
          await WidgetsBinding.instance.endOfFrame;
          if (await native.getProperty('user-data/arca/gl-ready') == 'yes') {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
      if (!mounted) {
        await player.dispose();
        return;
      }
      // Subtitles are chosen here (_loadSubtitles); without this mpv also
      // loads the ones beside the file and lists them twice.
      if (player.platform case final NativePlayer native) {
        await native.setProperty('sub-auto', 'no');
        // At the end, stay on the last frame instead of going black.
        await native.setProperty('keep-open', 'yes');
      }
      await player.open(Media(Uri.file(widget.file.absolutePath).toString()));
      // Subtitles can only be added once the file is loaded.
      await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 10), onTimeout: () => Duration.zero);
      if (!mounted) return;
      _fileLoaded = true;
      await _loadSubtitles();
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = Platform.isLinux
            ? 'Could not start the player. The libmpv shipped with Arca is missing; reinstall Arca.'
            : 'Could not start the player: $e',
      );
    }
  }

  /// Shows the file's subtitles, also when they are made while it plays.
  Future<void> _loadSubtitles() async {
    final player = _player, path = widget.file.subtitles;
    if (player == null || !_fileLoaded) return;
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
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final isAudio = kindForMime(widget.file.mime) == FileKind.audio;
    if (controller != null && _error == null) {
      return AspectRatio(
        aspectRatio: isAudio ? 16 / 5 : 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          // A click on the picture plays or pauses, as on video sites; a
          // double click still goes fullscreen.
          child: MaterialDesktopVideoControlsTheme(
            normal: _desktopControls,
            fullscreen: _desktopControls,
            child: Video(
              controller: controller,
              controls: AdaptiveVideoControls,
              subtitleViewConfiguration: subtitleLook,
            ),
          ),
        ),
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        FileThumbnail(widget.file, badge: false, animateOnHover: false),
        if (_error == null)
          const CircularProgressIndicator()
        else
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.black87,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  TextButton(onPressed: _start, child: const Text('Try again')),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
