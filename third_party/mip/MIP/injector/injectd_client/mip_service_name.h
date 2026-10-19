/* Mach service name of the private injectd daemon.
 *
 * The daemon (injector/injectd.m) owns this service and the client
 * (injector/injectd_client/injectd_client.m) connects to it. The name must match the
 * MachServices key of the private injectd LaunchDaemon plist, which the Makefile generates
 * from MIP_SERVICE_NAME. The two are cross-checked by the build (see MIP/Makefile).
 */
#ifndef MIP_SERVICE_NAME_H
#define MIP_SERVICE_NAME_H

#define MIP_MACH_SERVICE_NAME "com.wiggly-sheets.spaces-renamer.injectd"

#endif /* MIP_SERVICE_NAME_H */
