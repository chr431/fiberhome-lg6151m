/* audit_const.h -- constants and wire layouts for the audit netlink tools.
 *
 * Every value below was transcribed by hand from the DEVICE KERNEL TREE at
 * _local/legacy/linux-5.15.134 (kernel 5.15.134, matches the LG6151M device),
 * NOT from any host/Windows or target-libc header.  Each constant cites its
 * source file.  If the device kernel is ever rebased, re-verify against the
 * new tree before using these tools.
 *
 * Used by: auditpoke.c (rule client), vmpoke.c (positive control),
 *          test selftest path.  Neutral naming only.
 */
#ifndef AUDIT_CONST_H
#define AUDIT_CONST_H

#include <stdint.h>

/* ============ netlink core -- include/uapi/linux/netlink.h ============ */
#define NL_AF_NETLINK      16           /* AF_NETLINK (include/linux/socket.h) */
#define NLMSG_ERROR        0x2          /* netlink.h:104 */
#define NLMSG_DONE         0x3          /* netlink.h:105 */
#define NLM_F_REQUEST      0x01         /* netlink.h:54 */
#define NLM_F_MULTI        0x02         /* netlink.h:55 */
#define NLM_F_ACK          0x04         /* netlink.h:56 */
#define NETLINK_AUDIT      9            /* netlink.h:18 */

struct nl_hdr {                        /* netlink.h:44, 16 bytes */
    uint32_t nlmsg_len;
    uint16_t nlmsg_type;
    uint16_t nlmsg_flags;
    uint32_t nlmsg_seq;
    uint32_t nlmsg_pid;
};

struct nl_sockaddr {                   /* netlink.h:37 */
    uint16_t nl_family;
    uint16_t nl_pad;
    uint32_t nl_pid;
    uint32_t nl_groups;
};

struct nl_err {                        /* netlink.h:~109 */
    int32_t  error;
    struct nl_hdr msg;
};

#define NL_ALIGN(len)     (((len) + 3u) & ~3u)   /* NLMSG_ALIGN (netlink.h:89) */
#define NL_HDRLEN         16u                     /* NLMSG_HDRLEN (netlink.h:91) */

/* ============ audit subsystem -- include/uapi/linux/audit.h ============ */
#define AUDIT_GET          1000        /* audit.h:54 */
#define AUDIT_SET          1001        /* audit.h:55 */
#define AUDIT_ADD_RULE     1011        /* audit.h:65 */
#define AUDIT_DEL_RULE     1012        /* audit.h:66 */
#define AUDIT_LIST_RULES   1013        /* audit.h:67 */

#define AUDIT_SYSCALL_REC  1300        /* audit.h:87  AUDIT_SYSCALL record type */
#define AUDIT_CONFIG_CHANGE 1305       /* audit.h:92 */

#define AUDIT_FILTER_USER    0x00      /* audit.h:161 */
#define AUDIT_FILTER_TASK    0x01      /* audit.h:162 */
#define AUDIT_FILTER_ENTRY   0x02      /* audit.h:163 (deprecated in-kernel) */
#define AUDIT_FILTER_EXIT    0x04      /* audit.h:165 */
#define AUDIT_FILTER_EXCLUDE 0x05      /* audit.h:166 */
#define AUDIT_FILTER_FS      0x06      /* audit.h:167 */
#define AUDIT_FILTER_PREPEND 0x10      /* audit.h:~171 (AUDIT_FILTER_PREPEND) */

#define AUDIT_NEVER    0               /* audit.h:176 */
#define AUDIT_POSSIBLE 1               /* audit.h:177 (deprecated in-kernel) */
#define AUDIT_ALWAYS   2               /* audit.h:177/181 */

#define AUDIT_BITMASK_SIZE 64          /* audit.h:183 */
#define AUDIT_MAX_FIELDS   64          /* audit.h:181 */
#define AUDIT_WORD_(nr)    ((uint32_t)((nr) / 32))  /* audit.h:184 AUDIT_WORD */
#define AUDIT_BIT_(nr)     (1u << ((nr) - AUDIT_WORD_(nr) * 32)) /* audit.h:185 */

/* rule field types -- audit.h:~230..294 */
#define AUDIT_ARCH_F       11          /* audit.h:255 AUDIT_ARCH field */
#define AUDIT_FILTERKEY    210         /* audit.h:294 */

/* rule field operators -- audit.h:~313..321 (top bits of fieldflags) */
#define AUDIT_EQUAL        0x40000000u /* audit.h:317 */

