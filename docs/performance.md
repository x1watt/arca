# Performance

How Arca spends CPU, memory, disk and battery, what went wrong while building it, how to measure it, and the rules for adding work without paying for the same mistakes twice. It follows the shape of the XPRS `docs/performance.md`, whose lessons apply here too: this project runs the same kind of stack (a Nostr relay, an I2P node and heavy media work inside a Flutter app) on the same kind of phone.

Every number below was measured, with the method given next to it. Where a claim has no number, it says so.

Read this together with `docs/architecture.md`. When you add or change code, check your change against sections 3 and 6 before calling it done.

---

## 1. The architecture, in CPU terms

- **UI isolate.** Flutter only: widgets, gestures, the media_kit player surface. It receives the whole state as plain maps and never touches keys, sockets, databases or big files.
- **Core isolate** (`coreIsolateMain`, `core_service.dart`). Profiles, unlocked keys, the per-profile relays and event stores, the library, follows and suggestions, the subtitle queue, model downloads. Requests run concurrently (`unawaited(handle(...).then(send))`), so a slow network call does not hold up a click.
- **I2P isolate.** The `i2p-dart` worker, one per device, carrying every profile's destination.
- **Transcription worker.** One `Isolate.run` per file, spawned by the core: libmpv decodes the audio, then whisper.cpp recognises it. Both calls block their thread for seconds to minutes.
- **ffmpeg processes.** Video previews (a still and a hover GIF) run as child processes, not in Dart at all.
- **Native threads.** whisper.cpp starts its own compute threads (section 4.2); libmpv starts its decoder and output threads, for the player and for audio decoding.

Two things follow:

1. **A busy core isolate freezes nothing on screen but delays every answer.** The UI keeps drawing, yet a "Create collection" waits behind whatever the core is doing synchronously. Anything longer than a few milliseconds of synchronous work on the core belongs in a worker or a process.
2. **Native threads are invisible to Dart tools.** The transcription worker's isolate shows no Dart frames while whisper burns eight cores. Measure native work with process and thread CPU (section 5), not with the Dart profiler.

---

## 2. What the heavy work costs

**Speech recognition.** Measured with `time` around `tool/_one.dart` style runs (decode plus model load plus recognition), on this development machine (16 threads, 15 GB, x86-64 with AVX2) using 8 threads, and on the C61 test phone (8 cores, 3.8 GB) using 4 threads:

- Base (57 MB), 11 s clip, desktop: about 1 s.
- Base, first 60 s of a real YouTube video, desktop: 3.9 s without word alignment, 5.2 s with it (section 3.8).
- Large turbo (547 MB), 11 s clip, desktop: 18 s, so slower than real time on the CPU. A one-hour video is a job of more than an hour.
- Tiny (31 MB), 11 s clip, C61: about 10 s wall time from the tap to the file on disk.

This is why the model is chosen per device (small ones on phones, the large one only with 7 GB or more), why only one file is transcribed at a time, and why the thread count is capped (section 4.2).

**Model downloads.** Base took 5 s from the GitHub release on this line. Models go to `models/` and are never loaded on the UI isolate.

