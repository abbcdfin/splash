/*
 * drm-splash - Display a static splash image via DRM dumb buffer.
 *
 * Loads a raw SPLR pixel file, sets a DRM mode, and holds the display
 * until receiving SIGTERM (at which point it exits cleanly so the next
 * process can acquire DRM master).
 *
 * SPLR raw format:
 *   bytes  0-3  : magic "SPLR"
 *   bytes  4-7  : uint32_t width  (little-endian)
 *   bytes  8-11 : uint32_t height (little-endian)
 *   bytes 12+   : width*height XRGB8888 pixels, row-major
 *                 (in memory: B G R X, 4 bytes per pixel)
 *
 * Usage:
 *   drm-splash [OPTIONS] <image.splr>
 *
 * Options:
 *   -d <device>   DRM device (default: /dev/dri/card0)
 *   -c <index>    connector index (default: 0 = first connected)
 *   -h            show this help
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define SPLR_MAGIC      "SPLR"
#define SPLR_MAGIC_LEN  4
#define SPLR_HEADER_LEN 12  /* magic(4) + width(4) + height(4) */

static volatile sig_atomic_t g_terminate = 0;

static void sig_handler(int signo)
{
    (void)signo;
    g_terminate = 1;
}

/* ------------------------------------------------------------------ */

typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t *pixels;   /* XRGB8888, row-major, caller owns */
} SplrImage;

static int splr_load(const char *path, SplrImage *out)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return -1;
    }

    uint8_t hdr[SPLR_HEADER_LEN];
    if (fread(hdr, 1, SPLR_HEADER_LEN, f) != SPLR_HEADER_LEN) {
        fprintf(stderr, "%s: truncated header\n", path);
        fclose(f);
        return -1;
    }

    if (memcmp(hdr, SPLR_MAGIC, SPLR_MAGIC_LEN) != 0) {
        fprintf(stderr, "%s: not a SPLR file\n", path);
        fclose(f);
        return -1;
    }

    out->width  = (uint32_t)hdr[4]  | ((uint32_t)hdr[5]  << 8) |
                  ((uint32_t)hdr[6] << 16) | ((uint32_t)hdr[7] << 24);
    out->height = (uint32_t)hdr[8]  | ((uint32_t)hdr[9]  << 8) |
                  ((uint32_t)hdr[10] << 16) | ((uint32_t)hdr[11] << 24);

    if (out->width == 0 || out->height == 0 ||
        out->width > 8192 || out->height > 8192) {
        fprintf(stderr, "%s: invalid dimensions %ux%u\n",
                path, out->width, out->height);
        fclose(f);
        return -1;
    }

    size_t pixel_bytes = (size_t)out->width * out->height * 4;
    out->pixels = malloc(pixel_bytes);
    if (!out->pixels) {
        fprintf(stderr, "out of memory (%zu bytes)\n", pixel_bytes);
        fclose(f);
        return -1;
    }

    if (fread(out->pixels, 1, pixel_bytes, f) != pixel_bytes) {
        fprintf(stderr, "%s: truncated pixel data\n", path);
        free(out->pixels);
        fclose(f);
        return -1;
    }

    fclose(f);
    return 0;
}

/* ------------------------------------------------------------------ */
/* BMP loading (24-bit and 32-bit, bottom-up and top-down)             */
/* Output pixels are XRGB8888 (B G R X in memory), same as SPLR.      */
/* ------------------------------------------------------------------ */

