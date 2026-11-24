#include "tl_llama.h"

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <exception>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "chat.h"
#include "ggml-backend.h"
#include "llama.h"
#ifdef __ANDROID__
#include <android/log.h>
#include <sys/system_properties.h>
#endif
#include "mtmd.h"
#include "mtmd-helper.h"

struct tl_llama {
  llama_model *model = nullptr;
  llama_context *ctx = nullptr;
  mtmd_context *vision = nullptr;
  // the model's template for llama.cpp's Jinja renderer, made the first time it is needed
  common_chat_templates_ptr vision_templates;
  bool embeddings = false;
};

static char *dup(const std::string &s) {
  char *p = static_cast<char *>(std::malloc(s.size() + 1));
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}
#ifdef __ANDROID__
// why a model did not load is only ever said here
static void log_to_logcat(ggml_log_level level, const char *text, void *) {
  if (level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_ERROR) __android_log_write(level == GGML_LOG_LEVEL_ERROR ? ANDROID_LOG_ERROR : ANDROID_LOG_WARN, "tl_llama", text);
}
// the vision part's own timings (the picture encoded, the prompt read) are information, kept too
static void mtmd_to_logcat(ggml_log_level level, const char *text, void *u) {
  if (level == GGML_LOG_LEVEL_INFO && std::strstr(text, " ms")) __android_log_write(ANDROID_LOG_INFO, "tl_llama", text);
  else log_to_logcat(level, text, u);
}
// Diagnostics, set over adb: `setprop debug.tl.device Vulkan0` runs the model on another GPU than
// the core chose, `setprop debug.tl.encoder Vulkan0` only the picture's encoder.
static std::string prop(const char *key) {
  char v[PROP_VALUE_MAX] = {0};
  __system_property_get(key, v);
  return v;
}
#endif

static void fail(char **error, const std::string &why) {
  if (error) *error = dup(why);
}

static std::string json_string(const char *s) {
  std::string o = "\"";
  for (const char *p = s ? s : ""; *p; p++) {
    const unsigned char c = static_cast<unsigned char>(*p);
    if (c == '"' || c == '\\') { o += '\\'; o += static_cast<char>(c); }
    else if (c < 0x20) { char u[8]; std::snprintf(u, sizeof u, "\\u%04x", c); o += u; }
    else o += static_cast<char>(c);
  }
  return o + "\"";
}

static const char *type_name(enum ggml_backend_dev_type t) {
  switch (t) {
    case GGML_BACKEND_DEVICE_TYPE_GPU: return "gpu";
    case GGML_BACKEND_DEVICE_TYPE_IGPU: return "igpu";
    case GGML_BACKEND_DEVICE_TYPE_CPU: return "cpu";
    default: return "accel";
  }
}

extern "C" void tl_llama_init(const char *dir) {
  // once per process
  static std::once_flag once;
  std::call_once(once, [dir] {
#ifdef __ANDROID__
    llama_log_set(log_to_logcat, nullptr);
    mtmd_helper_log_set(mtmd_to_logcat, nullptr);
#endif
    if (dir && *dir) ggml_backend_load_all_from_path(dir); else ggml_backend_load_all();
    llama_backend_init();
  });
}

extern "C" char *tl_llama_devices(void) {
  std::string out = "[";
  for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
    ggml_backend_dev_t d = ggml_backend_dev_get(i);
    ggml_backend_dev_props props;
    ggml_backend_dev_get_props(d, &props);
    ggml_backend_reg_t r = ggml_backend_dev_backend_reg(d);
    if (i) out += ",";
    out += "{\"name\":" + json_string(props.name) + ",\"backend\":" + json_string(r ? ggml_backend_reg_name(r) : "") +
           ",\"description\":" + json_string(props.description) + ",\"type\":\"" + type_name(props.type) +
           "\",\"free\":" + std::to_string(props.memory_free) + ",\"total\":" + std::to_string(props.memory_total) +
           ",\"id\":" + json_string(props.device_id) + "}";
  }
  return dup(out + "]");
}

