/* fhled_ctl.c v1.1 -- LG6151M LED control, full vendor sequence.
 * RE basis (subagent 2026-10-04): libled_interface fh_gpio_write does
 * get_pin_index -> config_mux_index(0) -> set_mode_index(1) -> write_index.
 * Writing without mux leaves the pad in alternate function -> no light.
 * LED GPIOs are ACTIVE-LOW (0 = lit), power LED id15 already lit by bootloader.
 * Usage: fhled_ctl on|off <list_idx>   (idx per /proc/driver/fh_bsp_gpio_list)
 *        fhled_ctl g <gpio> <0|1>     (raw gpio, mode+write only)
 *        fhled_ctl r <list_idx>       (read via index)
 * idx map (this board): 6=WIFI 14=VOIP/WAN 45=POWER 62=5G_G 63=5G_B
 *                       64=4G_R 65=4G_G 66=4G_B 67=PWR_R
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define IOC_MUX_IDX   0x400c5305  /* _IOW('S',5,12) {idx,mux,dbg}  */
#define IOC_MODE_IDX  0x400c5306  /* _IOW('S',6,12) {idx,mode,dbg} */
#define IOC_WRITE_IDX 0x400c5308  /* _IOW('S',8,12) {idx,val,dbg}  */
#define IOC_READ_IDX  0xc00c5309  /* _IOWR('S',9,12) val->+4       */
#define IOC_PIN_IDX   0xc00c530a  /* _IOWR('S',10,12) pin->+4      */
#define IOC_MUX       0x400c5300  /* raw variants */
#define IOC_MODE      0x400c5301
#define IOC_WRITE     0x400c5303

struct fh_arg { unsigned int id; unsigned char val; unsigned char dbg; unsigned char pad[6]; };

static int fd;

static void seq_idx(unsigned idx, unsigned char lit)
{
    struct fh_arg a;
    memset(&a, 0, sizeof a); a.id = idx; a.dbg = 1;
    if (ioctl(fd, IOC_PIN_IDX, &a))            { printf("pin_idx(%u) err\n", idx); return; }
    unsigned pin = a.val | (a.pad[0] << 8);
    memset(&a, 0, sizeof a); a.id = idx; a.dbg = 1;
    ioctl(fd, IOC_MUX_IDX, &a);                                   /* pad -> GPIO */
    memset(&a, 0, sizeof a); a.id = idx; a.val = 1; a.dbg = 1;
    ioctl(fd, IOC_MODE_IDX, &a);                                  /* output */
    memset(&a, 0, sizeof a); a.id = idx; a.val = lit; a.dbg = 1;   /* 0 = lit (active low) */
    int rc = ioctl(fd, IOC_WRITE_IDX, &a);
    printf("idx %u (pin %u) <- %u : %s\n", idx, pin, lit, rc ? "WRITE ERR" : "ok");
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s on|off <idx> | g <gpio> <0|1> | r <idx>\n", argv[0]);
        return 1;
    }
    fd = open("/dev/fhdrv_kdrv_board", O_RDWR);
    if (fd < 0) { perror("open"); return 2; }
    if (!strcmp(argv[1], "r")) {
        struct fh_arg a; memset(&a, 0, sizeof a); a.id = atoi(argv[2]); a.dbg = 1;
        if (!ioctl(fd, IOC_READ_IDX, &a)) printf("idx %u = %u\n", a.id, a.val);
        else printf("read err\n");
    } else if (!strcmp(argv[1], "g")) {
        struct fh_arg a; memset(&a, 0, sizeof a); a.id = atoi(argv[2]); a.dbg = 1;
        ioctl(fd, IOC_MUX,   &a);
        memset(&a, 0, sizeof a); a.id = atoi(argv[2]); a.val = 1; a.dbg = 1;
        ioctl(fd, IOC_MODE,  &a);
        memset(&a, 0, sizeof a); a.id = atoi(argv[2]); a.val = atoi(argv[3]); a.dbg = 1;
        printf(ioctl(fd, IOC_WRITE, &a) ? "WRITE ERR\n" : "ok\n");
    } else {
        seq_idx(atoi(argv[2]), !strcmp(argv[1], "on") ? 0 : 1);
    }
    close(fd);
    return 0;
}
