// A small C interface over llama.cpp, loaded by the Rust core (tl-core's `ai` module): list the
// devices, load a model on one of them, ask about one picture. Which device, and everything around
// the answer (prompt, picture, reading the reply), is the core's. Strings returned are freed with
// tl_llama_free_string.
#pragma once
#include <stdint.h>

#if defined(_WIN32)
#define TL_LLAMA_API __declspec(dllexport)
#else
#define TL_LLAMA_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tl_llama tl_llama;

// Loads the backends found in `dir` (the app's library folder); null: next to this library. Once
// per process; later calls do nothing.
TL_LLAMA_API void tl_llama_init(const char *dir);

// The devices llama.cpp found, as JSON: [{"name": "Vulkan0", "backend": "Vulkan", "description":
// "NVIDIA GeForce RTX 5090", "type": "gpu" | "igpu" | "cpu" | "accel", "free": bytes, "total": bytes,
// "id": "PCI bus id or empty"}]. The memory is as of this call.
TL_LLAMA_API char *tl_llama_devices(void);

// A model, entirely on the device named `device` (a "name" above), which has to be a GPU: there is
// no running on the processor. `projector` (a vision model's mmproj) may be null; `embeddings` for an
// embedder. On failure null, and *error says why.
TL_LLAMA_API tl_llama *tl_llama_load(const char *weights, const char *projector, const char *device, int32_t context,
                                     int32_t embeddings, char **error);

// The model's answer about the picture at `image` (JPEG, PNG, BMP, GIF), at most `max_tokens`.
TL_LLAMA_API char *tl_llama_describe(tl_llama *m, const char *image, const char *system, const char *question,
                                     int32_t max_tokens, char **error);

// An L2-normalized embedding of `text` into `out` (room for tl_llama_dimensions floats).
TL_LLAMA_API int32_t tl_llama_dimensions(tl_llama *m);
TL_LLAMA_API int32_t tl_llama_embed(tl_llama *m, const char *text, float *out, char **error);

TL_LLAMA_API void tl_llama_unload(tl_llama *m);
TL_LLAMA_API void tl_llama_free_string(char *s);

#ifdef __cplusplus
}
#endif