**Linux bundle.** libmpv, ffmpeg and ffprobe with their libraries add 261 MB to `lib/` (Ubuntu's ffmpeg links nearly every codec). `libarca_whisper.so` is 2.1 MB with whisper and ggml linked in.

**Memory, not measured yet.** Whisper holds the whole decoded audio as 32-bit floats (16,000 samples per second: 230 MB for an hour) plus the model. On a 3.8 GB phone a long file with anything above Tiny is a real risk; see section 7.

---

## 3. Fixed: what was actually wrong

### 3.1 A collection that vanished: `map[id] ??= await open()`

Creating a collection and adding a file returned "No collection 71c2..." one call later.

Cause: the core cached libraries as `_libraries[id] ??= await Library.open(...)`. At startup two tasks asked for the same library before either open had finished (the preview pass and the subtitle migration). Both saw an empty slot, both opened their own `Library`, and the second assignment replaced the first. The collection was created in the copy that was then thrown away; the next request read the other copy.

Fix: cache the future, not the value: `_libraries[id] ??= Library.open(...)`. The same pattern was fixed for the follow stores and the event stores.

> **Rule: never write `x ??= await something()` for a shared cache.** The await opens a gap in which a second caller does the same work and one result is silently lost. Store the `Future` and let every caller await the same one.

### 3.2 A test that waited for itself

The preview test hung forever. `ensure()` cleaned up its in-flight map with `.whenComplete(() => _running.remove(sha256))`. The arrow returned the removed future, the same future the callback was attached to, so `whenComplete` waited for itself. A block body (`{ _running.remove(sha256); }`) fixed it; a comment in `previews.dart` says why.

ffmpeg also read from stdin when started from a process without a terminal and could stall; every call now passes `-nostdin`.

### 3.3 Two minutes to say "offline"

Sending a suggestion to someone who was offline took about two minutes before failing: the default publish tried several times with long timeouts over I2P. It now makes two attempts with a 20 s timeout and says clearly that the owner did not answer.

> **Rule: every network call made because the user pressed a button has a budget the user would accept.** Retries are for background work.

### 3.4 An edit that did not replace the old one

Republishing a collection within the same second as the previous version kept the old version: Nostr replaceable events with equal `created_at` are decided by id, not by arrival. `_publishLocal` now makes each replacement strictly newer than the one it replaces.

### 3.5 libmpv quit before it started, but only on the phone

Automatic subtitles failed on Android with "The media library stopped unexpectedly" and worked on Linux. The decoder was created with `idle=no`; with an empty playlist mpv may shut down before the `loadfile` command arrives, and on the phone it did. With `idle=yes` it waits; the end of the file is detected from the `END_FILE` event. mpv's own error text is now part of the message, so the next failure explains itself.

> **Rule: a native library's timing differs per platform.** Anything that passes on the desktop and touches libmpv, whisper or the I2P worker is untested until it has run on a phone.

### 3.6 Reading the disk for every file on every update

The core rebuilds and pushes the whole state on every change: every download progress tick, every transcription percent. The first subtitle code read a small JSON file per file inside that builder, synchronously, on the core isolate. With a library of thousands of files and a progress update per second, that is thousands of file reads per second.

Fix: failures and sidecar folder listings are cached in memory (`SubtitleStore`, `Sidecars`). Writes by Arca drop the affected folder at once; files dropped in by other programs show up within 30 seconds.

> **Rule: code that runs while building the state must not touch the disk per item.** Cache it, invalidate on write, expire for outside changes.

### 3.7 whisper in a debug build

Flutter's debug build compiled whisper.cpp and ggml without optimisation; recognition was unusably slow. `native/arca_whisper/CMakeLists.txt` forces `-O2` for its own targets even in debug, and Gradle passes `CMAKE_BUILD_TYPE=Release` to the native build. `GGML_NATIVE` is off so the library does not use instructions of the build machine only (on x86-64 the baseline is AVX2, FMA and F16C: CPUs from 2013 on).

### 3.8 A feature silently switched off by another feature

Word timings looked fine but were not the aligned ones: whisper disables DTW alignment when flash attention is on and says so only in a log line, and our shim silences whisper's log. Found only by a test with a known answer: 8 s of tone followed by the JFK sample must put the first word at about 8.3 s. With flash attention off the first cue starts at 8.52 s; before, times were spread evenly over each segment and cues covered silence for up to six seconds. The cost is about 30% more CPU for recognition (section 2), paid for subtitles that match the speech.

> **Rule: when you silence a library's log, test the output against a known answer.** A quiet library can turn a feature off and still return plausible numbers.

### 3.9 Subtitles judged on the wrong sample

The first cue layout looked right on the 11 s JFK sample and was poor on a real video: single orphaned words ("update.", "handle") opening cues, lines of 80 characters. Short samples hide layout problems. Cue layout is now checked on the first minute of a real talk.

### 3.10 4K video drawn on the CPU

A 4K AV1 video stuttered. Decoding was not the problem: this machine decodes it at 4.9 times real time on the CPU and 7.7 times with the GPU (`ffmpeg -f null` over 30 s). media_kit had fallen back to software rendering because it looked for Flutter's EGL context on the platform thread, and current Flutter keeps it on the raster thread ("EGL display or context is invalid", then "S/W rendering" in its log). Every frame was drawn by mpv into memory on the GTK main thread and uploaded again by Flutter.

Fix: a patched copy of media_kit_video (`third_party/media_kit_video/ARCA.md`) sets up mpv's GL rendering on the raster thread. With it, mpv renders into a GPU texture shared with Flutter and uses hardware decoding (`nvdec-copy` on the NVIDIA card here). Two startup races had to be closed: the file must not open before the GPU output exists (mpv then drops the video track), and subtitles must be added only after the file has loaded (earlier, the command failed and could end playback).

> **Rule: read a native plugin's own log once on every platform.** The fallback printed one line and the app kept working, just slowly. `ARCA_MPV_LOG=1` prints mpv's log.

### 3.11 Zero-copy decoding, measured

After 3.10 the question was whether decoded frames still made a trip through memory. `native/tools/zero_copy_check.cc` answers it on the desktop without a window: it opens the GPU as an EGL device, creates a GLES context in Flutter's place and a second one for mpv exactly as the patched plugin does, renders a video into a texture shared through an EGLImage, reads the picture back in the "Flutter" context, and reports the decoder mpv chose, frames per second and CPU. Build and run:

```sh
g++ -O2 -std=c++17 -o zero_copy_check native/tools/zero_copy_check.cc $(pkg-config --cflags --libs epoxy mpv)
./zero_copy_check video.webm gles 15          # or: gl, and a fourth argument for --hwdec
```

On the RTX 3080 (driver 595), a 4K AV1 video at 30 fps, 15 s, picture checked every time:

- CPU decoding: 239% of one core.
- GPU decoding copied back through memory (`nvdec-copy`): 15%.
- GPU decoding handed straight to OpenGL (`nvdec`): 4 to 5%, with a GLES 3 context and with a desktop OpenGL context alike.

So the plugin's GLES 3 context already gets zero-copy decoding on NVIDIA; no desktop OpenGL context is needed. The "CUDA hwdec only works with OpenGL" message seen on Xvfb comes from Mesa's software GL there, not from the setup. The app now prints one line per video with the decoder in use (`video 3840x2160, decoding: nvdec`).

On Android the obvious zero-copy option measured worse. On the C61, a 1080p H.264 video in a release build, 20 s of playback, two runs each: media_kit's default (MediaCodec copying into mpv's GPU output, `mediacodec-copy`) 23 to 25% of one core; `vo=mediacodec_embed` with `hwdec=mediacodec` (MediaCodec drawing straight onto the surface) 37 to 39%. The default stays.

