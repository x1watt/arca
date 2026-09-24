#include "arca_whisper.h"

#include <cstdio>
#include <algorithm>
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

// Subtitle conventions (broadcast and streaming style guides): at most two
// lines of about 42 characters, on screen long enough to read, never for
// more than about seven seconds, and a new cue at the end of a sentence.
constexpr int kMaxLine = 42;
constexpr int64_t kMaxCue = 700;   // centiseconds
constexpr int64_t kMinCue = 100;
constexpr int64_t kMaxGap = 80;

struct Cue {
  int64_t t0, t1;
  std::vector<std::string> lines;
};

struct Word {
  std::string text;
  int64_t t0, t1;
};

std::string trim(const char* t);

// Words with their times, from whisper's tokens: a token that starts with
// a space starts a word, the others continue it. Special tokens are skipped.
std::vector<Word> collect_words(whisper_context* ctx) {
  std::vector<Word> words;
  const whisper_token eot = whisper_token_eot(ctx);
  for (int i = 0; i < whisper_full_n_segments(ctx); i++) {
    bool first = true;
    for (int j = 0; j < whisper_full_n_tokens(ctx, i); j++) {
      if (whisper_full_get_token_id(ctx, i, j) >= eot) continue;
      std::string t = whisper_full_get_token_text(ctx, i, j);
      whisper_token_data d = whisper_full_get_token_data(ctx, i, j);
      if (t.empty()) continue;
      if (d.t_dtw >= 0) {
        d.t0 = d.t_dtw;
        d.t1 = d.t_dtw;
      }
      bool starts = first || t[0] == ' ' || words.empty();
      first = false;
      if (starts) {
        std::string w = trim(t.c_str());
        if (w.empty()) continue;
        words.push_back({w, d.t0, d.t1});
      } else {
        words.back().text += t;
        words.back().t1 = std::max(words.back().t1, d.t1);
      }
    }
  }
  // Token times can step backwards a little; keep them in order.
  for (size_t i = 1; i < words.size(); i++) {
    words[i].t0 = std::max(words[i].t0, words[i - 1].t0);
    words[i].t1 = std::max(words[i].t1, words[i].t0);
  }
  return words;
}

whisper_alignment_heads_preset aheads_for(const char* model) {
  std::string m(model);
  auto has = [&](const char* s) { return m.find(s) != std::string::npos; };
  if (has("large-v3-turbo")) return WHISPER_AHEADS_LARGE_V3_TURBO;
  if (has("large-v3")) return WHISPER_AHEADS_LARGE_V3;
  if (has("medium")) return WHISPER_AHEADS_MEDIUM;
  if (has("small")) return WHISPER_AHEADS_SMALL;
  if (has("base")) return WHISPER_AHEADS_BASE;
  if (has("tiny")) return WHISPER_AHEADS_TINY;
  return WHISPER_AHEADS_NONE;
}

bool ends_clause(const std::string& s) {
  return !s.empty() && (s.back() == ',' || s.back() == '-');
}

bool ends_sentence(const std::string& s);

// Splits a cue's words into one line, or two lines of similar length,
// preferring to break after punctuation and never leaving a line longer
// than it has to be.
std::vector<std::string> balance(const std::vector<Word>& ws) {
  std::string all;
  for (auto& w : ws) all += (all.empty() ? "" : " ") + w.text;
  if ((int)all.size() <= kMaxLine || ws.size() < 2) return {all};
  int best = 0;
  double best_score = 1e9;
  size_t left = 0;
  for (size_t i = 0; i + 1 < ws.size(); i++) {
    left += ws[i].text.size() + (i ? 1 : 0);
    size_t right = all.size() - left - 1;
    double longest = (double)std::max(left, right);
    double score = std::abs((double)left - (double)right);
    if (longest > kMaxLine) score += 1000 + longest;  // only if nothing fits
    if (ends_sentence(ws[i].text) || ends_clause(ws[i].text)) score -= 12;
    if (score < best_score) {
      best_score = score;
      best = (int)i;
    }
  }
  std::string l1, l2;
  for (size_t i = 0; i < ws.size(); i++) {
    std::string& l = (int)i <= best ? l1 : l2;
    l += (l.empty() ? "" : " ") + ws[i].text;
  }
  return {l1, l2};
}

