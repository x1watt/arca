#include "arca_whisper.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "whisper.h"

namespace {

void quiet_log(enum ggml_log_level, const char*, void*) {}

uint32_t le32(const unsigned char* p) {
  return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}

uint16_t le16(const unsigned char* p) { return p[0] | (p[1] << 8); }

// Reads a PCM16 WAV into mono float samples; false if it is not one.
bool read_wav(const char* path, std::vector<float>& out) {
  FILE* f = std::fopen(path, "rb");
  if (!f) return false;
  std::vector<unsigned char> buf;
  unsigned char chunk[1 << 16];
  size_t n;
  while ((n = std::fread(chunk, 1, sizeof(chunk), f)) > 0) {
    buf.insert(buf.end(), chunk, chunk + n);
  }
  std::fclose(f);
  if (buf.size() < 12 || std::memcmp(buf.data(), "RIFF", 4) != 0 ||
      std::memcmp(buf.data() + 8, "WAVE", 4) != 0) {
    return false;
  }
  int channels = 0, bits = 0;
  size_t pos = 12;
  while (pos + 8 <= buf.size()) {
    const unsigned char* h = buf.data() + pos;
    uint32_t size = le32(h + 4);
    size_t body = pos + 8;
    if (std::memcmp(h, "fmt ", 4) == 0 && body + 16 <= buf.size()) {
      // PCM, plainly or as WAVE_FORMAT_EXTENSIBLE with the PCM subformat.
      uint16_t format = le16(buf.data() + body);
      if (format == 0xFFFE && size >= 40 && body + 26 <= buf.size()) {
        format = le16(buf.data() + body + 24);
      }
      if (format != 1) return false;
      channels = le16(buf.data() + body + 2);
      if (le32(buf.data() + body + 4) != WHISPER_SAMPLE_RATE) return false;
      bits = le16(buf.data() + body + 14);
    } else if (std::memcmp(h, "data", 4) == 0) {
      if (channels < 1 || bits != 16) return false;
      // Streamed writers leave the size unset; take what is there.
      size_t end = size == 0 || size == 0xFFFFFFFF || body + size > buf.size()
                       ? buf.size()
                       : body + size;
      size_t frames = (end - body) / (2 * channels);
      out.resize(frames);
      const unsigned char* d = buf.data() + body;
      for (size_t i = 0; i < frames; i++) {
        float sum = 0;
        for (int c = 0; c < channels; c++) {
          sum += (int16_t)le16(d + 2 * (i * channels + c)) / 32768.0f;
        }
        out[i] = sum / channels;
      }
      return true;
    }
    pos = body + size + (size & 1);
  }
  return false;
}

std::string srt_time(int64_t centis) {
  int64_t ms = centis * 10;
  char s[32];
  std::snprintf(s, sizeof(s), "%02d:%02d:%02d,%03d", (int)(ms / 3600000),
                (int)(ms / 60000 % 60), (int)(ms / 1000 % 60), (int)(ms % 1000));
  return s;
}

std::string trim(const char* t) {
  std::string s(t);
  size_t a = s.find_first_not_of(" \t\n");
  size_t b = s.find_last_not_of(" \t\n");
  return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}

}  // namespace

extern "C" __attribute__((visibility("default"))) int32_t arca_whisper_transcribe(const char* model, const char* wav,
                                           const char* out_srt,
                                           const char* language,
                                           int32_t threads,
                                           volatile int32_t* progress,
                                           volatile int32_t* cancel,
                                           char* lang_out,
                                           int32_t lang_out_len) {
  whisper_log_set(quiet_log, nullptr);
  std::vector<float> pcm;
  if (!read_wav(wav, pcm)) return ARCA_WHISPER_ERR_AUDIO;

  whisper_context_params cparams = whisper_context_default_params();
  cparams.use_gpu = false;
  whisper_context* ctx = whisper_init_from_file_with_params(model, cparams);
  if (!ctx) return ARCA_WHISPER_ERR_MODEL;

  whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  p.n_threads = threads > 0 ? threads : 4;
  p.language = language && *language ? language : "auto";
  p.translate = false;
  p.print_progress = false;
  p.print_realtime = false;
  p.print_timestamps = false;
  p.print_special = false;
  p.progress_callback = [](whisper_context*, whisper_state*, int value,
                           void* data) {
    if (data) *static_cast<volatile int32_t*>(data) = value;
  };
  p.progress_callback_user_data = (void*)progress;
  p.abort_callback = [](void* data) {
    return data != nullptr && *static_cast<volatile int32_t*>(data) != 0;
  };
  p.abort_callback_user_data = (void*)cancel;

  int rc = whisper_full(ctx, p, pcm.data(), (int)pcm.size());
  if (cancel && *cancel) {
    whisper_free(ctx);
    return ARCA_WHISPER_CANCELLED;
  }
  if (rc != 0) {
    whisper_free(ctx);
    return ARCA_WHISPER_ERR_FAILED;
  }

  if (lang_out && lang_out_len > 0) {
    const char* code = whisper_lang_str(whisper_full_lang_id(ctx));
    std::snprintf(lang_out, lang_out_len, "%s", code ? code : "");
  }

  std::string srt;
  int shown = 0;
  for (int i = 0; i < whisper_full_n_segments(ctx); i++) {
    std::string text = trim(whisper_full_get_segment_text(ctx, i));
    if (text.empty()) continue;
    srt += std::to_string(++shown) + "\n" +
           srt_time(whisper_full_get_segment_t0(ctx, i)) + " --> " +
           srt_time(whisper_full_get_segment_t1(ctx, i)) + "\n" + text +
           "\n\n";
  }
  whisper_free(ctx);

  FILE* f = std::fopen(out_srt, "wb");
  if (!f) return ARCA_WHISPER_ERR_WRITE;
  bool ok = std::fwrite(srt.data(), 1, srt.size(), f) == srt.size();
  ok = std::fclose(f) == 0 && ok;
  if (progress) *progress = 100;
  return ok ? ARCA_WHISPER_OK : ARCA_WHISPER_ERR_WRITE;
}