> **Rule: measure the "obviously faster" option before shipping it.** Zero-copy won by a factor of three on the desktop and lost on the phone.

### 3.12 Five seconds from tap to picture

Opening a video took about five seconds before anything moved. A trace from the tap (release build, Xvfb, 3 opens each) put it down to one line: the player page waited for the plugin's "GPU output ready" property before opening the file, polling it every 30 ms plus a frame for up to three seconds, and the property never read back as ready, so every open waited the full loop. Everything else together took about 250 ms: creating the player 5 ms, the GPU render context 120 ms on the first open, opening the file 40 ms, and on the RTX 3080 (`native/tools/zero_copy_check.cc`, now printing these timings) 120 to 190 ms from loadfile to the first frame whatever the decoder.

Fix (`app/lib/core/playback.dart`): one player for the whole session, created after the first screen is drawn, with a one-pixel view of it kept on screen at the app's root so its GPU output is set up at start, never on a tap. The file starts loading when its card is tapped, so loading overlaps the page transition, and the page keeps the still preview up until the picture moves, so there is no black box. Measured after: 510 to 530 ms from tap to moving picture on Xvfb with a 4K file on software GL; the steps before the file opens take 10 to 25 ms.

> **Rule: a wait with a timeout hides its own failure.** The loop "worked" by giving up after three seconds every time. Trace from the user's tap, not from the function you suspect.
>
> **Rule: create long-lived media objects once.** A player, its isolate and its GPU output cost the same whether one video is watched or fifty; pay once, at start, off the tap.

