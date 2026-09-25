# media_kit_video 2.0.1, patched for Arca

A copy of [media_kit_video](https://pub.dev/packages/media_kit_video) 2.0.1 (MIT, see LICENSE), used through `dependency_overrides` in `app/pubspec.yaml`. The `example/` folder was left out. Only the Linux rendering path is changed; drop this copy once upstream renders on the GPU with current Flutter.

## The problem

With Flutter 3.47 on Linux, Flutter draws with its own EGL context on the raster thread, while the platform thread holds GDK's GLX context. media_kit created mpv's render context on the platform thread by copying the current EGL context, found none ("EGL display or context is invalid"), and fell back to software rendering: mpv drew every frame into a memory buffer on the GTK main thread, which Flutter then uploaded again. A 4K video stuttered.

## The changes

- `linux/video_output.cc`: the EGL context and the mpv render context are created in `video_output_ensure_gl`, on the raster thread, the first time Flutter asks the texture for a frame. The context uses Flutter's EGL config (GLES 3 when available, else 2) so the frame can be shared through an EGLImage, as before. Until then the texture is marked available every 30 ms so Flutter asks. Arca keeps one player for the whole session with a one-pixel view of it on screen from the start (`app/lib/core/playback.dart`), so this setup is done before any file is opened. If a file is opened earlier anyway, the video track is selected again once the output exists (mpv drops it when there is no output).
- `linux/texture_gl.cc`: calls `video_output_ensure_gl` first and shows the 1x1 placeholder until it succeeds.
- `lib/src/video/video_texture.dart`: the 1x1 placeholder texture is mounted before the video size is known. Otherwise the texture never reached the screen, Flutter never asked for its first frame, and mpv never learned the video size: each waited for the other.
