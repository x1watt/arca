import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/kinds.dart';
import 'core_client.dart';

/// The app's one media player (docs/performance.md, 3.12).
///
/// Creating a player costs an mpv instance, an isolate for its events and,
/// on Linux, the GPU output with its hardware decoding set up. Paying that
/// on every open made videos start seconds after the tap. It is paid once,
/// shortly after the app starts ([warmUp]), and every file page reuses it.
/// A file starts loading when its card is tapped ([prepare]), so loading
/// overlaps the page transition.
class Playback {
  Playback._();
  static final instance = Playback._();

  /// Set once the player exists; the pages and the root surface
  /// ([PlaybackSurface]) show it.
  final controller = ValueNotifier<VideoController?>(null);

  /// The file loaded now, by absolute path.
  final current = ValueNotifier<String?>(null);

  /// Whether the current file's picture is on screen yet; until then pages
  /// keep the still preview up instead of a black box.
  final showing = ValueNotifier<bool>(false);

  /// Why the player could not start, if it could not.
  final error = ValueNotifier<String?>(null);

  Player? _player;
  Future<void>? _ready;
  bool _opened = false;

  Player? get player => _player;

  static bool plays(FileView f) => switch (kindForMime(f.mime)) {
    FileKind.video || FileKind.audio => true,
    _ => false,
  };

  Future<void> warmUp() => _ready ??= _create();

  Future<void> _create() async {
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
      if (player.platform case final NativePlayer native) {
        // Subtitles are chosen by the page; without this mpv also loads the
        // ones beside the file and lists them twice.
        await native.setProperty('sub-auto', 'no');
        // At the end, stay on the last frame instead of going black.
        await native.setProperty('keep-open', 'yes');
      }
      player.stream.position.listen((p) {
        if (_opened && !showing.value && p > Duration.zero) {
          showing.value = true;
        }
      });
      _player = player;
      // media_kit's defaults: on Android, MediaCodec with a copy into mpv's
      // GPU output measured cheaper than drawing straight onto the surface
      // (docs/performance.md, 3.11).
      controller.value = VideoController(player);
    } catch (e) {
      error.value = Platform.isLinux
          ? 'Could not start the player. The libmpv shipped with Arca is missing; reinstall Arca.'
          : 'Could not start the player: $e';
    }
  }

  /// Starts loading and playing [file]; nothing to do when it is already
  /// the current file.
  Future<void> prepare(FileView file) async {
    final path = file.absolutePath;
    if (current.value == path) return;
    current.value = path;
    showing.value = false;
    _opened = false;
    await warmUp();
    final player = _player;
    if (player == null || current.value != path) return;
    await player.open(Media(Uri.file(path).toString()));
    if (current.value == path) _opened = true;
  }

  /// Stops [file] when its page closes, unless another file took over.
  Future<void> release(FileView file) async {
    if (current.value != file.absolutePath) return;
    current.value = null;
    showing.value = false;
    _opened = false;
    await _player?.stop();
  }
}

/// A view of the player kept on screen for the whole session, one pixel
/// in a corner of the app (main.dart).
/// On Linux the GPU output is set up the first time Flutter draws the
/// player's texture; drawing it here does that at start instead of on the
/// first tap, and keeps the texture live between pages.
class PlaybackSurface extends StatelessWidget {
  const PlaybackSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Playback.instance.controller,
      builder: (context, controller, _) => controller == null
          ? const SizedBox.shrink()
          : ExcludeSemantics(
              child: IgnorePointer(
                child: Video(
                  controller: controller,
                  controls: NoVideoControls,
                  subtitleViewConfiguration: const SubtitleViewConfiguration(
                    visible: false,
                  ),
                ),
              ),
            ),
    );
  }
}
