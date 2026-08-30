// ORT 桥接层声明（Swift 通过 -import-objc-header 导入）
#ifndef BRIDGE_H
#define BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// 创建 ORT 会话；成功返回 0，ctx 输出句柄
int depth_create(const char* model_path, void** out_ctx);

// 推理：input 1x3xHxW float32（H=W=sqrt(size/3)），output H*W float32；成功返回 0
int depth_run(void* vctx, const float* input, int size, float* output);

// 销毁会话
void depth_destroy(void* vctx);

#ifdef __cplusplus
}
#endif

#endif /* BRIDGE_H */