### 3.13 A crash that waited for a new caller

Alice's app died without a word during a two-instance test; the kernel log had it: a segfault on Flutter's raster thread in `libmedia_kit_video_plugin.so`, in `video_output_get_width`. That function reads an `mpv_node` that `mpv_get_property` fills in only when it succeeds, and reads it uninitialized when there is no video yet. Upstream it was rarely reached before a video existed; the lazy GPU setup (3.10) asks for the size on every frame request of the idle player, so garbage was read often enough to crash. Fixed in the patched plugin: the node is initialized and the result checked, and the size is only asked for once the GPU output exists.

> **Rule: a silent exit is a crash until the kernel log says otherwise.** `journalctl -k | grep segfault` names the library and the offset; `readelf -lW` and `nm` turn the offset into a function.

### 3.14 Packing: the price of a copy that is really yours

The whitepaper wants making a packed slice on demand to cost 1,000 to 10,000 times more than reading it from the packed copy, so a steward cannot claim a copy they do not keep. `tool/packing_bench.dart` on this desktop (16 threads, one chunk per thread, Argon2id from the `cryptography` package in plain Dart), with page-cache reads, the honest steward's best case:

- Argon2id 8 MB: 34 ms per chunk, 4.05 MB/s, 408x. Too cheap.
- Argon2id 32 MB: 146 ms per chunk, 1.40 MB/s, 1,355x. The testnet setting.
- Argon2id 64 MB: 264 ms per chunk, 0.86 MB/s, 3,050x. The mainnet setting; a 32 GB partition takes about 10 hours on one core, so packing must spread over cores and run in the background.

Not measured yet: the same on the C61 phone, and a native RandomX for comparison.

---

## 4. The heavy jobs and how they are run

### 4.1 One job at a time, on a worker, progress through shared memory

Transcription runs with `Isolate.run` per file. That contradicts the XPRS rule "never `Isolate.run` per item", and deliberately: the rule is about hot paths with many small items, where the spawn costs more than the work. A transcription is one item that lasts seconds to hours, so the spawn cost is noise, and a fresh isolate per job means a crash or a leak in native code does not outlive the job.

Progress and cancellation are two `Int32`s in native memory allocated by the core; their address goes to the worker, whisper writes progress into one and polls the other through its abort callback. No port messages per percent and no callbacks into Dart from native threads. The core reads the value once a second and pushes state only when it changed.

### 4.2 A thread budget

whisper uses half of the processors on a computer (between 2 and 8) and at most 4 on a phone (`transcribeThreads()`), so the machine stays usable and the phone does not heat up at once. One file at a time, whatever the queue length.

### 4.3 Files are streamed, never read whole

- `hashFile` reads files in chunks and feeds SHA-256 and SHA-1 at the same time.
- Model downloads stream to a `.part` file while hashing; an interrupted download continues from where it stopped (HTTP range), rehashing only the bytes already on disk, and is renamed into place only when size and SHA-256 match.
- Sidecar manifests are written to a temporary file and renamed, so a copy of the folder taken at any moment never holds half of one.

