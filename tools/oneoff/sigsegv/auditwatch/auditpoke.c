/* auditpoke.c -- minimal audit netlink rule client (auditctl replacement).
 *
 * Purpose (SIGSEGV investigation, H2-1): install EXIT/ALWAYS audit rules for
 * the cross-process memory syscalls so every ptrace(117) /
 * process_vm_readv(270) / process_vm_writev(271) call by any instrumented
 * task is logged to kmsg as an audit(...) line.  The device kernel has
 * AUDIT=y + AUDITSYSCALL=y but no auditd/auditctl, so this tool speaks the
 * netlink protocol itself.  With no auditd registered, kauditd printk()s
 * every record (kernel/audit.c kauditd_hold_skb -> kauditd_printk_skb ->
 * pr_notice "type=%d ...") -- that is the on-device capture path.
 *
 * Wire format and semantics verified against the device kernel tree
 * _local/legacy/linux-5.15.134:
 *   - audit_receive_msg / audit_netlink_ok      kernel/audit.c (perm checks)
 *   - audit_rule_change / audit_data_to_entry   kernel/auditfilter.c
 *   - audit_to_entry_common: flags = listnr, mask = syscall bitmap, high
 *     mask bits are classes; AUDIT_POSSIBLE/AUDIT_FILTER_ENTRY deprecated
 *   - reply framing: audit_make_reply / audit_send_list_thread; LIST ends
 *     with NLMSG_DONE (audit_list_rules -> audit_make_reply(done=1))
 *
 * Critical enablement fact: audit contexts are allocated only at fork time
 * (kernel/fork.c copy_process -> audit_alloc) and only after audit has been
 * enabled once (audit_set_enabled sets audit_ever_enabled).  Tasks forked
 * before `auditpoke on` are NOT instrumented -- see README.
 *
 * Subcommands:
 *   on [1|0]      AUDIT_SET enabled (default 1). NEVER sends 2 (locked).
 *   off           AUDIT_SET enabled=0 (rules stay, records stop)
 *   status        AUDIT_GET: enabled/rate_limit/backlog/lost
 *   add [key]     add EXIT/ALWAYS rule: arch=AUDIT_ARCH_SELF,
 *                 syscall mask {ptrace, process_vm_readv, process_vm_writev},
 *                 filterkey (default "h21vm")
 *   addvm [key]   same but mask {process_vm_readv, process_vm_writev} only
 *                 (ptrace excluded: a resident daemon owns ptrace on the
 *                 target device and floods kmsg + the shared printk ratelimit)
 *   delvm [key]   delete the addvm rule (byte-identical buffer)
 *   list          AUDIT_LIST_RULES, decoded dump
 *   del [key]     delete the identical rule (byte-identical buffer)
 *   selftest      host-side layout assertions, no netlink use
 *
 * Exit codes: 0 ok / 1 usage / 2 kernel rejected (message printed) /
 *             3 netlink timeout / 4 local error.
 *
 * Build (device): zig cc -target aarch64-linux-musl -DAUDITPOKE_ARCH_AARCH64
 * Build (WSL smoke): zig cc -target x86_64-linux-musl -DAUDITPOKE_ARCH_X86_64
 * Build (host selftest, Windows-native): zig cc -target native \
 *     -DAUDITPOKE_ARCH_AARCH64 -DAUDITPOKE_HOST_SELFTEST auditpoke.c
 * (AUDITPOKE_HOST_SELFTEST compiles only the rule serializer + layout
 * assertions; no POSIX socket headers are included.)
 */
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>

#ifndef AUDITPOKE_HOST_SELFTEST
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/uio.h>
#endif

#include "audit_const.h"

#define RECV_TMO_SEC 5
#define RECVBUF 8192

static const char *g_key = "h21vm";

/* ---------------- rule serialization (shared by add/del/selftest) -------- */

/* Build the wire rule.  Byte-identical output for identical key => `del`
 * matches what `add` inserted (kernel compares parsed rules,
 * kernel/auditfilter.c audit_compare_rule). */
