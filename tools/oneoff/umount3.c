#include <sys/mount.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    return umount2(argv[1], MNT_DETACH) == 0 ? 0 : 1;
}
