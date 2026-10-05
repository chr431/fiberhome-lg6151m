/* wpapmk.c v1.0 -- WPA passphrase -> PMK (PBKDF2-HMAC-SHA1, 4096 iters)
 * 原厂魔改 hostapd 的 wpa_passphrase 会过 libfhcrypto 解密(明文进=乱码出),
 * 只能用 wpa_psk 原始 PMK 喂它。设备无 python/openssl, 自带纯C实现。
 * 用法: wpapmk <ssid> <passphrase>  -> stdout 64 hex chars
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

typedef struct { uint32_t h[5]; uint64_t len; uint8_t buf[64]; size_t bl; } sha1_t;

static uint32_t rol(uint32_t v, int s) { return (v << s) | (v >> (32 - s)); }

static void sha1_init(sha1_t *c) {
    c->h[0]=0x67452301; c->h[1]=0xEFCDAB89; c->h[2]=0x98BADCFE;
    c->h[3]=0x10325476; c->h[4]=0xC3D2E1F0; c->len=0; c->bl=0;
}

static void sha1_block(sha1_t *c, const uint8_t *p) {
    uint32_t w[80], a,b,cc,d,e,f,k,t; int i;
    for (i=0;i<16;i++) w[i]=((uint32_t)p[i*4]<<24)|((uint32_t)p[i*4+1]<<16)|((uint32_t)p[i*4+2]<<8)|p[i*4+3];
    for (;i<80;i++) w[i]=rol(w[i-3]^w[i-8]^w[i-14]^w[i-16],1);
    a=c->h[0];b=c->h[1];cc=c->h[2];d=c->h[3];e=c->h[4];
    for (i=0;i<80;i++){
        if(i<20){f=(b&cc)|((~b)&d);k=0x5A827999;}
        else if(i<40){f=b^cc^d;k=0x6ED9EBA1;}
        else if(i<60){f=(b&cc)|(b&d)|(cc&d);k=0x8F1BBCDC;}
        else {f=b^cc^d;k=0xCA62C1D6;}
        t=rol(a,5)+f+e+k+w[i]; e=d; d=cc; cc=rol(b,30); b=a; a=t;
    }
    c->h[0]+=a;c->h[1]+=b;c->h[2]+=cc;c->h[3]+=d;c->h[4]+=e;
}

static void sha1_update(sha1_t *c, const uint8_t *d, size_t n) {
    c->len += n;
    while (n) {
        size_t k = 64 - c->bl; if (k > n) k = n;
        memcpy(c->buf + c->bl, d, k);
        c->bl += k; d += k; n -= k;
        if (c->bl == 64) { sha1_block(c, c->buf); c->bl = 0; }
    }
}

/* HMAC + PBKDF2 收尾 */
static void sha1_done(sha1_t *c, uint8_t out[20]) {
    uint64_t bits = c->len * 8;
    uint8_t b1 = 0x80, b0 = 0;
    sha1_update(c, &b1, 1);
    while (c->bl != 56) sha1_update(c, &b0, 1);
    for (int i = 0; i < 8; i++) { uint8_t v = (uint8_t)(bits >> (56 - 8*i)); sha1_update(c, &v, 1); }
    for (int i = 0; i < 5; i++) {
        out[i*4]   = (uint8_t)(c->h[i] >> 24);
        out[i*4+1] = (uint8_t)(c->h[i] >> 16);
        out[i*4+2] = (uint8_t)(c->h[i] >> 8);
        out[i*4+3] = (uint8_t)(c->h[i]);
    }
}

static void hmac_sha1(const uint8_t *key, size_t kl,
                      const uint8_t *msg, size_t ml, uint8_t out[20]) {
    uint8_t k[64], ipad[64], opad[64], ih[20];
    sha1_t c;
    memset(k, 0, 64);
    if (kl > 64) {                 /* >64B key: 先散列(口令场景不会出现) */
        sha1_init(&c); sha1_update(&c, key, kl); sha1_done(&c, k);
    } else memcpy(k, key, kl);
    for (int i = 0; i < 64; i++) { ipad[i]=k[i]^0x36; opad[i]=k[i]^0x5c; }
    sha1_init(&c); sha1_update(&c, ipad, 64); sha1_update(&c, msg, ml); sha1_done(&c, ih);
    sha1_init(&c); sha1_update(&c, opad, 64); sha1_update(&c, ih, 20); sha1_done(&c, out);
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: wpapmk <ssid> <pass>\n"); return 2; }
    const char *ssid = argv[1], *pass = argv[2];
    size_t sl = strlen(ssid), pl = strlen(pass);
    if (pl < 8 || pl > 63) { fprintf(stderr, "pass len must be 8..63\n"); return 3; }

    uint8_t salt[4 + 256];
    memcpy(salt, ssid, sl);
    salt[sl]=0; salt[sl+1]=0; salt[sl+2]=0; salt[sl+3]=1;   /* INT(1) BE */

    uint8_t U[20], T[20], dk[40];
    hmac_sha1((const uint8_t*)pass, pl, salt, sl + 4, T);   /* U_1 */
    memcpy(U, T, 20);
    for (int iter = 1; iter < 4096; iter++) {
        hmac_sha1((const uint8_t*)pass, pl, U, 20, U);
        for (int i = 0; i < 20; i++) T[i] ^= U[i];
    }
    memcpy(dk, T, 20);                                       /* c=1 block 即 32B? 不: 需2块 */
    uint8_t T2[20], U2[20];
    salt[sl+3]=2;
    hmac_sha1((const uint8_t*)pass, pl, salt, sl + 4, T2);
    memcpy(U2, T2, 20);
    for (int iter = 1; iter < 4096; iter++) {
        hmac_sha1((const uint8_t*)pass, pl, U2, 20, U2);
        for (int i = 0; i < 20; i++) T2[i] ^= U2[i];
    }
    memcpy(dk + 20, T2, 20);

    for (int i = 0; i < 32; i++) printf("%02x", dk[i]);
    printf("\n");
    return 0;
}