static size_t build_rule(struct audit_rule_x *r, const char *key, int vm_only)
{
    size_t klen = strlen(key);

    memset(r, 0, sizeof(*r));
    r->flags       = AUDIT_FILTER_EXIT;
    r->action      = AUDIT_ALWAYS;
    r->field_count = 2;

    /* field 0: arch == AUDIT_ARCH_SELF */
    r->fields[0]     = AUDIT_ARCH_F;
    r->values[0]     = AUDIT_ARCH_SELF;
    r->fieldflags[0] = AUDIT_EQUAL;

    /* field 1: filterkey (string packed in buf, value = length,
     * kernel/auditfilter.c audit_data_to_entry case AUDIT_FILTERKEY) */
    r->fields[1]     = AUDIT_FILTERKEY;
    r->values[1]     = (uint32_t)klen;
    r->fieldflags[1] = AUDIT_EQUAL;
    memcpy(r->buf, key, klen);
    r->buflen = (uint32_t)klen;

    /* syscall bitmap: plain syscall bits; bits >= 2048 are classes and are
     * left clear (audit_to_entry_common class expansion) */
    if (!vm_only)
        r->mask[AUDIT_WORD_(NR_PTRACE)]    |= AUDIT_BIT_(NR_PTRACE);
    r->mask[AUDIT_WORD_(NR_PROCESS_VM_RD)] |= AUDIT_BIT_(NR_PROCESS_VM_RD);
    r->mask[AUDIT_WORD_(NR_PROCESS_VM_WR)] |= AUDIT_BIT_(NR_PROCESS_VM_WR);

    return sizeof(*r) + NL_ALIGN(klen);
}

#ifndef AUDITPOKE_HOST_SELFTEST
/* ---------------- netlink plumbing --------------------------------------- */

struct nlsock {
    int fd;
    uint32_t seq;
};

static int nl_open(struct nlsock *n)
{
    struct timeval tv = { RECV_TMO_SEC, 0 };

    n->fd = socket(NL_AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_AUDIT);
    if (n->fd < 0)
        return -1;
    /* nl_pid=0: kernel assigns our portid; single-threaded client */
    struct nl_sockaddr sa;
    memset(&sa, 0, sizeof(sa));
    sa.nl_family = NL_AF_NETLINK;
    if (bind(n->fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(n->fd);
        n->fd = -1;
        return -1;
    }
    if (setsockopt(n->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
        close(n->fd);
        n->fd = -1;
        return -1;
    }
    n->seq = (uint32_t)getpid();
    return 0;
}

static void nl_close(struct nlsock *n) { if (n->fd >= 0) close(n->fd); }

/* send one request (nlmsghdr + payload); returns 0 / -1 */
static int nl_send(struct nlsock *n, uint16_t type, const void *payload,
                   size_t plen)
{
    unsigned char out[NL_HDRLEN + 2048];
    struct nl_hdr *h = (struct nl_hdr *)out;
    size_t total = NL_HDRLEN + NL_ALIGN(plen);

    if (total > sizeof(out)) {
        fprintf(stderr, "auditpoke: payload too large (%zu)\n", plen);
        return -1;
    }
    memset(out, 0, sizeof(out));
    h->nlmsg_len   = (uint32_t)total;
    h->nlmsg_type  = type;
    h->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    h->nlmsg_seq   = ++n->seq;
    h->nlmsg_pid   = 0;                       /* to kernel */
    if (plen)
        memcpy(out + NL_HDRLEN, payload, plen);

    struct nl_sockaddr dst;
    memset(&dst, 0, sizeof(dst));
    dst.nl_family = NL_AF_NETLINK;
    if (sendto(n->fd, out, total, 0, (struct sockaddr *)&dst, sizeof(dst)) < 0)
        return -1;
    return 0;
}

/* e is a positive errno as returned by nl_recv_one */
static const char *nl_errname(int e)
{
    switch (e) {
    case EPERM:          return "EPERM: no CAP_AUDIT_CONTROL (run as root in the initial pid namespace), or audit_enabled=LOCKED";
    case ECONNREFUSED:   return "ECONNREFUSED: caller not in init user namespace";
    case EEXIST:         return "EEXIST: rule already present (idempotent)";
    case ENOENT:         return "ENOENT: rule not present";
    case EINVAL:         return "EINVAL: kernel rejected the rule";
    case EOPNOTSUPP:     return "EOPNOTSUPP";
    case EBUSY:          return "EBUSY";
    default:             return strerror(e);
    }
}

/* wait for one message with matching seq; fills type/flags/data/len.
 * returns 0 ok / -1 timeout / errno>0 netlink error */
static int nl_recv_one(struct nlsock *n, uint16_t *type, uint16_t *flags,
                       unsigned char *data, size_t *dlen)
{
    unsigned char buf[RECVBUF];

    for (;;) {
        ssize_t r = recv(n->fd, buf, sizeof(buf), 0);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "auditpoke: recv: %s\n", strerror(errno));
            return -1;
        }
        struct nl_hdr *h = (struct nl_hdr *)buf;
        size_t rem = (size_t)r;
        if (rem < NL_HDRLEN || h->nlmsg_len < NL_HDRLEN || h->nlmsg_len > rem) {
            fprintf(stderr, "auditpoke: malformed netlink message\n");
            continue;
        }
        if (h->nlmsg_seq != n->seq)
            continue;                    /* stale message from another request */
        *type  = h->nlmsg_type;
        *flags = h->nlmsg_flags;
        if (h->nlmsg_type == NLMSG_ERROR) {
            if (h->nlmsg_len < NL_HDRLEN + sizeof(struct nl_err)) {
                fprintf(stderr, "auditpoke: short NLMSG_ERROR\n");
                continue;
            }
            struct nl_err *e = (struct nl_err *)(buf + NL_HDRLEN);
            if (e->error != 0)
                return -e->error;        /* positive errno returned */
            /* error==0 is the ACK: deliver as data len 0 */
            *dlen = 0;
            return 0;
        }
        *dlen = h->nlmsg_len - NL_HDRLEN;
        if (*dlen)
            memcpy(data, buf + NL_HDRLEN, *dlen);
        return 0;
    }
}

