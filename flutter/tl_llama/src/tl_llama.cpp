#include "tl_llama.h"

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <exception>
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
  m->embeddings = cp.embeddings;
  m->ctx = llama_init_from_model(m->model, cp);
  if (!m->ctx) { fail(error, "context"); tl_llama_unload(m); return nullptr; }
  if (projector && *projector) {
    mtmd_context_params vp = mtmd_context_params_default();
    vp.use_gpu = gpu_layers > 0;
    vp.device = gpu;
    vp.print_timings = false;
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

extern "C" int32_t tl_llama_dimensions(tl_llama *m) { return m ? llama_model_n_embd(m->model) : 0; }

extern "C" void tl_llama_unload(tl_llama *m) {
  if (!m) return;
  if (m->vision) mtmd_free(m->vision);
  if (m->ctx) llama_free(m->ctx);
  if (m->model) llama_model_free(m->model);
  delete m;
}

extern "C" void tl_llama_free_string(char *s) { std::free(s); }