static ggml_backend_dev_t gpu_named(const char *name) {
  if (!name) return nullptr;
  ggml_backend_dev_t d = ggml_backend_dev_by_name(name);
  if (!d) return nullptr;
  const auto t = ggml_backend_dev_type(d);
  return t == GGML_BACKEND_DEVICE_TYPE_GPU || t == GGML_BACKEND_DEVICE_TYPE_IGPU ? d : nullptr;
}

static tl_llama *load_model(const char *weights, const char *projector, const char *device, int32_t context,
                           int32_t embeddings, char **error) {
  ggml_backend_dev_t gpu = gpu_named(device);
  if (!gpu) { fail(error, std::string("no such GPU: ") + (device ? device : "(none)")); return nullptr; }
  ggml_backend_dev_t encoder = gpu;
#ifdef __ANDROID__
  if (ggml_backend_dev_t d = gpu_named(prop("debug.tl.device").c_str())) encoder = gpu = d;
  if (ggml_backend_dev_t d = gpu_named(prop("debug.tl.encoder").c_str())) encoder = d;
  __android_log_print(ANDROID_LOG_INFO, "tl_llama", "encoder on %s (%s)", ggml_backend_dev_name(encoder), ggml_backend_dev_description(encoder));
#endif
  auto *m = new tl_llama();
  llama_model_params mp = llama_model_default_params();
  ggml_backend_dev_t only[] = {gpu, nullptr};
  mp.devices = only;
  mp.n_gpu_layers = -1;  // all of it
#ifdef __ANDROID__
  __android_log_print(ANDROID_LOG_INFO, "tl_llama", "load on %s (%s)", device, ggml_backend_dev_description(gpu));
#endif
  m->model = llama_model_load_from_file(weights, mp);
  if (!m->model) { fail(error, "model"); delete m; return nullptr; }
  llama_context_params cp = llama_context_default_params();
  cp.n_ctx = context > 0 ? context : 4096;
  cp.n_batch = cp.n_ctx;
  cp.embeddings = embeddings != 0;
  if (cp.embeddings) cp.n_ubatch = cp.n_batch;
  m->embeddings = cp.embeddings;
  m->ctx = llama_init_from_model(m->model, cp);
  if (!m->ctx) { fail(error, "context"); tl_llama_unload(m); return nullptr; }
  if (projector && *projector) {
    mtmd_context_params vp = mtmd_context_params_default();
    vp.use_gpu = true;
    vp.device = encoder;
    vp.print_timings = true;
    // The pictures the core sends are at most 896 on their long side (core/src/ai/picture.rs),
    // which no model turns into more than 1024 tokens (14-pixel patches merged 2 by 2: 32 x 32).
    // Said to the encoder, it warms up and reserves for that, not for its own limit (Qwen2.5-VL:
    // 8464): that much fits no buffer of a phone's OpenCL, and the first picture ended the app.
    vp.image_max_tokens = 1024;
    m->vision = mtmd_init_from_file(projector, m->model, vp);
    if (!m->vision) { fail(error, "projector"); tl_llama_unload(m); return nullptr; }
  }
  return m;
}

