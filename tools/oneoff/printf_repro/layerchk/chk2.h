#ifndef CHK2_H
#define CHK2_H
/* hand-off tracer: vsnprintf records the va_list object it passes on; vfprintf
 * compares the same object at entry.  Distinguishes "the object was written"
 * from "the callee got a different object" (aarch64 passes the 32-byte
 * va_list by invisible reference, so a callee-side copy is possible). */
extern unsigned long g_src[6];	/* 0 address, 1..4 words */
void p0rpt(const char *tag, unsigned long a, unsigned long b, unsigned long c,
    unsigned long d, unsigned long e);
#endif