size_t text_len(const std::vector<Word>& ws) {
  size_t n = 0;
  for (auto& w : ws) n += w.text.size() + (n ? 1 : 0);
  return n;
}

// Groups words into cues: a cue ends at the end of a sentence, at a pause,
// or when it would not fit on two lines or stay up too long. A cue that
// overflows is cut at its last punctuation when there is one late enough,
// so a sentence's last words do not open the next cue.
std::vector<Cue> layout(const std::vector<Word>& words) {
  std::vector<Cue> cues;
  std::vector<Word> cur;
  auto emit = [&](size_t n) {
    std::vector<Word> head(cur.begin(), cur.begin() + n);
    cues.push_back({head.front().t0, head.back().t1, balance(head)});
    cur.erase(cur.begin(), cur.begin() + n);
  };
  for (const Word& w : words) {
    if (!cur.empty()) {
      bool pause = w.t0 - cur.back().t1 > kMaxGap;
      size_t len = text_len(cur) + 1 + w.text.size();
      // A sentence's last word may run a little over rather than open the
      // next cue on its own.
      size_t room = ends_sentence(w.text) ? 2 * kMaxLine + 6 : 2 * kMaxLine - 4;
      bool too_long = len > room || w.t1 - cur.front().t0 > kMaxCue;
      if (pause) {
        emit(cur.size());
      } else if (too_long) {
        size_t cut = cur.size();
        size_t total = text_len(cur), at = 0;
        for (size_t i = 0; i + 1 < cur.size(); i++) {
          at += cur[i].text.size() + (i ? 1 : 0);
          if ((ends_sentence(cur[i].text) || ends_clause(cur[i].text)) && at * 2 >= total) cut = i + 1;
        }
        emit(cut);
      }
    }
    cur.push_back(w);
    if (ends_sentence(w.text) && text_len(cur) >= 12) emit(cur.size());
  }
  if (!cur.empty()) emit(cur.size());
  return cues;
}

bool ends_sentence(const std::string& s) {
  if (s.empty()) return false;
  char c = s.back();
  return c == '.' || c == '?' || c == '!' || c == ':' || c == ';';
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
  // Alignment heads give word times that follow the speech (DTW), instead
  // of times spread evenly over each segment.
  cparams.dtw_token_timestamps = true;
  cparams.flash_attn = false;  // whisper turns DTW off with flash attention
  cparams.dtw_aheads_preset = aheads_for(model);
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
  // Word timings, so cues can be laid out below like subtitles are.
  p.token_timestamps = true;
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

  std::vector<Word> words = collect_words(ctx);
  std::vector<Cue> cues = layout(words);
  std::string srt;
  for (size_t i = 0; i < cues.size(); i++) {
    Cue& c = cues[i];
    // Keep short cues up long enough to read, without covering the next.
    int64_t end = std::max(c.t1, c.t0 + kMinCue);
    if (i + 1 < cues.size()) end = std::min(end, cues[i + 1].t0);
    srt += std::to_string(i + 1) + "\n" + srt_time(c.t0) + " --> " +
           srt_time(std::max(end, c.t1)) + "\n";
    for (auto& l : c.lines) srt += l + "\n";
    srt += "\n";
  }
  whisper_free(ctx);

  FILE* f = std::fopen(out_srt, "wb");
  if (!f) return ARCA_WHISPER_ERR_WRITE;
  bool ok = std::fwrite(srt.data(), 1, srt.size(), f) == srt.size();
  ok = std::fclose(f) == 0 && ok;
  if (progress) *progress = 100;
  return ok ? ARCA_WHISPER_OK : ARCA_WHISPER_ERR_WRITE;
}
