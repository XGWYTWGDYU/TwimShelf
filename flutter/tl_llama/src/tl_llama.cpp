#include "tl_llama.h"

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <mutex>
#include <string>
#include <vector>

#include "ggml-backend.h"
#include "llama.h"
#ifdef __ANDROID__
#include <android/log.h>
#endif
#include "mtmd.h"
#include "mtmd-helper.h"

struct tl_llama {
  llama_model *model = nullptr;
  llama_context *ctx = nullptr;
  mtmd_context *vision = nullptr;
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
#endif

/// The GPU to run on when there is a choice: OpenCL is the backend made for Adreno, the one GPU family
/// it is offered for here (a device where Vulkan's queue is lost mid-job). None: llama.cpp chooses.
static ggml_backend_dev_t opencl_device() {
  for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
    ggml_backend_dev_t d = ggml_backend_dev_get(i);
    ggml_backend_reg_t r = ggml_backend_dev_backend_reg(d);
    if (r && std::strcmp(ggml_backend_reg_name(r), "OpenCL") == 0 && ggml_backend_dev_type(d) == GGML_BACKEND_DEVICE_TYPE_GPU) return d;
  }
  return nullptr;
}

// Qwen2.5-VL (general.architecture "qwen2vl"), the vision models of the catalog. The picture the
// tagger prepares is at most 896 on its long side: (896 / 28)² = 1024 of its tokens. Said to the
// encoder, that is also the size it warms up with, instead of its own limit of 1288²: an attention
// that size fits no GPU buffer without flash attention, and runs on the processor in 4.8 GB.
static constexpr int kTaggingTokens = 1024;
// Vulkan: without flash attention its encoder took 6.8 s instead of 12.8 s for such a picture on a
// Radeon RX 580 (no fp16 or matrix cores), in a compute buffer of 1.2 GB instead of 0.6 GB. Taken
// where the GPU has that room left beside the projector once the language model is in place.
// (CUDA's flash attention is its fast path: left as it is.)
static constexpr size_t kEncoderBuffer = size_t(1300) << 20;

/// The GPU the model runs on (the first one, when llama.cpp chooses), or none.
static ggml_backend_dev_t model_gpu(ggml_backend_dev_t chosen) {
  for (size_t i = 0; !chosen && i < ggml_backend_dev_count(); i++) {
    ggml_backend_dev_t c = ggml_backend_dev_get(i);
    const auto type = ggml_backend_dev_type(c);
    if (type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU) chosen = c;
  }
  return chosen;
}

/// A Vulkan GPU with `bytes` free.
static bool vulkan_with_room(ggml_backend_dev_t d, size_t bytes) {
  if (!d) return false;
  ggml_backend_reg_t r = ggml_backend_dev_backend_reg(d);
  if (!r || std::strcmp(ggml_backend_reg_name(r), "Vulkan") != 0) return false;
  size_t free = 0, total = 0;
  ggml_backend_dev_memory(d, &free, &total);
  return free >= bytes;
}

static size_t file_size(const char *utf8) {
  std::error_code e;
  const auto n = std::filesystem::file_size(std::filesystem::u8path(utf8), e);
  return e ? 0 : static_cast<size_t>(n);
}

static void fail(char **error, const std::string &why) {
  if (error) *error = dup(why);
}

extern "C" char *tl_llama_init(const char *dir) {
  // once per process (Dart calls it from every worker isolate)
  static std::mutex lock;
  static std::string devices;
  static bool ready = false;
  std::lock_guard<std::mutex> g(lock);
  if (ready) return dup(devices);
  ready = true;
#ifdef __ANDROID__
  llama_log_set(log_to_logcat, nullptr);
  mtmd_helper_log_set(log_to_logcat, nullptr);
#endif
  if (dir && *dir) ggml_backend_load_all_from_path(dir); else ggml_backend_load_all();
  llama_backend_init();
  for (size_t i = 0; i < ggml_backend_dev_count(); i++) {
    ggml_backend_dev_t d = ggml_backend_dev_get(i);
    if (!devices.empty()) devices += ", ";
    devices += ggml_backend_dev_name(d);
    const char *desc = ggml_backend_dev_description(d);
    if (desc && *desc) { devices += " ("; devices += desc; devices += ")"; }
  }
  return dup(devices);
}

