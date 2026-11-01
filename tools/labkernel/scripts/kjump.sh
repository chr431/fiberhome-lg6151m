#!/bin/sh
# kjump -- kexec helper for kernel-to-kernel jumps (V5 reserve).
# Kernel side is ready: CONFIG_KEXEC=y, CONFIG_KEXEC_FILE=y (see /proc/config.gz).
# Userland honesty: this initramfs does NOT bundle a kexec binary -- kexec-tools
# was not cross-built for this release. Stage one to use this helper:
#   /bin/netup  # 169.254/16 channel, busybox tftp/httpd on both ends
#   (transfer a static aarch64 kexec to /bin/kexec; chmod 755)
#   kjump /tmp/Image.new "console=ttyS0,921600n1 init=/init"
if [ ! -x /bin/kexec ]; then
    echo "kjump: /bin/kexec not present (kexec-tools not bundled; kernel CONFIG_KEXEC=y is ready)"
    echo "kjump: stage a static aarch64 kexec binary first (netup + tftp/httpd), then retry"
    exit 1
fi
if [ -z "${1:-}" ]; then
    echo "usage: kjump <kernel-image> [cmdline]"
    exit 2
fi
K="$1"
C="${2:-console=ttyS0,921600n1 init=/init}"
echo "kjump: loading $K (cmdline: $C)"
/bin/kexec -l "$K" --command-line="$C" || exit 3
echo "kjump: loaded; executing jump -- console may glitch"
sync
/bin/kexec -e