static uint16_t bmp_le16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t bmp_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int bmp_load(const char *path, SplrImage *out)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return -1;
    }

    /* File header: 14 bytes */
    uint8_t fhdr[14];
    if (fread(fhdr, 1, sizeof(fhdr), f) != sizeof(fhdr))
        goto trunc;

    if (fhdr[0] != 'B' || fhdr[1] != 'M') {
        fprintf(stderr, "%s: not a BMP file\n", path);
        goto fail;
    }

    uint32_t pixel_offset = bmp_le32(fhdr + 10);

    /* DIB header: we only need the first 40 bytes (BITMAPINFOHEADER) */
    uint8_t dib[40];
    if (fread(dib, 1, sizeof(dib), f) != sizeof(dib))
        goto trunc;

    int32_t  bmp_w    = (int32_t)bmp_le32(dib + 4);
    int32_t  bmp_h    = (int32_t)bmp_le32(dib + 8);
    uint16_t bpp      = bmp_le16(dib + 14);
    uint32_t compress = bmp_le32(dib + 16);

    /* Only uncompressed (0) and BI_BITFIELDS (3, common for 32-bit) */
    if (compress != 0 && compress != 3) {
        fprintf(stderr, "%s: unsupported BMP compression %u\n", path, compress);
        goto fail;
    }
    if (bpp != 24 && bpp != 32) {
        fprintf(stderr, "%s: unsupported BMP depth %u (need 24 or 32)\n",
                path, bpp);
        goto fail;
    }

    int top_down = (bmp_h < 0);
    uint32_t w = (uint32_t)(bmp_w < 0 ? -bmp_w : bmp_w);
    uint32_t h = (uint32_t)(top_down ? -bmp_h : bmp_h);

    if (w == 0 || h == 0 || w > 8192 || h > 8192) {
        fprintf(stderr, "%s: invalid BMP dimensions %ux%u\n", path, w, h);
        goto fail;
    }

    size_t pixel_bytes = (size_t)w * h * 4;
    out->pixels = malloc(pixel_bytes);
    if (!out->pixels) {
        fprintf(stderr, "out of memory (%zu bytes)\n", pixel_bytes);
        goto fail;
    }
    out->width  = w;
    out->height = h;

    /* BMP row stride is padded to 4-byte boundary */
    uint32_t src_stride = ((uint32_t)w * (bpp / 8u) + 3u) & ~3u;
    uint8_t *row_buf    = malloc(src_stride);
    if (!row_buf) {
        fprintf(stderr, "out of memory\n");
        free(out->pixels);
        out->pixels = NULL;
        goto fail;
    }

    if (fseek(f, (long)pixel_offset, SEEK_SET) < 0)
        goto trunc_row;

    for (uint32_t row = 0; row < h; row++) {
        if (fread(row_buf, 1, src_stride, f) != src_stride)
            goto trunc_row;

        /* Bottom-up BMP: row 0 in file is the bottom row of the image */
        uint32_t dst_row = top_down ? row : (h - 1u - row);
        uint8_t *dst = out->pixels + dst_row * w * 4u;

        for (uint32_t x = 0; x < w; x++) {
            const uint8_t *src = row_buf + x * (bpp / 8u);
            /* BMP: B G R [A]  →  XRGB8888 in memory: B G R X */
            dst[x * 4 + 0] = src[0]; /* B */
            dst[x * 4 + 1] = src[1]; /* G */
            dst[x * 4 + 2] = src[2]; /* R */
            dst[x * 4 + 3] = 0x00;   /* X */
        }
    }

    free(row_buf);
    fclose(f);
    return 0;

trunc_row:
    free(row_buf);
    free(out->pixels);
    out->pixels = NULL;
trunc:
    fprintf(stderr, "%s: truncated BMP data\n", path);
fail:
    fclose(f);
    return -1;
}

/* ------------------------------------------------------------------ */

typedef struct {
    int                  fd;
    uint32_t             connector_id;
    uint32_t             crtc_id;
    drmModeModeInfo      mode;
    uint32_t             buf_id;       /* dumb buffer fb id */
    uint32_t             buf_handle;
    uint32_t             buf_stride;
    uint64_t             buf_size;
    void                *buf_map;
    drmModeCrtcPtr       saved_crtc;
} DrmContext;

static void drm_cleanup(DrmContext *ctx)
{
    if (!ctx || ctx->fd < 0)
        return;

    /* restore original CRTC state */
    if (ctx->saved_crtc) {
        drmModeSetCrtc(ctx->fd,
                       ctx->saved_crtc->crtc_id,
                       ctx->saved_crtc->buffer_id,
                       ctx->saved_crtc->x,
                       ctx->saved_crtc->y,
                       &ctx->connector_id, 1,
                       &ctx->saved_crtc->mode);
        drmModeFreeCrtc(ctx->saved_crtc);
        ctx->saved_crtc = NULL;
    }

    if (ctx->buf_map && ctx->buf_map != MAP_FAILED) {
        munmap(ctx->buf_map, ctx->buf_size);
        ctx->buf_map = NULL;
    }

    if (ctx->buf_id) {
        drmModeRmFB(ctx->fd, ctx->buf_id);
        ctx->buf_id = 0;
    }

    if (ctx->buf_handle) {
        struct drm_mode_destroy_dumb dd = { .handle = ctx->buf_handle };
        drmIoctl(ctx->fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dd);
        ctx->buf_handle = 0;
    }
}

