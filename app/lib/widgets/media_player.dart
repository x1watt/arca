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

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      final player = Player();
      final controller = VideoController(player);
      player.stream.error.listen((e) {
        if (mounted) setState(() => _error = e);
      });
      await player.open(Media(Uri.file(widget.file.absolutePath).toString()));
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _controller = controller;
      });
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
    if (player == null || path == null || path == _loadedSubtitles) return;
    _loadedSubtitles = path;
    await player.setSubtitleTrack(
      SubtitleTrack.uri(
        Uri.file(path).toString(),
        title: 'Subtitles',
        language: widget.file.subtitleLanguage,
      ),
    );
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
          child: Video(
            controller: controller,
            controls: AdaptiveVideoControls,
            subtitleViewConfiguration: subtitleLook,
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
