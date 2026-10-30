#include <sys/resource.h>
int main(void){ struct rlimit rl = { RLIM_INFINITY, RLIM_INFINITY }; setrlimit(RLIMIT_CORE, &rl); *(volatile int*)0 = 1; return 0; }