/* arch tokens -- audit.h:380..383 + elf-em.h */
#define AUDIT_ARCH_64BIT   0x80000000u /* audit.h:380 __AUDIT_ARCH_64BIT */
#define AUDIT_ARCH_LE      0x40000000u /* audit.h:381 __AUDIT_ARCH_LE */
#define AUDIT_ARCH_AARCH64 0xC00000B7u /* audit.h:383: EM_AARCH64(183, elf-em.h:46)|64BIT|LE */
#define AUDIT_ARCH_X86_64  0xC000003Eu /* audit.h:~401: EM_X86_64(62, elf-em.h:31)|64BIT|LE */

/* AUDIT_SET/AUDIT_GET status -- audit.h:~325..360 */
#define AUDIT_STATUS_ENABLED 0x0001    /* audit.h:337 */

/* audit_enabled states -- include/linux/audit.h:150..152 (kernel internal;
 * accepted by AUDIT_SET through audit_set_enabled(), audit.c) */
#define AUDIT_OFF_    0
#define AUDIT_ON_     1
#define AUDIT_LOCKED_ 2   /* NEVER send: irreversible until reboot */

/* struct audit_status -- audit.h:~325 (11 fixed u32 + union + 2 u32) */
struct audit_status_x {
    uint32_t mask;
    uint32_t enabled;
    uint32_t failure;
    uint32_t pid;
    uint32_t rate_limit;
    uint32_t backlog_limit;
    uint32_t lost;
    uint32_t backlog;
    union {
        uint32_t version;
        uint32_t feature_bitmap;
    } u;
    uint32_t backlog_wait_time;
    uint32_t backlog_wait_time_actual;
};

/* struct audit_rule_data -- audit.h:503..515 (1040 bytes + buf) */
struct audit_rule_x {
    uint32_t flags;                    /* listnr | AUDIT_FILTER_PREPEND */
    uint32_t action;                   /* AUDIT_NEVER/POSSIBLE/ALWAYS */
    uint32_t field_count;
    uint32_t mask[AUDIT_BITMASK_SIZE]; /* syscall bitmap; bits >=2048 are classes */
    uint32_t fields[AUDIT_MAX_FIELDS];
    uint32_t values[AUDIT_MAX_FIELDS];
    uint32_t fieldflags[AUDIT_MAX_FIELDS];
    uint32_t buflen;                   /* total string-field bytes in buf[] */
    char     buf[0];
};

/* ============ syscall numbers ============ */
/* aarch64 (asm-generic unistd): _local/legacy/linux-5.15.134/
 *   include/uapi/asm-generic/unistd.h:385  __NR_ptrace            117
 *   include/uapi/asm-generic/unistd.h:729  __NR_process_vm_readv  270
 *   include/uapi/asm-generic/unistd.h:731  __NR_process_vm_writev 271 */
/* x86_64 (syscall table): _local/legacy/linux-5.15.134/
 *   arch/x86/entry/syscalls/syscall_64.tbl:112/321/322
 *   ptrace 101, process_vm_readv 310, process_vm_writev 311 */
#if defined(AUDITPOKE_ARCH_AARCH64)
#  define NR_SYSCALL_BASE   0
#  define NR_PTRACE          117
#  define NR_PROCESS_VM_RD   270
#  define NR_PROCESS_VM_WR   271
#  define AUDIT_ARCH_SELF    AUDIT_ARCH_AARCH64
#  define ARCH_NAME          "aarch64"
#elif defined(AUDITPOKE_ARCH_X86_64)
#  define NR_SYSCALL_BASE   0
#  define NR_PTRACE          101
#  define NR_PROCESS_VM_RD   310
#  define NR_PROCESS_VM_WR   311
#  define AUDIT_ARCH_SELF    AUDIT_ARCH_X86_64
#  define ARCH_NAME          "x86_64"
#else
#  error "define AUDITPOKE_ARCH_AARCH64 or AUDITPOKE_ARCH_X86_64"
#endif

/* ============ ptrace requests -- include/uapi/linux/ptrace.h:11..28 ============ */
/* aarch64 uses the generic set (no GETREGS/SETREGS; GETREGSET/SETREGSET instead) */
#define PT_PEEKDATA   2        /* ptrace.h:13 */
#define PT_POKEDATA   5        /* ptrace.h:16 */
#define PT_ATTACH     16       /* ptrace.h:22 */
#define PT_DETACH     17       /* ptrace.h:23 */
#define PT_GETREGSET  0x4204   /* ptrace.h:50 */
#define PT_SETREGSET  0x4205   /* ptrace.h:51 */

#endif /* AUDIT_CONST_H */