static int drm_find_connector(int fd, int prefer_index,
                               uint32_t *conn_id_out, uint32_t *crtc_id_out,
                               drmModeModeInfo *mode_out)
{
    drmModeResPtr res = drmModeGetResources(fd);
    if (!res) {
        perror("drmModeGetResources");
        return -1;
    }

    int found = 0;
    int index = 0;

    for (int i = 0; i < res->count_connectors && !found; i++) {
        drmModeConnectorPtr conn = drmModeGetConnector(fd, res->connectors[i]);
        if (!conn)
            continue;

        if (conn->connection != DRM_MODE_CONNECTED || conn->count_modes == 0) {
            drmModeFreeConnector(conn);
            continue;
        }

        if (index != prefer_index && prefer_index >= 0) {
            index++;
            drmModeFreeConnector(conn);
            continue;
        }

        /* pick preferred mode or first mode */
        int mode_idx = 0;
        for (int m = 0; m < conn->count_modes; m++) {
            if (conn->modes[m].type & DRM_MODE_TYPE_PREFERRED) {
                mode_idx = m;
                break;
            }
        }
        *mode_out = conn->modes[mode_idx];
        *conn_id_out = conn->connector_id;

        /* find encoder → CRTC */
        drmModeEncoderPtr enc = NULL;
        if (conn->encoder_id)
            enc = drmModeGetEncoder(fd, conn->encoder_id);

        if (enc && enc->crtc_id) {
            *crtc_id_out = enc->crtc_id;
            found = 1;
        } else {
            /* try any CRTC that the encoder supports */
            for (int e = 0; e < conn->count_encoders && !found; e++) {
                drmModeFreeEncoder(enc);
                enc = drmModeGetEncoder(fd, conn->encoders[e]);
                if (!enc) continue;
                for (int c = 0; c < res->count_crtcs && !found; c++) {
                    if (!(enc->possible_crtcs & (1 << c))) continue;
                    *crtc_id_out = res->crtcs[c];
                    found = 1;
                }
            }
        }

        if (enc) drmModeFreeEncoder(enc);
        drmModeFreeConnector(conn);
        index++;
    }

    drmModeFreeResources(res);

    if (!found) {
        fprintf(stderr, "no connected connector found (index %d)\n",
                prefer_index);
        return -1;
    }
    return 0;
}

static int drm_create_fb(int fd, uint32_t width, uint32_t height,
                          uint32_t *handle_out, uint32_t *stride_out,
                          uint64_t *size_out, uint32_t *fb_id_out,
                          void **map_out)
{
    struct drm_mode_create_dumb cd = {
        .width  = width,
        .height = height,
        .bpp    = 32,
    };

    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
        perror("DRM_IOCTL_MODE_CREATE_DUMB");
        return -1;
    }

    *handle_out = cd.handle;
    *stride_out = cd.pitch;
    *size_out   = cd.size;

    if (drmModeAddFB(fd, width, height, 24, 32, cd.pitch, cd.handle, fb_id_out)) {
        perror("drmModeAddFB");
        return -1;
    }

    struct drm_mode_map_dumb md = { .handle = cd.handle };
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &md)) {
        perror("DRM_IOCTL_MODE_MAP_DUMB");
        return -1;
    }

    *map_out = mmap(NULL, cd.size, PROT_READ | PROT_WRITE, MAP_SHARED,
                    fd, md.offset);
    if (*map_out == MAP_FAILED) {
        perror("mmap dumb buffer");
        return -1;
    }

    memset(*map_out, 0, cd.size);
    return 0;
}

/* Blit image centred on fb (both image and fb are XRGB8888 / 4 bpp) */
static void blit_centred(void *fb, uint32_t fb_w, uint32_t fb_h,
                          uint32_t fb_stride,
                          const uint8_t *img, uint32_t img_w, uint32_t img_h)
{
    int32_t off_x = ((int32_t)fb_w - (int32_t)img_w) / 2;
    int32_t off_y = ((int32_t)fb_h - (int32_t)img_h) / 2;

    uint32_t src_x0 = 0, src_y0 = 0;
    uint32_t dst_x0 = 0, dst_y0 = 0;
    uint32_t copy_w = img_w, copy_h = img_h;

    if (off_x < 0) { src_x0 = (uint32_t)(-off_x); copy_w -= src_x0; }
    else            { dst_x0 = (uint32_t)off_x; }

    if (off_y < 0) { src_y0 = (uint32_t)(-off_y); copy_h -= src_y0; }
    else           { dst_y0 = (uint32_t)off_y; }

    if (copy_w > fb_w - dst_x0) copy_w = fb_w - dst_x0;
    if (copy_h > fb_h - dst_y0) copy_h = fb_h - dst_y0;

    for (uint32_t row = 0; row < copy_h; row++) {
        const uint8_t *src = img + ((src_y0 + row) * img_w + src_x0) * 4;
        uint8_t       *dst = (uint8_t *)fb +
                             (dst_y0 + row) * fb_stride + dst_x0 * 4;
        memcpy(dst, src, copy_w * 4);
    }
}