/* simple transaction: send + wait for the ACK; 0 ok / errno */
static int nl_txn(struct nlsock *n, uint16_t type, const void *payload,
                  size_t plen)
{
    uint16_t t, f;
    unsigned char data[512];
    size_t dl = sizeof(data);

    if (nl_send(n, type, payload, plen) < 0) {
        fprintf(stderr, "auditpoke: send(%u): %s\n", type, strerror(errno));
        return 4;
    }
    int rc = nl_recv_one(n, &t, &f, data, &dl);
    if (rc == -1)
        return 3;
    if (rc > 0) {
        fprintf(stderr, "auditpoke: kernel rejected %u: %s\n", type,
                nl_errname(rc));
        return 2;
    }
    return 0;
}

/* ---------------- decoding for `list` ------------------------------------ */

static const char *list_name(uint32_t flags)
{
    switch (flags & ~AUDIT_FILTER_PREPEND) {
    case AUDIT_FILTER_USER:    return "USER";
    case AUDIT_FILTER_TASK:    return "TASK";
    case AUDIT_FILTER_ENTRY:   return "ENTRY(deprecated)";
    case AUDIT_FILTER_EXIT:    return "EXIT";
    case AUDIT_FILTER_EXCLUDE: return "EXCLUDE";
    case AUDIT_FILTER_FS:      return "FS";
    default:                   return "?";
    }
}

static const char *action_name(uint32_t a)
{
    switch (a) {
    case AUDIT_NEVER:    return "NEVER";
    case AUDIT_POSSIBLE: return "POSSIBLE(deprecated)";
    case AUDIT_ALWAYS:   return "ALWAYS";
    default:             return "?";
    }
}

static const char *syscall_name(uint32_t nr)
{
    if (nr == (uint32_t)NR_PTRACE)        return " ptrace";
    if (nr == (uint32_t)NR_PROCESS_VM_RD) return " process_vm_readv";
    if (nr == (uint32_t)NR_PROCESS_VM_WR) return " process_vm_writev";
    return "";
}

