/* fhstub.c v1.0 -- symbol stubs so libfhdrv_net_api.so loads standalone.
 * These symbols belong to other functions in the FH kitchen-sink .so; the
 * multiwan ioctl path (fhdrv_net_set_multiwan_mode) doesn't call them.
 * Stubs return 0/failure; extend the list as the loader demands.
 */
#include <stddef.h>

long fhapi_uci_get_config(void) { return -1; }
long fhapi_getobjidbyobjpath(void) { return -1; }
long fhapi_multinode_sessionprepare_ext(void) { return -1; }
long fhapi_singlevalue_get(void) { return -1; }
long fhcfg_init_str_vector(void) { return -1; }
long lib_fh_ubus_unregister_event_handler(void) { return -1; }
long fh_sys_mgr_get_wifi_total_num(void) { return 0; }
long fh_sys_mgr_get_mac_num(void) { return 0; }
long fh_sys_mgr_get_devinfo(void) { return -1; }
long fh_sys_mgr_get_ethmac(void) { return -1; }
long fh_sys_mgr_get_brmac(void) { return -1; }
long fh_sys_mgr_get_areacode(void) { return -1; }
long fh_sys_mgr_get_basemac(void) { return -1; }
