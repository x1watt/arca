# Arca

A shared library of files that anyone can browse, keep copies of and add to, like a Wikipedia for files. It runs over Nostr and I2P only; every client is also a relay. The design is in `arca-whitepaper.md` and the implementation plan in `docs/architecture.md`.

## Layout

- `app/`: the Flutter app (Linux and Android).
- `packages/arca_core/`: the core in pure Dart (keys, events, relay, profiles, library, subtitles). It runs on its own isolate.
- `native/arca_whisper/`: a small C interface over whisper.cpp, used for subtitles.
- `third_party/whisper.cpp`: git submodule.

## Building

    git clone --recursive https://github.com/x1watt/arca
    cd arca/app
    flutter build linux

`packages/arca_core` depends on [i2p-dart](https://github.com/x1watt/i2p-dart) checked out next to this repository (`../i2p-dart`).

To build on Linux you need `cmake`, `patchelf`, `libmpv2` and `ffmpeg` (on Ubuntu: `sudo apt install cmake patchelf libmpv-dev ffmpeg`). The Linux bundle carries libmpv, ffmpeg and their libraries (`app/linux/packaging/bundle_media.sh`), so it runs without them installed.

To add Arca to the desktop's application list (menu, dock and window icon), run `app/linux/packaging/install_desktop.sh` after building; `--remove` takes it out again. Icons for both platforms are generated from `app/assets/icon/*.svg` by `app/tool/make_icons.sh`.

## Speech models

Subtitles are made on the device with whisper.cpp. The models are not part of the app. From Settings, under Subtitles, the app downloads the model that suits the device from this repository's [models-v1 release](https://github.com/x1watt/arca/releases/tag/models-v1) and checks its SHA-256. These are unchanged copies of the quantized models from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) on Hugging Face (MIT license):

- `ggml-tiny-q5_1.bin` (31 MB): older phones
- `ggml-base-q5_1.bin` (57 MB): phones
- `ggml-small-q5_1.bin` (181 MB): recent phones, older computers
- `ggml-large-v3-turbo-q5_0.bin` (547 MB): computers with 8 GB of memory or more