static void print_rule(const struct audit_rule_x *r)
{
    printf("  list=%s action=%s fields=%u buflen=%u\n",
           list_name(r->flags), action_name(r->action), r->field_count,
           r->buflen);
    printf("    syscalls:");
    int shown = 0;
    for (uint32_t w = 0; w < AUDIT_BITMASK_SIZE && w * 32 < 2048; w++) {
        uint32_t v = r->mask[w];
        while (v) {
            int b = __builtin_ctz(v);
            uint32_t nr = w * 32 + (uint32_t)b;
            v &= ~(1u << b);
            printf(" %u%s", nr, syscall_name(nr));
            shown++;
        }
    }
    if (!shown)
        printf(" (all)");
    printf("\n");
    printf("    fields:");
    for (uint32_t i = 0; i < r->field_count && i < AUDIT_MAX_FIELDS; i++) {
        if (r->fields[i] == AUDIT_ARCH_F)
            printf(" arch=0x%x", r->values[i]);
        else if (r->fields[i] == AUDIT_FILTERKEY) {
            size_t off = 0;
            for (uint32_t j = 0; j < i; j++)
                if (r->fields[j] == AUDIT_FILTERKEY)
                    off += r->values[j];   /* only string fields consume buf */
            if (r->values[i] <= r->buflen && off + r->values[i] <= (size_t)r->buflen)
                printf(" key=\"%.*s\"", (int)r->values[i], r->buf + off);
            else
                printf(" key=<out-of-range %u>", r->values[i]);
        } else
            printf(" f%u(op=0x%x)=%u", r->fields[i], r->fieldflags[i],
                   r->values[i]);
    }
    printf("\n");
}

/* ---------------- subcommands -------------------------------------------- */

static int cmd_on(struct nlsock *n, int enable)
{
    struct audit_status_x s;
    memset(&s, 0, sizeof(s));
    s.mask    = AUDIT_STATUS_ENABLED;
    s.enabled = (uint32_t)enable;
    int rc = nl_txn(n, AUDIT_SET, &s, sizeof(s));
    if (rc == 0) {
        printf("audit enabled=%d\n", enable);
        if (enable)
            printf("NOTE: only tasks forked AFTER this moment get audit "
                   "contexts (audit_alloc at fork, audit_ever_enabled).\n"
                   "Long-running daemons are invisible until restarted.\n");
    }
    return rc;
}

static int cmd_status(struct nlsock *n)
{
    uint16_t t, f;
    unsigned char data[512];

    if (nl_send(n, AUDIT_GET, NULL, 0) < 0) {
        fprintf(stderr, "auditpoke: send: %s\n", strerror(errno));
        return 4;
    }
    /* the ACK (NLMSG_ERROR error=0) may precede the AUDIT_GET reply
     * (reply is unicast from a kthread); skip it */
    for (int i = 0; i < 4; i++) {
        size_t dl = sizeof(data);
        int rc = nl_recv_one(n, &t, &f, data, &dl);
        if (rc == -1)
            return 3;
        if (rc > 0) {
            fprintf(stderr, "auditpoke: AUDIT_GET failed: %s\n",
                    nl_errname(rc));
            return 2;
        }
        if (t != AUDIT_GET)
            continue;                    /* ACK or unrelated */
        if (dl < sizeof(struct audit_status_x)) {
            fprintf(stderr, "auditpoke: short AUDIT_GET reply (%zu)\n", dl);
            return 4;
        }
        struct audit_status_x *s = (struct audit_status_x *)data;
        const char *st = s->enabled == AUDIT_OFF_ ? "off" :
                         s->enabled == AUDIT_ON_ ? "on" :
                         s->enabled == AUDIT_LOCKED_ ? "LOCKED" : "?";
        printf("audit_enabled=%u (%s) rate_limit=%u backlog_limit=%u "
               "lost=%u backlog=%u\n",
               s->enabled, st, s->rate_limit, s->backlog_limit, s->lost,
               s->backlog);
        return 0;
    }
    fprintf(stderr, "auditpoke: no AUDIT_GET reply\n");
    return 3;
}

static int cmd_add(struct nlsock *n, int vm_only)
{
    struct audit_rule_x *r = malloc(sizeof(*r) + 256);
    if (!r)
        return 4;
    size_t total = build_rule(r, g_key, vm_only);
    int rc = nl_txn(n, AUDIT_ADD_RULE, r, total);
    if (rc == 0 && !vm_only)
        printf("rule added: list=EXIT action=ALWAYS arch=%s "
               "syscalls={%d ptrace, %d process_vm_readv, %d process_vm_writev} "
               "key=\"%s\"\n",
               ARCH_NAME, NR_PTRACE, NR_PROCESS_VM_RD, NR_PROCESS_VM_WR, g_key);
    if (rc == 0 && vm_only)
        printf("rule added: list=EXIT action=ALWAYS arch=%s "
               "syscalls={%d process_vm_readv, %d process_vm_writev} "
               "key=\"%s\"\n",
               ARCH_NAME, NR_PROCESS_VM_RD, NR_PROCESS_VM_WR, g_key);
    free(r);
    return rc;
}