// The model's own chat template with the instruction and the question, the picture's place marked in
// the user's message. llama.cpp's C function knows a fixed set of templates (not Gemma 4's, for one);
// any other is rendered by its Jinja renderer, as llama.cpp's own tools do. After the suggestion in
// github.com/XGWYTWGDYU/TwimShelf/pull/6 (JensenYang226).
static std::string picture_prompt(tl_llama *m, const char *system, const char *question) {
  const std::string marker = mtmd_default_marker();
  const std::string user = marker + "\n" + question;
  llama_chat_message msgs[2] = {{"system", system}, {"user", user.c_str()}};
  const char *tmpl = llama_model_chat_template(m->model, nullptr);
  std::vector<char> buf(user.size() * 2 + std::strlen(system) + 1024);
  int32_t n = llama_chat_apply_template(tmpl, msgs, 2, true, buf.data(), (int32_t)buf.size());
  if (n > (int32_t)buf.size()) { buf.resize(n + 1); n = llama_chat_apply_template(tmpl, msgs, 2, true, buf.data(), (int32_t)buf.size()); }
  if (n >= 0) {
    std::string prompt(buf.data(), n);
    // a model that reasons in <think>: its reasoning is already over when it starts to answer
    if (tmpl && std::strstr(tmpl, "<think>")) {
      const std::string open = "<think>\n";
      if (prompt.size() >= open.size() && prompt.compare(prompt.size() - open.size(), open.size(), open) == 0) prompt += "\n</think>\n\n";
      else prompt += "<think>\n\n</think>\n\n";
    }
    return prompt;
  }
  if (!m->vision_templates) m->vision_templates = common_chat_templates_init(m->model, "");
  common_chat_templates_inputs inputs;
  inputs.enable_thinking = false;   // the template itself leaves the reasoning out
  inputs.force_pure_content = true;
  common_chat_msg instruction;
  instruction.role = "system";
  instruction.content = system;
  common_chat_msg picture;
  picture.role = "user";
  picture.content_parts = {{"media_marker", marker}, {"text", std::string("\n") + question}};
  inputs.messages = {std::move(instruction), std::move(picture)};
  std::string prompt = common_chat_templates_apply(m->vision_templates.get(), inputs).prompt.str();
  const auto at = prompt.find(marker);
  if (at == std::string::npos || prompt.find(marker, at + marker.size()) != std::string::npos) {
    throw std::runtime_error("not one place for the picture");
  }
  return prompt;
}

static char *describe_picture(tl_llama *m, const char *image, const char *system, const char *question,
                                   int32_t max_tokens, char **error) {
  if (!m || !m->vision) { fail(error, "no vision model"); return nullptr; }
  const llama_vocab *vocab = llama_model_get_vocab(m->model);
  llama_memory_clear(llama_get_memory(m->ctx), true);

  std::string prompt;
  try {
    prompt = picture_prompt(m, system, question);
  } catch (const std::exception &e) {
    fail(error, std::string("chat template: ") + e.what());
    return nullptr;
  }

  mtmd_helper_bitmap_wrapper loaded = mtmd_helper_bitmap_init_from_file(m->vision, image, false, mtmd_helper_init_opt_default());
  mtmd_bitmap *bitmap = loaded.bitmap;
  if (!bitmap) { fail(error, "image"); return nullptr; }
  mtmd_input_chunks *chunks = mtmd_input_chunks_init();
  mtmd_input_text text{prompt.c_str(), prompt.size(), true, true};
  const mtmd_bitmap *bitmaps[1] = {bitmap};
  int32_t r = mtmd_tokenize(m->vision, chunks, &text, bitmaps, 1);
  llama_pos past = 0;
  const auto t_read = std::chrono::steady_clock::now();
  if (r == 0) r = mtmd_helper_eval_chunks(m->vision, m->ctx, chunks, 0, 0, (int32_t)llama_n_batch(m->ctx), true, &past);
  const auto t_gen = std::chrono::steady_clock::now();
  mtmd_input_chunks_free(chunks);
  mtmd_bitmap_free(bitmap);
  if (r != 0) { fail(error, "prompt"); return nullptr; }

  // nearly greedy, as the MLX engine (temperature 0.1)
  llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
  llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.1f));
  llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
  std::string out;
  for (int32_t i = 0; i < max_tokens; i++) {
    llama_token tok = llama_sampler_sample(smpl, m->ctx, -1);
    if (llama_vocab_is_eog(vocab, tok)) break;
    char piece[256];
    int32_t k = llama_token_to_piece(vocab, tok, piece, sizeof piece, 0, false);
    if (k > 0) out.append(piece, k);
    llama_batch b = llama_batch_get_one(&tok, 1);
    if (llama_decode(m->ctx, b) != 0) break;
  }
  llama_sampler_free(smpl);
#ifdef __ANDROID__
  using ms = std::chrono::milliseconds;
  const auto t_end = std::chrono::steady_clock::now();
  __android_log_print(ANDROID_LOG_INFO, "tl_llama", "stages: picture and prompt %lld ms (%d positions), answer %lld ms (%zu chars)",
                      (long long)std::chrono::duration_cast<ms>(t_gen - t_read).count(), (int)past,
                      (long long)std::chrono::duration_cast<ms>(t_end - t_gen).count(), out.size());
