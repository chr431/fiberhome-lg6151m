/* p0chk.h -- va_list integrity checkpoints for the printf stack (P0).
 *
 * Never take &ap of a register-resident va_list: on aarch64 every va_list here
 * is already a struct in memory (a pointer parameter, or an array local), so
 * reading its words through a plain pointer is exact.
 *
 * aarch64 AAPCS64 layout: +0 __stack, +8 __gr_top, +16 __vr_top,
 * +24 __gr_offs (int), +28 __vr_offs (int).
 */
#ifndef P0CHK_H
#define P0CHK_H
void p0fail(const char *tag, const void *obj, unsigned long stack,
    unsigned long grtop, int groffs, unsigned long n);
extern unsigned long g_chk_n;

#define CHK(tag, p) do { \
	const volatile unsigned long *__w = \
	    (const volatile unsigned long *)(p); \
	unsigned long __s = __w[0], __t = __w[1]; \
	int __o = (int)(unsigned)__w[3]; \
	g_chk_n++; \
	if (__t < 0x100000000UL || __s < 0x100000000UL || __o >= 0) \
		p0fail((tag), (p), __s, __t, __o, g_chk_n); \
} while (0)
#endif
