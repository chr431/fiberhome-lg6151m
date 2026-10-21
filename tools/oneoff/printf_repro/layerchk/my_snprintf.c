#include <stdio.h>
#include <stdarg.h>
#include "p0chk.h"

int snprintf(char *restrict s, size_t n, const char *restrict fmt, ...)
{
	int ret;
	va_list ap;
	va_start(ap, fmt);
	CHK("snprintf.entry", &ap);
	ret = vsnprintf(s, n, fmt, ap);
	CHK("snprintf.after", &ap);
	va_end(ap);
	return ret;
}