static int cmd_del(struct nlsock *n, int vm_only)
{
    struct audit_rule_x *r = malloc(sizeof(*r) + 256);
    if (!r)
        return 4;
    size_t total = build_rule(r, g_key, vm_only);
    int rc = nl_txn(n, AUDIT_DEL_RULE, r, total);
    if (rc == 0)
        printf("rule deleted (vm_only=%d key=\"%s\")\n", vm_only, g_key);
    free(r);
    return rc;
}

static int cmd_list(struct nlsock *n)
{
    if (nl_send(n, AUDIT_LIST_RULES, NULL, 0) < 0) {
        fprintf(stderr, "auditpoke: send: %s\n", strerror(errno));
        return 4;
    }
    int count = 0;
    for (;;) {
        uint16_t t, f;
        unsigned char data[2048];
        size_t dl = sizeof(data);
        int rc = nl_recv_one(n, &t, &f, data, &dl);
        if (rc == -1)
            return 3;
        if (rc > 0) {
            fprintf(stderr, "auditpoke: AUDIT_LIST_RULES failed: %s\n",
                    nl_errname(rc));
            return 2;
        }
        if (t == NLMSG_DONE) {
            printf("%d rule(s)\n", count);
            return 0;
        }
        if (t == NLMSG_ERROR) {
            /* plain success ACK (error==0 handled in nl_recv_one): the list
             * kthread unicasts rules only after the ACK, so keep reading */
            continue;
        }
        if (t == AUDIT_LIST_RULES && dl >= sizeof(struct audit_rule_x)) {
            printf("[%d]", count);
            print_rule((struct audit_rule_x *)data);
            count++;
        }
    }
}

#endif /* !AUDITPOKE_HOST_SELFTEST */

/* ---------------- host selftest (no netlink) ----------------------------- */

static int expect(int cond, const char *what)
{
    printf("  %-52s %s\n", what, cond ? "PASS" : "FAIL");
    return cond ? 0 : 1;
}

static int cmd_selftest(void)
{
    int bad = 0;
    struct audit_rule_x *r = malloc(sizeof(*r) + 256);
    size_t total = build_rule(r, g_key, 0);

    printf("auditpoke selftest (" ARCH_NAME ", key=\"%s\"):\n", g_key);
    bad += expect(sizeof(struct nl_hdr) == 16, "sizeof(nlmsghdr) == 16");
    bad += expect(offsetof(struct nl_hdr, nlmsg_seq) == 8, "nlmsghdr.seq offset == 8");
    bad += expect(sizeof(struct audit_rule_x) == 1040, "sizeof(audit_rule_data) == 1040");
    bad += expect(offsetof(struct audit_rule_x, mask) == 12, "audit_rule_data.mask offset == 12");
    bad += expect(offsetof(struct audit_rule_x, fields) == 268, "audit_rule_data.fields offset == 268");
    bad += expect(offsetof(struct audit_rule_x, values) == 524, "audit_rule_data.values offset == 524");
    bad += expect(offsetof(struct audit_rule_x, fieldflags) == 780, "audit_rule_data.fieldflags offset == 780");
    bad += expect(offsetof(struct audit_rule_x, buflen) == 1036, "audit_rule_data.buflen offset == 1036");
    bad += expect(r->flags == AUDIT_FILTER_EXIT && r->action == AUDIT_ALWAYS,
                  "flags=EXIT action=ALWAYS");
    bad += expect(r->field_count == 2, "field_count == 2 (arch + filterkey)");
    bad += expect(r->fields[0] == AUDIT_ARCH_F &&
                  r->values[0] == AUDIT_ARCH_SELF &&
                  r->fieldflags[0] == AUDIT_EQUAL,
                  "field0: arch == AUDIT_ARCH_SELF, op == EQUAL");
    /* mask: exactly our three syscall bits in words < 64 */
    {
        uint32_t want[AUDIT_BITMASK_SIZE] = {0};
        want[AUDIT_WORD_(NR_PTRACE)]        |= AUDIT_BIT_(NR_PTRACE);
        want[AUDIT_WORD_(NR_PROCESS_VM_RD)] |= AUDIT_BIT_(NR_PROCESS_VM_RD);
        want[AUDIT_WORD_(NR_PROCESS_VM_WR)] |= AUDIT_BIT_(NR_PROCESS_VM_WR);
        int ok = memcmp(want, r->mask, sizeof(want)) == 0;
        bad += expect(ok, "mask == {ptrace,process_vm_readv,process_vm_writev}");
        /* decode round-trip */
        int found = 0;
        for (uint32_t w = 0; w < AUDIT_BITMASK_SIZE; w++) {
            uint32_t v = want[w];
            while (v) {
                int b = __builtin_ctz(v);
                v &= ~(1u << b);
                if ((uint32_t)NR_PTRACE == w * 32 + b ||
                    (uint32_t)NR_PROCESS_VM_RD == w * 32 + b ||
                    (uint32_t)NR_PROCESS_VM_WR == w * 32 + b)
                    found++;
            }
        }
        bad += expect(found == 3, "mask decode round-trip finds 3 syscalls");
    }
    bad += expect(r->values[1] == strlen(g_key) &&
                  r->buflen == strlen(g_key) &&
                  memcmp(r->buf, g_key, strlen(g_key)) == 0,
                  "filterkey packed in buf, value == buflen == keylen");
    bad += expect(total == sizeof(*r) + NL_ALIGN(strlen(g_key)),
                  "wire length == 1040 + align(keylen)");
    free(r);
    printf("%s: %d failure(s)\n", bad ? "SELFTEST FAIL" : "SELFTEST PASS", bad);
    return bad ? 4 : 0;
}