- Files between clients (`transport/blobs.dart`) are served one 24 KiB chunk at a time from the file on disk and written by offset into a `.part` file; eight chunks are in flight, and a `.part.have` bitmap lets a download continue after a break instead of starting over. Over the live I2P network, three instances on this machine copied 115 KB in 1.1 s, and a 22.9 MB video in 128 s (about 178 KB/s).
- Stores written from several places at once (`follows.json`, `synced.json`, `collections.json`) save one at a time: two writers sharing the temporary file made the second rename fail.

The one exception is whisper itself, which needs the whole decoded audio in memory (section 2 and 7).

---

## 5. Measurement discipline

1. **Measure wall time end to end** for anything the user waits for: tap to file on disk, not "recognition took N ms". Model load and audio decoding are part of the cost.
2. **Use a known answer.** For timing: a tone of known length before known speech. For text: the JFK sample. For layout: a real minute of speech, not a sample built to be easy (3.9).
3. **Measure on the phone.** The desktop has four times the memory and twice the cores; it hid 3.5 and it hides every memory problem. The C61 (3.8 GB, 8 cores) is the reference phone, as in XPRS.
4. **Read native CPU from the process, not the Dart profiler.** A worker inside whisper shows no Dart frames:
   ```sh
   adb shell "PID=\$(pidof org.arca.arca); for t in /proc/\$PID/task/*; do echo \$(cat \$t/comm) \$(awk '{print \$14+\$15}' \$t/stat); done"
   ```
   Take two readings some seconds apart in one device-side command; ticks are 100 per second.
5. **Release builds for CPU numbers.** On the phone the same playback measured 130 to 150% of a core in a debug build and 23 to 39% in a release build; debug numbers compare nothing.
6. **Never drive the visible desktop for tests.** GUI checks run on Xvfb (`:98`, `:99`) with their own `HOME` and `XDG_DATA_HOME`, then are stopped by PID after checking the process's `DISPLAY`. The user's desktop session is never used for automated input.
7. **Phone tests stay inside Arca.** The test phone may be someone's own phone: launch Arca with `am start -n org.arca.arca/.MainActivity`, delete anything pushed for a test afterwards, and do not screenshot outside the app.

---

## 6. Adding new work without regressing any of this

### 6.1 Decide where the work runs before writing it

- **Renders or reacts to a gesture:** UI isolate. Nothing else goes there.
- **State, keys, stores, network requests:** core isolate, as asynchronous code that never blocks for long.
- **Minutes of CPU in native code (recognition, decoding):** a worker isolate per job, progress through shared memory (4.1).
- **An external tool (ffmpeg):** a child process with `-nostdin` and explicit output paths.
- **Many small items on a hot path (signatures, packets):** one long-lived worker with a bounded queue, the XPRS pattern. Not `Isolate.run` per item.

### 6.2 Checklist for a new subsystem

- Shared cache? Cache the `Future` (3.1).
- Called while building the state? No disk access per item (3.6).
- A button that waits on the network? A budget in seconds, two attempts at most (3.3).
- Reads a file the user chose? Stream it; the biggest legitimate input is a film (4.3).
- Downloads something? Resumable into `.part`, verified by hash, renamed into place.
- Writes into a collection folder? Temporary file and rename; name it after the file it belongs to (`docs/architecture.md`, 9.4).
- Native library? Optimised in every build type, portable CPU flags, tested on the phone (3.5, 3.7).
- Silenced a library's log? Test the output against a known answer (3.8).
- Heavy and continuous? One job at a time with a thread budget, and think about the phone in someone's pocket (section 7).

### 6.3 Guard

XPRS enforces its rules with `tool/arch_guard.dart` on pre-commit. Arca has no guard yet. The first rules worth adding, because each shape reads as free at the call site:

