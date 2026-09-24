import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/core_client.dart';
import '../models/kinds.dart';
import 'cards.dart';

/// Plays a video or audio file in place. Uses libmpv through media_kit:
/// bundled on Android, and the system's libmpv on Linux (package libmpv2).
/// Shows the preview with a play button until the user starts it, so no
/// player is created for files nobody plays.
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

  Future<void> _start() async {
    try {
      final player = Player();
      final controller = VideoController(player);
      player.stream.error.listen((e) {
        if (mounted) setState(() => _error = e);
      });
      await player.open(Media(Uri.file(widget.file.absolutePath).toString()));
      final subtitles = widget.file.subtitles;
      if (subtitles != null) {
        await player.setSubtitleTrack(
          SubtitleTrack.uri(
            Uri.file(subtitles).toString(),
            title: 'Speech recognition',
            language: widget.file.subtitleLanguage,
          ),
        );
      }
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _controller = controller;
      });
    } catch (e) {
      setState(
        () => _error = Platform.isLinux
            ? 'Could not start the player. The libmpv shipped with Arca is missing; reinstall Arca.'
            : 'Could not start the player: $e',
      );
    }
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
    if (controller != null) {
      return AspectRatio(
        aspectRatio: isAudio ? 16 / 5 : 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Video(controller: controller, controls: AdaptiveVideoControls),
        ),
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        FileThumbnail(widget.file, badge: false, animateOnHover: false),
        Material(
          color: Colors.black54,
          shape: const CircleBorder(),
          child: IconButton(
            iconSize: 56,
            color: Colors.white,
            tooltip: 'Play',
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: _start,
          ),
        ),
        if (_error != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.all(8),
              color: Colors.black87,
              child: Text(_error!, style: const TextStyle(color: Colors.white)),
            ),
          ),
      ],
    );
  }
}