/* ---------------- main ---------------------------------------------------- */

static void usage(void)
{
    fprintf(stderr,
        "usage: auditpoke <cmd> [arg]\n"
        "  on [1|0]     enable/disable audit (AUDIT_SET enabled)\n"
        "  off          disable audit (rules stay)\n"
        "  status       AUDIT_GET status\n"
        "  add [key]    add EXIT/ALWAYS rule for ptrace/process_vm_* (key default h21vm)\n"
        "  addvm [key]  same but ptrace excluded (mask 270/271 only)\n"
        "  list         list all rules\n"
        "  del [key]    delete our 3-syscall rule (key default h21vm)\n"
        "  delvm [key]  delete our 270/271-only rule (key default h21vm)\n"
        "  selftest     host layout assertions, no netlink\n");
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        usage();
        return 1;
    }
    if (strcmp(argv[1], "selftest") == 0)
        return cmd_selftest();
#ifdef AUDITPOKE_HOST_SELFTEST
    fprintf(stderr, "auditpoke: host-selftest build supports only `selftest`\n");
    return 1;
#else
    struct nlsock n;
    if (nl_open(&n) < 0) {
        fprintf(stderr, "auditpoke: NETLINK_AUDIT socket: %s "
                "(kernel without CONFIG_AUDIT?)\n", strerror(errno));
        return 4;
    }
    int rc;
    if (strcmp(argv[1], "on") == 0) {
        int en = (argc >= 3) ? atoi(argv[2]) : 1;
        if (en < 0 || en > 1) {
            fprintf(stderr, "auditpoke: refusing enabled=%d "
                    "(2=LOCKED is irreversible until reboot)\n", en);
            nl_close(&n);
            return 1;
        }
        rc = cmd_on(&n, en);
    } else if (strcmp(argv[1], "off") == 0) {
        rc = cmd_on(&n, 0);
    } else if (strcmp(argv[1], "status") == 0) {
        rc = cmd_status(&n);
    } else if (strcmp(argv[1], "add") == 0) {
        if (argc >= 3)
            g_key = argv[2];
        rc = cmd_add(&n, 0);
    } else if (strcmp(argv[1], "addvm") == 0) {
        if (argc >= 3)
            g_key = argv[2];
        rc = cmd_add(&n, 1);
    } else if (strcmp(argv[1], "del") == 0) {
        if (argc >= 3)
            g_key = argv[2];
        rc = cmd_del(&n, 0);
    } else if (strcmp(argv[1], "delvm") == 0) {
        if (argc >= 3)
            g_key = argv[2];
        rc = cmd_del(&n, 1);
    } else if (strcmp(argv[1], "list") == 0) {
        rc = cmd_list(&n);
    } else {
        usage();
        rc = 1;
    }
    nl_close(&n);
    return rc;
#endif /* !AUDITPOKE_HOST_SELFTEST */
}
