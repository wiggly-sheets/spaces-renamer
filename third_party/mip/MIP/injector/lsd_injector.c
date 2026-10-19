#include <xpc/xpc.h>
#include <bsm/libbsm.h>
#include <libproc.h>
#include <stdint.h>
#include <pwd.h>
#include <sys/syslimits.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <os/log.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include "injectd_client/injectd_client.h"

// Private APIs
extern mach_port_t xpc_dictionary_copy_mach_send(xpc_object_t, const char *);
extern void xpc_dictionary_get_audit_token(xpc_object_t xdict, audit_token_t *token);

static const char *MIP_injector_path(void)
{
    Dl_info info;
    dladdr("", &info); // Get own info
    return info.dli_fname;
}

static const char *MIP_loader_path(void)
{
    static char *ret = NULL;
    if (ret) return ret;

    ret = strdup(MIP_injector_path());
    *strrchr(ret, '/') = 0;

    // strlen("loader.dylib") < strlen("lsdinjector.dylib")
    strcat(ret, "/loader.dylib");

    return ret;
}

static const char *MIP_root_path(void)
{
    static char *ret = NULL;
    if (ret) return ret;

    ret = strdup(MIP_injector_path());
    *strrchr(ret, '/') = 0;
    return ret;
}

static os_log_t MIP_log(void)
{
    static os_log_t log = NULL;
    if (!log) {
        log = os_log_create("com.wiggly-sheets.spaces-renamer.mip", "lsdinjector");
    }
    return log;
}

/* We want the user data to be accessible from all processes, but some processes (for
   example, Chrome's sub-processes) have a very strict sandbox profile so putting the
   data in the user's home folder won't always work. /usr/lib, on the other hand, is
   accessible from all processes (Otherwise they're pretty much worthless to hook in the
   first place), so we put our data in /usr/lib/mip/user_data/<uid>/. We also set
   a symlink in the user's Library folder, for easier access.

   Private build: the symlink in the user's Library folder is NOT created. The user may
   already have a ~/Library/MIP symlink that belongs to a system MIP install, and hijacking
   it would break that install. The private runtime keeps its user data under its own root
   (<MIP_ROOT>/user_data/<uid>). */
static void create_user_data_folder(pid_t pid)
{
    struct proc_bsdinfo proc;
    proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &proc, sizeof(proc));

    char path[PATH_MAX];
    sprintf(path, "%s/user_data/%d", MIP_root_path(), proc.pbi_uid);

    if (mkdir(path, 0755)) return; // Might already exist
    chown(path, proc.pbi_uid, proc.pbi_gid);
}

static void handleClientMessageHook_common(uint64_t command, xpc_object_t dict)
{
    /* Command 500 is sent by all GUI processes to launchservicesd when they launch.
       The process will block until it receives an answer from launchservicesd.
       We will inject our code before we send a reply. Once we send the actual reply,
       by calling the original method, the process resumes, runs the injected dlopen,
       and continues normal execution. */

    if (command == 500) {
        audit_token_t token;
        xpc_dictionary_get_audit_token(dict, &token);
        pid_t pid = audit_token_to_pid(token);

        /* While strictly speaking this should be loader's responsibility to create this folder,
           this function must run as root, so it is done by the injector. */
        create_user_data_folder(pid);
        inject_to_pid(pid, MIP_loader_path(), false);
    }
}

/* ---------------------------------------------------------------------------
 * Coexistence with another MIP chain.
 *
 * Upstream replaces the single launchservicesd GOT slot that points at
 * xpc_dictionary_get_int64 with its own hook. A second lsdinjector that runs afterwards
 * looks for a slot still holding the original symbol, finds none, and silently never
 * installs its hook: that chain stops injecting anything.
 *
 * The private build therefore
 *   1. chains onto a hook that another lsdinjector already installed, and
 *   2. waits a short while before claiming the still untouched slot, so that a competing
 *      chain which is still starting up gets the slot first and this chain chains onto it.
 * ------------------------------------------------------------------------- */

#if __arm64__
#define MIP_STRIP(p) ((uintptr_t)__builtin_ptrauth_strip((void *)(p), 0))
#else
#define MIP_STRIP(p) ((uintptr_t)(p))
#endif

/* How long to wait for a competing chain to hook the slot before claiming it ourselves.
   Both chains' LaunchDaemons race at boot, and the competing chain injects its
   lsdinjector a few seconds after launchservicesd appears. */
#define MIP_HOOK_GRACE_US 15000000
#define MIP_HOOK_POLL_US 250000

typedef uint64_t (*mip_int64_getter_t)(xpc_object_t, const char *);

/* The hook that was in the slot before ours, if any. Signed for a C function pointer
   call (see mip_sign_for_call). */
static mip_int64_getter_t mip_previous_getter = NULL;

static uintptr_t mip_original_address = 0;
static void **mip_slot_start = NULL;
static void **mip_slot_end = NULL;