static tl_llama *load_model(const char *weights, const char *projector, int32_t gpu_layers, int32_t context,
                           int32_t embeddings, char **error) {
  if (ggml_backend_dev_count() == 0) { fail(error, "no llama.cpp backend found"); return nullptr; }
  auto *m = new tl_llama();
  llama_model_params mp = llama_model_default_params();
  mp.n_gpu_layers = gpu_layers;
  ggml_backend_dev_t gpu = gpu_layers > 0 ? opencl_device() : nullptr;
  ggml_backend_dev_t only[] = {gpu, nullptr};
  if (gpu) mp.devices = only;
#ifdef __ANDROID__
  __android_log_print(ANDROID_LOG_INFO, "tl_llama", "load: gpu layers %d, device %s", gpu_layers, gpu ? ggml_backend_dev_description(gpu) : "chosen by llama.cpp");
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
    vp.use_gpu = gpu_layers > 0;
    vp.device = gpu;
    vp.print_timings = false;
    char arch[64] = {0};
    if (llama_model_meta_val_str(m->model, "general.architecture", arch, sizeof arch) > 0 && std::strcmp(arch, "qwen2vl") == 0) {
      vp.image_max_tokens = kTaggingTokens;
      const size_t projector_bytes = file_size(projector);
      if (vp.use_gpu && projector_bytes > 0 && vulkan_with_room(model_gpu(gpu), projector_bytes + kEncoderBuffer)) vp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
#ifdef __ANDROID__
      __android_log_print(ANDROID_LOG_INFO, "tl_llama", "encoder: flash attention %s", vp.flash_attn_type == LLAMA_FLASH_ATTN_TYPE_DISABLED ? "off" : "auto");
#endif
    }
    m->vision = mtmd_init_from_file(projector, m->model, vp);
    if (!m->vision) { fail(error, "projector"); tl_llama_unload(m); return nullptr; }
  }
  return m;
}

static char *describe_picture(tl_llama *m, const char *image, const char *system, const char *question,
                                   int32_t max_tokens, char **error) {
  if (!m || !m->vision) { fail(error, "no vision model"); return nullptr; }
  const llama_vocab *vocab = llama_model_get_vocab(m->model);
  llama_memory_clear(llama_get_memory(m->ctx), true);

  // the model's own chat template, the picture's place marked in the user's message
  std::string user = std::string(mtmd_default_marker()) + "\n" + question;
  llama_chat_message msgs[2] = {{"system", system}, {"user", user.c_str()}};
  const char *tmpl = llama_model_chat_template(m->model, nullptr);
  std::vector<char> buf(user.size() * 2 + std::strlen(system) + 1024);
  int32_t n = llama_chat_apply_template(tmpl, msgs, 2, true, buf.data(), (int32_t)buf.size());
  if (n > (int32_t)buf.size()) { buf.resize(n + 1); n = llama_chat_apply_template(tmpl, msgs, 2, true, buf.data(), (int32_t)buf.size()); }
  if (n < 0) { fail(error, "chat template"); return nullptr; }
  std::string prompt(buf.data(), n);
  // a model that reasons in <think>: its reasoning is already over when it starts to answer
  if (tmpl && std::strstr(tmpl, "<think>")) {
    const std::string open = "<think>\n";
    if (prompt.size() >= open.size() && prompt.compare(prompt.size() - open.size(), open.size(), open) == 0) prompt += "\n</think>\n\n";
    else prompt += "<think>\n\n</think>\n\n";
  }

  mtmd_helper_bitmap_wrapper loaded = mtmd_helper_bitmap_init_from_file(m->vision, image, false, mtmd_helper_init_opt_default());
  mtmd_bitmap *bitmap = loaded.bitmap;
  if (!bitmap) { fail(error, "image"); return nullptr; }
  mtmd_input_chunks *chunks = mtmd_input_chunks_init();
  mtmd_input_text text{prompt.c_str(), prompt.size(), true, true};
  const mtmd_bitmap *bitmaps[1] = {bitmap};
  int32_t r = mtmd_tokenize(m->vision, chunks, &text, bitmaps, 1);
  llama_pos past = 0;
  if (r == 0) r = mtmd_helper_eval_chunks(m->vision, m->ctx, chunks, 0, 0, (int32_t)llama_n_batch(m->ctx), true, &past);
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

extern "C" tl_llama *tl_llama_load(const char *weights, const char *projector, int32_t gpu_layers, int32_t context,
                                   int32_t embeddings, char **error) {
  return guarded(error, [&] { return load_model(weights, projector, gpu_layers, context, embeddings, error); });
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