#endif
  return dup(out);
}

// A GPU that gives up (Vulkan's device lost) throws, and nothing above here would catch it: the app
// would end. The caller gets it as the job's error.
template <typename F>
static auto guarded(char **error, F body) -> decltype(body()) {
  try {
    return body();
  } catch (const std::exception &e) {
    fail(error, e.what());
  } catch (...) {
    fail(error, "engine");
  }
  return nullptr;
}

extern "C" tl_llama *tl_llama_load(const char *weights, const char *projector, const char *device, int32_t context,
                                   int32_t embeddings, char **error) {
  return guarded(error, [&] { return load_model(weights, projector, device, context, embeddings, error); });
}

extern "C" char *tl_llama_describe(tl_llama *m, const char *image, const char *system, const char *question,
                                   int32_t max_tokens, char **error) {
  const auto start = std::chrono::steady_clock::now();
  char *answer = guarded(error, [&] { return describe_picture(m, image, system, question, max_tokens, error); });
#ifdef __ANDROID__
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - start).count();
  __android_log_print(ANDROID_LOG_INFO, "tl_llama", "picture: %lld ms, %s", (long long)ms, answer ? "ok" : "failed");
#else
  (void)start;
#endif
  return answer;
}

extern "C" int32_t tl_llama_dimensions(tl_llama *m) { return m ? llama_model_n_embd_out(m->model) : 0; }

extern "C" int32_t tl_llama_embed(tl_llama *m, const char *text, float *out, char **error) {
  if (!m || !m->embeddings || !text || !out) { fail(error, "no embedding model or input"); return -1; }
  try {
    const auto *vocab = llama_model_get_vocab(m->model);
    const auto length = std::strlen(text);
    if (length > INT32_MAX) { fail(error, "embedding input too long"); return -1; }
    const auto text_size = static_cast<int32_t>(length);
    const auto required = llama_tokenize(vocab, text, text_size, nullptr, 0, true, false);
    if (required >= 0 || -static_cast<int64_t>(required) > llama_n_ctx(m->ctx)) {
      fail(error, "invalid embedding token count");
      return -1;
    }
    std::vector<llama_token> tokens(static_cast<size_t>(-required));
    const auto count = llama_tokenize(vocab, text, text_size, tokens.data(), -required, true, false);
    if (count <= 0) { fail(error, "embedding tokenization"); return -1; }
    llama_memory_clear(llama_get_memory(m->ctx), true);
    auto batch = llama_batch_get_one(tokens.data(), count);
    const auto rc = llama_model_has_encoder(m->model) ? llama_encode(m->ctx, batch) : llama_decode(m->ctx, batch);
    if (rc != 0) { fail(error, "embedding evaluation"); return -1; }
    const auto pooling = llama_pooling_type(m->ctx);
    const float *vector = pooling == LLAMA_POOLING_TYPE_NONE
        ? llama_get_embeddings_ith(m->ctx, -1) : llama_get_embeddings_seq(m->ctx, 0);
    const auto dimensions = tl_llama_dimensions(m);
    if (!vector || dimensions <= 0 || pooling == LLAMA_POOLING_TYPE_RANK) {
      fail(error, "no text embedding");
      return -1;
    }
    double squared_norm = 0;
    for (int32_t i = 0; i < dimensions; ++i) squared_norm += static_cast<double>(vector[i]) * vector[i];
    if (squared_norm <= 0 || !std::isfinite(squared_norm)) { fail(error, "invalid embedding"); return -1; }
    const auto norm = std::sqrt(squared_norm);
    for (int32_t i = 0; i < dimensions; ++i) out[i] = static_cast<float>(vector[i] / norm);
    return 0;
  } catch (const std::exception &e) {
    fail(error, e.what());
  } catch (...) {
    fail(error, "embedding engine");
  }
  return -1;
}

extern "C" void tl_llama_unload(tl_llama *m) {
  if (!m) return;
  if (m->vision) mtmd_free(m->vision);
  if (m->ctx) llama_free(m->ctx);
  if (m->model) llama_model_free(m->model);
  delete m;
}

extern "C" void tl_llama_free_string(char *s) { std::free(s); }
