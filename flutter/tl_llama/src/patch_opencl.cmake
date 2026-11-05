# Applied to llama.cpp's OpenCL backend after download. A model on the GPU otherwise holds it for
# seconds at a time, and the whole system's drawing waits behind it.
set(_file "${SRC}/ggml/src/ggml-opencl/ggml-opencl.cpp")
file(READ "${_file}" _text)

# 1. The model yields to everything else on the GPU (Qualcomm's cl_qcom_priority_hint), where the
#    driver knows the hint; elsewhere the context is the plain one.
set(_old "    CL_CHECK(\n        (shared_context = clCreateContext(properties, device_ids.size(), device_ids.data(), NULL, NULL, &err), err));")
string(FIND "${_text}" "${_old}" _at)
if(_at EQUAL -1)
  message(FATAL_ERROR "patch_opencl: clCreateContext has changed in this llama.cpp")
endif()
set(_new "    cl_context_properties low_priority[] = { (intptr_t) CL_CONTEXT_PLATFORM, (intptr_t) default_device->platform->id, 0x40C9 /* CL_CONTEXT_PRIORITY_HINT_QCOM */, 0x40CC /* CL_PRIORITY_HINT_LOW_QCOM */, 0 };\n    shared_context = clCreateContext(low_priority, device_ids.size(), device_ids.data(), NULL, NULL, &err);\n    GGML_LOG_WARN(\"ggml_opencl: low priority context: %s\\n\", err == CL_SUCCESS ? \"yes\" : \"no\");\n    if (err != CL_SUCCESS) CL_CHECK(\n        (shared_context = clCreateContext(properties, device_ids.size(), device_ids.data(), NULL, NULL, &err), err));")
string(REPLACE "${_old}" "${_new}" _text "${_text}")

# 2. Short submissions: the GPU is free to switch between them.
set(_old "        sync_with_other_backends(backend);\n\n        if (ggml_is_empty(node) ||")
string(FIND "${_text}" "${_old}" _at)
if(_at EQUAL -1)
  message(FATAL_ERROR "patch_opencl: the graph loop has changed in this llama.cpp")
endif()
set(_new "        if (i > 0 && i % 16 == 0) clFinish(backend_ctx->queue);\n\n        sync_with_other_backends(backend);\n\n        if (ggml_is_empty(node) ||")
string(REPLACE "${_old}" "${_new}" _text "${_text}")

file(WRITE "${_file}" "${_text}")