/* ------------------------------------------------------------------ */

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [OPTIONS] <image.splr>\n"
            "Options:\n"
            "  -d <device>   DRM device (default: /dev/dri/card0)\n"
            "  -c <index>    connector index (default: 0)\n"
            "  -h            show this help\n",
            prog);
}

int main(int argc, char *argv[])
{
    const char *drm_dev = "/dev/dri/card0";
    int conn_index = 0;
    const char *image_path = NULL;

    int opt;
    while ((opt = getopt(argc, argv, "d:c:h")) != -1) {
        switch (opt) {
        case 'd': drm_dev    = optarg; break;
        case 'c': conn_index = atoi(optarg); break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 1;
        }
    }

    if (optind >= argc) {
        usage(argv[0]);
        return 1;
    }
    image_path = argv[optind];

    /* load image — auto-detect format from magic bytes */
    SplrImage img = {0};
    {
        FILE *probe = fopen(image_path, "rb");
        uint8_t magic[2] = {0};
        if (!probe) { perror(image_path); return 1; }
        fread(magic, 1, sizeof(magic), probe);
        fclose(probe);

        int ret;
        if (magic[0] == 'B' && magic[1] == 'M')
            ret = bmp_load(image_path, &img);
        else
            ret = splr_load(image_path, &img);
        if (ret < 0)
            return 1;
    }

    /* open DRM device */
    int fd = open(drm_dev, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        perror(drm_dev);
        free(img.pixels);
        return 1;
    }

    /* check dumb buffer support */
    uint64_t cap = 0;
    if (drmGetCap(fd, DRM_CAP_DUMB_BUFFER, &cap) < 0 || !cap) {
        fprintf(stderr, "%s: no dumb buffer support\n", drm_dev);
        close(fd);
        free(img.pixels);
        return 1;
    }

    DrmContext ctx = { .fd = fd };

    if (drm_find_connector(fd, conn_index,
                           &ctx.connector_id, &ctx.crtc_id, &ctx.mode) < 0)
        goto fail;

    printf("drm-splash: connector=%u crtc=%u mode=%ux%u\n",
           ctx.connector_id, ctx.crtc_id,
           ctx.mode.hdisplay, ctx.mode.vdisplay);

    /* save current CRTC for restore on exit */
    ctx.saved_crtc = drmModeGetCrtc(fd, ctx.crtc_id);

    /* allocate dumb framebuffer at display resolution */
    if (drm_create_fb(fd, ctx.mode.hdisplay, ctx.mode.vdisplay,
                      &ctx.buf_handle, &ctx.buf_stride,
                      &ctx.buf_size, &ctx.buf_id, &ctx.buf_map) < 0)
        goto fail;

    /* blit image into framebuffer */
    blit_centred(ctx.buf_map, ctx.mode.hdisplay, ctx.mode.vdisplay,
                 ctx.buf_stride, img.pixels, img.width, img.height);
    free(img.pixels);
    img.pixels = NULL;

    /* set mode */
    if (drmModeSetCrtc(fd, ctx.crtc_id, ctx.buf_id, 0, 0,
                       &ctx.connector_id, 1, &ctx.mode)) {
        perror("drmModeSetCrtc");
        goto fail;
    }

    /*
     * Drop DRM master immediately after the modeset.  The CRTC and
     * framebuffer remain active — the image keeps displaying — but the
     * next process (compositor / application) can acquire master and
     * start rendering without having to kill drm-splash first.  This
     * allows a seamless page-flip handoff instead of a blank gap.
     */
    drmDropMaster(fd);

    printf("drm-splash: displaying %s, waiting for SIGTERM\n", image_path);

    /* install signal handlers */
    struct sigaction sa = { .sa_handler = sig_handler };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);

    /* wait until signalled */
    while (!g_terminate)
        pause();

    printf("drm-splash: received signal, exiting\n");
    drm_cleanup(&ctx);
    close(fd);
    return 0;

fail:
    if (img.pixels) free(img.pixels);
    drm_cleanup(&ctx);
    close(fd);
    return 1;
}
