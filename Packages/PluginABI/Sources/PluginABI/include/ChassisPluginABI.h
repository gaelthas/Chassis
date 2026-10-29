//
//  ChassisPluginABI.h
//  Chassis 外部插件 ABI（v1，纯 C）
//
//  为什么用 C 而不是 Swift protocol：Swift 的 protocol 跨动态库没有稳定 ABI，
//  第三方用另一个 Xcode/Swift 版本编译就会崩。C ABI 是唯一跨工具链稳定的边界。
//
//  版本演进规则：只允许在结构体末尾追加字段，并用 struct_size 让旧宿主截断读取。
//  apiVersion 不匹配时宿主拒绝加载，不做猜测性兼容。
//

#ifndef CHASSIS_PLUGIN_ABI_H
#define CHASSIS_PLUGIN_ABI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CHASSIS_PLUGIN_ABI_VERSION 1

typedef enum {
    CHASSIS_KEY_DOWN = 0,
    CHASSIS_KEY_UP = 1,
    CHASSIS_KEY_FLAGS_CHANGED = 2,
} chassis_key_kind;

typedef enum {
    CHASSIS_MOUSE_LEFT = 0,
    CHASSIS_MOUSE_RIGHT = 1,
    CHASSIS_MOUSE_OTHER = 2,
} chassis_mouse_button;

typedef enum {
    CHASSIS_INTERRUPT_TIMEOUT = 0,
    CHASSIS_INTERRUPT_PERMISSION_REVOKED = 1,
    CHASSIS_INTERRUPT_TAP_FAILED = 2,
} chassis_interrupt_reason;

typedef enum {
    CHASSIS_LOG_DEBUG = 0,
    CHASSIS_LOG_INFO = 1,
    CHASSIS_LOG_WARNING = 2,
    CHASSIS_LOG_ERROR = 3,
} chassis_log_level;

typedef struct {
    double x;
    double y;
    double timestamp;
    int32_t button;
    int32_t click_count;
    int32_t frontmost_pid;   /* 0 表示未知 */
} chassis_click_v1;

typedef struct {
    int32_t kind;            /* chassis_key_kind */
    int64_t key_code;
    uint64_t flags;
    int32_t is_repeat;
} chassis_key_v1;

typedef struct chassis_host_services_v1 {
    uint32_t struct_size;
    void *host;

    const char *(*plugin_id)(void *host);
    const char *(*host_version)(void *host);
    int32_t (*permission_status)(void *host, const char *capability);

    /* 订阅返回不透明句柄，取消时交给 unsubscribe。回调都在主线程执行。 */
    const void *(*subscribe_click)(void *host,
                                   void (*callback)(void *ctx, const chassis_click_v1 *event),
                                   void *ctx);
    const void *(*subscribe_pointer)(void *host,
                                     void (*callback)(void *ctx, double x, double y),
                                     void *ctx);
    const void *(*subscribe_key)(void *host,
                                 const int64_t *key_codes,
                                 size_t count,
                                 uint64_t required_flags,
                                 int32_t (*intercept)(void *ctx, const chassis_key_v1 *event),
                                 void (*handler)(void *ctx, const chassis_key_v1 *event),
                                 void *ctx);
    const void *(*subscribe_interruptions)(void *host,
                                           void (*callback)(void *ctx, int32_t source, int32_t reason, int32_t recovered),
                                           void *ctx);
    void (*unsubscribe)(void *host, const void *subscription);

    /* 快捷键：同一插件可注册多个；冲突返回非 0。 */
    int32_t (*register_hotkey)(void *host,
                               uint32_t key_code,
                               uint32_t modifiers,
                               void (*callback)(void *ctx),
                               void *ctx);
    void (*unregister_hotkeys)(void *host);

    void (*post_notification)(void *host, const char *identifier, const char *title, const char *body);

    /* 字符串配置：get 返回实际长度（>=0），buffer 不够时返回所需大小并让调用方重试。 */
    int32_t (*store_get)(void *host, const char *key, char *buffer, size_t buffer_size);
    void (*store_set)(void *host, const char *key, const char *value);

    void (*log)(void *host, int32_t level, const char *message);

    /* 可能阻塞的跨进程调用：work 在基座的后台串行队列执行，禁止回调主线程。 */
    int32_t (*perform_background)(void *host, void (*work)(void *ctx), void *ctx);
} chassis_host_services_v1;

typedef struct chassis_plugin_v1 {
    uint32_t struct_size;
    /* manifest.json 原文（UTF-8），与包内文件一致；宿主会二次校验。 */
    const char *manifest_json;
    void *(*create)(void);
    void (*destroy)(void *instance);
    int32_t (*activate)(void *instance, const chassis_host_services_v1 *services);
    void (*deactivate)(void *instance);
    /* 返回 NSViewController*（+1 retain）；宿主负责包装成 SwiftUI 视图。 */
    void *(*make_settings_view)(void *instance);
} chassis_plugin_v1;

/* 插件唯一必须导出的符号。返回 NULL 或版本不符时宿主拒绝加载。 */
chassis_plugin_v1 *chassis_plugin_entry(uint32_t host_abi_version);

#ifdef __cplusplus
}
#endif

#endif /* CHASSIS_PLUGIN_ABI_H */