#if __arm64__
/* clang emits `braaz` for an indirect call, which authenticates the target pointer with
   ptrauth_key_function_pointer and discriminator 0. The pointer stored in the GOT slot
   is signed with the slot address as discriminator (that is what the call site in
   launchservicesd expects), so it has to be re-signed before it is called from C. */
static void *mip_sign_for_call(void *raw)
{
    return ptrauth_sign_unauthenticated(raw, ptrauth_key_function_pointer, 0);
}
#else
static void *mip_sign_for_call(void *raw)
{
    return raw;
}
#endif

static uint64_t mip_call_previous(xpc_object_t dict, const char *key)
{
    mip_int64_getter_t previous = __atomic_load_n(&mip_previous_getter, __ATOMIC_ACQUIRE);
    if (previous) return previous(dict, key);
    return xpc_dictionary_get_int64(dict, key);
}

static uint64_t xpc_dictionary_get_int64_hook(xpc_object_t dict, const char *key)
{
    uint64_t ret = mip_call_previous(dict, key);
    if (strcmp(key, "command") == 0) {
        handleClientMessageHook_common(ret, dict);
    }
    return ret;
}

static int mip_path_ends_with(const char *path, const char *suffix)
{
    size_t path_len = strlen(path);
    size_t suffix_len = strlen(suffix);
    return path_len >= suffix_len && strcmp(path + path_len - suffix_len, suffix) == 0;
}

/* Text range of a loaded image, used to recognise a pointer to another lsdinjector's hook. */
static bool mip_image_text_range(uint32_t index, uintptr_t *low, uintptr_t *high)
{
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(index);
    if (!header || header->magic != MH_MAGIC_64) return false;

    uintptr_t slide = _dyld_get_image_vmaddr_slide(index);
    const struct load_command *cmd = (const struct load_command *)(header + 1);
    for (unsigned i = 0; i < header->ncmds; i++, cmd = (const struct load_command *)((char *)cmd + cmd->cmdsize)) {
        if (cmd->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)cmd;
        if (strcmp(segment->segname, "__TEXT") != 0) continue;
        *low = (uintptr_t)segment->vmaddr + slide;
        *high = *low + segment->vmsize;
        return true;
    }
    return false;
}

/* The GOT slot of launchservicesd that holds the xpc_dictionary_get_int64 pointer. */
static bool mip_data_const_range(void ***start, void ***end)
{
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64) return false;

    uintptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const struct load_command *cmd = (const struct load_command *)(header + 1);
    for (unsigned i = 0; i < header->ncmds; i++, cmd = (const struct load_command *)((char *)cmd + cmd->cmdsize)) {
        if (cmd->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)cmd;
#if __arm64__
        if (strcmp(segment->segname, "__DATA_CONST") == 0) {
#else
        if (strcmp(segment->segname, "__DATA") == 0) {
#endif
            *start = (void **)(segment->vmaddr + slide);
            *end = *start + segment->vmsize / sizeof(void *);
            return true;
        }
    }
    return false;
}

/* Find the slot and report the value currently stored in it. */
static void **mip_find_hook_slot(uintptr_t *stored)
{
    void **slot;

    /* The slot still holds the original libxpc function. */
    for (slot = mip_slot_start; slot < mip_slot_end; slot++) {
        if (MIP_STRIP(*slot) == mip_original_address) {
            *stored = (uintptr_t)*slot;
            return slot;
        }
    }

    /* Another lsdinjector hooked it already: recognise the slot by the pointer to that
       image's hook function. */
    const char *own_path = MIP_injector_path();
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path || !mip_path_ends_with(path, "/lsdinjector.dylib")) continue;
        if (own_path && strcmp(path, own_path) == 0) continue;

        uintptr_t low = 0, high = 0;
        if (!mip_image_text_range(i, &low, &high)) continue;

        for (slot = mip_slot_start; slot < mip_slot_end; slot++) {
            uintptr_t value = MIP_STRIP(*slot);
            if (value >= low && value < high) {
                *stored = (uintptr_t)*slot;
                return slot;
            }
        }
    }

    return NULL;
}

#if __arm64__

// Derived from code by khanhduytran0 {
#define _COMM_PAGE_START_ADDRESS (0x00000000FFFFFC000ULL)
#define _COMM_PAGE_TPRO_WRITE_ENABLE (_COMM_PAGE_START_ADDRESS + 0x0D0)
#define _COMM_PAGE_TPRO_WRITE_DISABLE (_COMM_PAGE_START_ADDRESS + 0x0D8)

static bool os_tpro_is_supported(void)
{
    if (*(uint64_t*)_COMM_PAGE_TPRO_WRITE_ENABLE) {
        return true;
    }
    return false;
}

__attribute__((naked)) bool os_thread_self_tpro_is_writeable(void)
{
    __asm__ __volatile__ (
                          "mrs             x0, s3_6_c15_c1_5\n"
                          "ubfx            x0, x0, #0x24, #1;\n"
                          "ret\n"
                          );
}

