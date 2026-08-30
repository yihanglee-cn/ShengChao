// ORT 桥接层：把 onnxruntime C API 封装成简单接口（Swift 端只调这三个函数）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "onnxruntime_c_api.h"

typedef struct {
    const OrtApi* api;
    OrtEnv* env;
    OrtSession* session;
} DepthCtx;

// 创建会话：返回 0 成功
int depth_create(const char* model_path, void** out_ctx) {
    const OrtApi* api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!api) return -1;
    OrtEnv* env = NULL;
    if (api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "shengchao", &env)) return -2;
    OrtSessionOptions* so = NULL;
    if (api->CreateSessionOptions(&so)) { api->ReleaseEnv(env); return -3; }
    api->SetIntraOpNumThreads(so, 4);
    api->SetSessionGraphOptimizationLevel(so, ORT_ENABLE_ALL);
    OrtSession* session = NULL;
    OrtStatus* st = api->CreateSession(env, model_path, so, &session);
    api->ReleaseSessionOptions(so);
    if (st || !session) { api->ReleaseEnv(env); return -4; }
    DepthCtx* ctx = (DepthCtx*)malloc(sizeof(DepthCtx));
    ctx->api = api; ctx->env = env; ctx->session = session;
    *out_ctx = ctx;
    return 0;
}

// 推理：input 为 hw*hw*3 float32（RGB 归一化），output 为 hw*hw float32（深度）
// 返回 0 成功
int depth_run(void* vctx, const float* input, int hw, float* output) {
    DepthCtx* ctx = (DepthCtx*)vctx;
    const OrtApi* api = ctx->api;
    int64_t shape[4] = {1, 3, hw, hw};
    OrtMemoryInfo* mem = NULL;
    api->CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &mem);
    OrtValue* input_tensor = NULL;
    OrtStatus* st = api->CreateTensorWithDataAsOrtValue(
        mem, (void*)input, (size_t)(hw * hw * 3) * sizeof(float), shape, 4,
        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input_tensor);
    if (mem) api->ReleaseMemoryInfo(mem);
    if (st || !input_tensor) return -1;

    char out_name[] = "predicted_depth";  // 模型输出名（Depth Anything V2）
    const char* in_names[1] = {"pixel_values"};
    const char* out_names[1] = {out_name};
    OrtValue* out_tensor = NULL;
    st = api->Run(ctx->session, NULL, in_names, (const OrtValue* const*)&input_tensor, 1,
                  out_names, 1, &out_tensor);
    api->ReleaseValue(input_tensor);
    if (st || !out_tensor) return -2;

    float* out_data = NULL;
    st = api->GetTensorMutableData(out_tensor, (void**)&out_data);
    if (st || !out_data) { api->ReleaseValue(out_tensor); return -3; }
    memcpy(output, out_data, (size_t)(hw * hw) * sizeof(float));
    api->ReleaseValue(out_tensor);
    return 0;
}

// 销毁会话
void depth_destroy(void* vctx) {
    DepthCtx* ctx = (DepthCtx*)vctx;
    if (!ctx) return;
    const OrtApi* api = ctx->api;
    if (ctx->session) api->ReleaseSession(ctx->session);
    if (ctx->env) api->ReleaseEnv(ctx->env);
    free(ctx);
}
