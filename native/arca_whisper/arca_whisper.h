// A small C interface over whisper.cpp for Arca's subtitle maker, so Dart
// binds a handful of plain functions instead of whisper's large structs.

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  ARCA_WHISPER_OK = 0,
  ARCA_WHISPER_ERR_MODEL = 1,
  ARCA_WHISPER_ERR_AUDIO = 2,
  ARCA_WHISPER_ERR_FAILED = 3,
  ARCA_WHISPER_CANCELLED = 4,
  ARCA_WHISPER_ERR_WRITE = 5,
};

// Transcribes a 16-bit PCM WAV file (16 kHz; stereo is mixed down) with the
// ggml model at [model] and writes the result as SubRip to [out_srt].
//
// [language] is a whisper language code or "auto" to detect it; the code
// used is written to [lang_out]. [progress] (0 to 100) and [cancel] are
// shared with the caller, which reads the first and may set the second to
// stop early. Blocks until done; call it from a worker thread or isolate.
int32_t arca_whisper_transcribe(const char* model, const char* wav,
                                const char* out_srt, const char* language,
                                int32_t threads, volatile int32_t* progress,
                                volatile int32_t* cancel, char* lang_out,
                                int32_t lang_out_len);

#ifdef __cplusplus
}
#endif