void os_thread_self_restrict_tpro_to_rw(void)
{
    __asm__ __volatile__ (
                          "mov x0, %0\n"
                          "ldr x0, [x0]\n"
                          "msr s3_6_c15_c1_5, x0\n"
                          "isb sy\n"
                          :: "r" (_COMM_PAGE_TPRO_WRITE_ENABLE)
                          : "memory", "x0"
                          );
    return;
}

void os_thread_self_restrict_tpro_to_ro(void)
{
    __asm__ __volatile__ (
                          "mov x0, %0\n"
                          "ldr x0, [x0]\n"
                          "msr s3_6_c15_c1_5, x0\n"
                          "isb sy\n"
                          :: "r" (_COMM_PAGE_TPRO_WRITE_DISABLE)
                          : "memory", "x0"
                          );
    return;
}

// }

static void unprotect_page(void *page)
{
    if (mprotect(page, 0x4000, PROT_READ | PROT_WRITE) == 0) {
        return;
    }
    void *temp = malloc(0x4000);
    memcpy(temp, page, 0x4000);
    vm_deallocate(mach_task_self(), (vm_address_t)page, 0x4000);
    vm_allocate(mach_task_self(), (vm_address_t *)&page, 0x4000, VM_FLAGS_FIXED);
    memcpy(page, temp, 0x4000);
    free(temp);
}
#endif

/* Put our hook into the slot, chaining onto whatever was in it. */
static void mip_install_hook(void **slot, uintptr_t stored)
{
    uintptr_t raw = MIP_STRIP(stored);
    if (raw == mip_original_address) {
        /* Nobody hooked the slot yet: our hook calls the original itself. */
        __atomic_store_n(&mip_previous_getter, (mip_int64_getter_t)NULL, __ATOMIC_RELEASE);
    } else {
        /* Another chain hooked the slot: call its hook from ours, so both stay active. */
        __atomic_store_n(&mip_previous_getter, (mip_int64_getter_t)mip_sign_for_call((void *)raw), __ATOMIC_RELEASE);
    }

#if __arm64__
    bool has_tpro = os_tpro_is_supported();
    bool revert_tpro_state = false;
    if (!has_tpro) {
        unprotect_page((void *)(((uintptr_t)slot) & ~0x3FFF));
    }
    else if (!os_thread_self_tpro_is_writeable()) {
        os_thread_self_restrict_tpro_to_rw();
        revert_tpro_state = true;
    }
    *slot = ptrauth_sign_unauthenticated((void *)MIP_STRIP((uintptr_t)&xpc_dictionary_get_int64_hook),
                                         ptrauth_key_function_pointer, slot);
    if (revert_tpro_state) {
        os_thread_self_restrict_tpro_to_ro();
    }
#else
    *slot = (void *)&xpc_dictionary_get_int64_hook;
#endif

    os_log_info(MIP_log(), "hook installed in slot %{public}p, previous %{public}p",
                slot, (void *)raw);
}

/* Wait for a competing chain to take the slot, then chain onto it. */
static void *mip_delayed_install(void *unused)
{
    (void)unused;
    for (unsigned waited = 0; waited < MIP_HOOK_GRACE_US; waited += MIP_HOOK_POLL_US) {
        usleep(MIP_HOOK_POLL_US);
        uintptr_t stored = 0;
        void **slot = mip_find_hook_slot(&stored);
        if (!slot) continue;
        if (MIP_STRIP(stored) == mip_original_address) continue;
        os_log_info(MIP_log(), "competing hook found, chaining onto it");
        mip_install_hook(slot, stored);
        return NULL;
    }

    uintptr_t stored = 0;
    void **slot = mip_find_hook_slot(&stored);
    if (slot) {
        os_log_info(MIP_log(), "no competing hook, taking the slot");
        mip_install_hook(slot, stored);
    } else {
        os_log_error(MIP_log(), "no hook slot found");
    }
    return NULL;
}

static void __attribute__((constructor)) hook_lsd(void)
{
    void **start = NULL, **end = NULL;
    if (!mip_data_const_range(&start, &end)) {
        os_log_error(MIP_log(), "could not locate __DATA_CONST of the host process");
        return;
    }
    mip_slot_start = start;
    mip_slot_end = end;
    mip_original_address = MIP_STRIP((uintptr_t)&xpc_dictionary_get_int64);

    uintptr_t stored = 0;
    void **slot = mip_find_hook_slot(&stored);
    if (!slot) {
        os_log_error(MIP_log(), "could not locate the xpc_dictionary_get_int64 slot");
        return;
    }

    if (MIP_STRIP(stored) != mip_original_address) {
        os_log_info(MIP_log(), "slot already hooked, chaining onto it");
        mip_install_hook(slot, stored);
        return;
    }

    /* The slot is untouched. A competing chain may still be starting up, so wait for it
       instead of locking it out. */
    pthread_t thread;
    if (pthread_create(&thread, NULL, mip_delayed_install, NULL) == 0) {
        pthread_detach(thread);
    } else {
        mip_install_hook(slot, stored);
    }
}