- `??= await` on a field (3.1).
- `readAsBytes()` or `readAsBytesSync()` outside tests (4.3).
- `existsSync`, `readAsStringSync` or `listSync` inside `_state()` and anything it calls, unless behind a cache (3.6).
- `Isolate.run` inside a loop.

---

## 7. Open, roughly by value

1. **Transcription on a phone in the background.** Android throttles or kills a backgrounded app; a long transcription started on a phone can die with the process and start over. It needs a foreground service while a job runs (the XPRS `BackgroundService` stack), and probably a "only while charging" setting for automatic subtitles on phones.
2. **Memory for long files.** Whisper gets the whole decoded audio at once. Decoding and recognising in windows of a few minutes (keeping the timestamps continuous) would bound memory to the window, and let progress survive a restart.
3. **Voice activity detection.** whisper.cpp supports a small VAD model. Skipping music and silence would cut recognition time on talks with intros and stop annotations like "[Bell]" appearing over non-speech.
4. **Faster ARM builds.** The Android library uses baseline ARMv8 so it runs on every phone. ggml can build several CPU variants and pick one at run time (dot product and fp16 on most phones since 2018); worth measuring on the C61.
5. **Whole-state pushes.** Every change sends the whole state, all collections and files, to the UI. Fine at tens of files, not at tens of thousands. The fix is per-collection state or diffs.
6. **A smaller Linux bundle.** 261 MB is mostly Ubuntu's ffmpeg. A libmpv and ffmpeg built with the formats Arca plays would be a fraction of it.
7. **Previews on Android.** Stills and hover GIFs use the ffmpeg command line, which does not exist on Android. libmpv can take the screenshots.

---

## 8. Build and device traps (each of these cost real time)

- **Two heavy builds freeze this 16 GB machine.** Every `gradlew`, `flutter build` and `flutter run` goes through `~/bin/android-build-locked`, which serialises them machine-wide. Light commands (`flutter analyze`, `pub get`, `dart test`) do not need it.
- **The Gradle daemon died** building whisper for Android: an 8 GB heap plus a compile job per core for ggml ran out of memory. `gradle.properties` now gives the daemon 4 GB, and the native build uses a Ninja job pool of 4 compiles.
- **RUNPATH applies only to direct dependencies.** Setting `$ORIGIN/lib` on the executable does not make a bundled library find its own dependencies; each copied library gets `$ORIGIN` itself (`bundle_media.sh`). The media_kit plugin's RUNPATH pointed into the build tree and had to be rewritten too.
- **Never bundle what GTK already loaded.** Copying the whole dependency closure of libmpv included a second glib, pango and friends. Everything already loaded by `libflutter_linux_gtk.so` stays with the system.
- **media_kit loads libmpv by name**, which finds a system copy first. `linux/runner/main.cc` sets `LIBMPV_LIBRARY_PATH` to the bundled one before Flutter starts.
- **libmpv refuses to start under a locale with a decimal comma** (`LC_NUMERIC`); `decodeAudio` resets it to `C` and retries.
- **The GitHub CLI is a snap** and cannot read files under `/tmp`. Stage release assets under the repository's ignored `build/` folder.
- **`adb shell run-as <pkg> sh -c 'rm dir/*'`** does not expand the glob the way it looks; list the names first and remove them one by one.
- **The Android file picker only shows media the scanner knows.** After `adb push`, send `MEDIA_SCANNER_SCAN_FILE` for the file, or open it through Downloads.
- **A stale icon subset.** A release build showed blank icons for icons added since the last build: Flutter reused the trimmed MaterialIcons font from its build cache, without the new glyphs. `rm -rf app/.dart_tool/flutter_build` and building again fixed it. When a new icon shows as nothing in a release build, check the font (`fc-query --format='%{charset}'` on `data/flutter_assets/fonts/MaterialIcons-Regular.otf`) before the code.
- **`uiautomator dump` sees Flutter's semantics tree**, which is how tests find a button's position on the phone instead of guessing coordinates.
