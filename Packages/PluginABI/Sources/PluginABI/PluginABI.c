#include "ChassisPluginABI.h"

/// ABI 自身版本。宿主与插件都可用它做早期校验；
/// 真正的兼容判据仍是 `chassis_plugin_entry(uint32_t)` 的返回值。
uint32_t chassis_abi_version(void) {
    return CHASSIS_PLUGIN_ABI_VERSION;
}
