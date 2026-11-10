#include "koe_host_api.h"

int koe_host_api_c_shim_anchor(void) {
    return (int)koe_host_api_version();
}
