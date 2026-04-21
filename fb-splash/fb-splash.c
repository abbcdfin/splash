/*
 * fb-splash - Display a static splash image via Linux framebuffer (fbdev).
 *
 * Opens /dev/fb0 (or a user-specified device), maps the framebuffer,
 * blits a centred image, then waits for SIGTERM.  Works with
 * simple-framebuffer and other fbdev drivers.  No DRM dependency.
 *
 * Supported input formats:
 *   SPLR  magic "SPLR": width(4) + height(4) + XRGB8888 pixels
 *   BMP   24-bit and 32-bit, bottom-up and top-down
 *
 * Usage:
 *   fb-splash [OPTIONS] <image.splr|image.bmp>
 *
 * Options:
 *   -d <device>   framebuffer device (default: /dev/fb0)
 *   -h            show this help
 */

#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/fb.h>

#define SPLR_MAGIC     "SPLR"
#define SPLR_MAGIC_LEN  4
#define SPLR_HEADER_LEN 12  /* magic(4) + width(4) + height(4) */

static volatile sig_atomic_t g_terminate = 0;

static void sig_handler(int signo)
{
	(void)signo;
	g_terminate = 1;
}

/* ------------------------------------------------------------------ */
/* Image loading                                                        */
/* All loaders produce pixels as XRGB8888: [B][G][R][X] per pixel.    */
/* ------------------------------------------------------------------ */

typedef struct {
	uint32_t width;
	uint32_t height;
	uint8_t *pixels;  /* caller owns */
} Image;

static int splr_load(const char *path, Image *out)
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

static uint16_t bmp_le16(const uint8_t *p)
{
	return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t bmp_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int bmp_load(const char *path, Image *out)
{
	FILE *f = fopen(path, "rb");
	if (!f) {
		perror(path);
		return -1;
	}

	uint8_t fhdr[14];
	if (fread(fhdr, 1, sizeof(fhdr), f) != sizeof(fhdr))
		goto trunc;

	if (fhdr[0] != 'B' || fhdr[1] != 'M') {
		fprintf(stderr, "%s: not a BMP file\n", path);
		goto fail;
	}

	uint32_t pixel_offset = bmp_le32(fhdr + 10);

	uint8_t dib[40];
	if (fread(dib, 1, sizeof(dib), f) != sizeof(dib))
		goto trunc;

	int32_t  bmp_w    = (int32_t)bmp_le32(dib + 4);
	int32_t  bmp_h    = (int32_t)bmp_le32(dib + 8);
	uint16_t bpp      = bmp_le16(dib + 14);
	uint32_t compress = bmp_le32(dib + 16);

	if (compress != 0 && compress != 3) {
		fprintf(stderr, "%s: unsupported BMP compression %u\n",
		        path, compress);
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

		uint32_t dst_row = top_down ? row : (h - 1u - row);
		uint8_t *dst = out->pixels + dst_row * w * 4u;

		for (uint32_t x = 0; x < w; x++) {
			const uint8_t *src = row_buf + x * (bpp / 8u);
			/* BMP: B G R [A] → output: B G R X */
			dst[x * 4 + 0] = src[0];
			dst[x * 4 + 1] = src[1];
			dst[x * 4 + 2] = src[2];
			dst[x * 4 + 3] = 0x00;
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
/* Framebuffer blitting                                                 */
/* ------------------------------------------------------------------ */

/*
 * Source pixels are always [B][G][R][X] (little-endian 0x00RRGGBB).
 * For x8r8g8b8 framebuffers (red.off=16, green.off=8, blue.off=0)
 * this layout matches exactly and we can memcpy row by row.
 * For other formats we convert per pixel using the vinfo channel fields.
 */
static int fb_is_xrgb8888(const struct fb_var_screeninfo *v)
{
	return v->bits_per_pixel == 32 &&
	       v->red.offset == 16   && v->red.length == 8 &&
	       v->green.offset == 8  && v->green.length == 8 &&
	       v->blue.offset == 0   && v->blue.length == 8;
}

static void blit_centred(void *fb,
                         uint32_t fb_w, uint32_t fb_h, uint32_t fb_stride,
                         const struct fb_var_screeninfo *vinfo,
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

	uint32_t bpp_bytes = vinfo->bits_per_pixel / 8;
	int fast = fb_is_xrgb8888(vinfo);

	for (uint32_t row = 0; row < copy_h; row++) {
		const uint8_t *src = img +
		                     ((src_y0 + row) * img_w + src_x0) * 4;
		uint8_t *dst = (uint8_t *)fb +
		               (dst_y0 + row) * fb_stride + dst_x0 * bpp_bytes;

		if (fast) {
			memcpy(dst, src, copy_w * 4);
			continue;
		}

		for (uint32_t x = 0; x < copy_w; x++) {
			uint8_t b = src[x * 4 + 0];
			uint8_t g = src[x * 4 + 1];
			uint8_t r = src[x * 4 + 2];
			uint32_t px =
			    ((uint32_t)(r >> (8u - vinfo->red.length))   << vinfo->red.offset) |
			    ((uint32_t)(g >> (8u - vinfo->green.length)) << vinfo->green.offset) |
			    ((uint32_t)(b >> (8u - vinfo->blue.length))  << vinfo->blue.offset);
			memcpy(dst + x * bpp_bytes, &px, bpp_bytes);
		}
	}
}

/* ------------------------------------------------------------------ */

static void usage(const char *prog)
{
	fprintf(stderr,
	        "Usage: %s [OPTIONS] <image.splr|image.bmp>\n"
	        "Options:\n"
	        "  -d <device>   framebuffer device (default: /dev/fb0)\n"
	        "  -h            show this help\n",
	        prog);
}

int main(int argc, char *argv[])
{
	const char *fb_dev     = "/dev/fb0";
	const char *image_path = NULL;
	int fd = -1;
	void *fb = MAP_FAILED;
	size_t fb_size = 0;
	Image img = {0};
	int ret = 1;

	int opt;
	while ((opt = getopt(argc, argv, "d:h")) != -1) {
		switch (opt) {
		case 'd': fb_dev = optarg; break;
		case 'h': usage(argv[0]); return 0;
		default:  usage(argv[0]); return 1;
		}
	}

	if (optind >= argc) {
		usage(argv[0]);
		return 1;
	}
	image_path = argv[optind];

	/* Auto-detect image format from magic bytes */
	{
		FILE *probe = fopen(image_path, "rb");
		uint8_t magic[2] = {0};
		if (!probe) { perror(image_path); goto out; }
		fread(magic, 1, sizeof(magic), probe);
		fclose(probe);

		if (magic[0] == 'B' && magic[1] == 'M')
			ret = bmp_load(image_path, &img);
		else
			ret = splr_load(image_path, &img);
		if (ret < 0)
			goto out;
	}

	fd = open(fb_dev, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror(fb_dev);
		goto out;
	}

	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;

	if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
		perror("FBIOGET_VSCREENINFO");
		goto out;
	}
	if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
		perror("FBIOGET_FSCREENINFO");
		goto out;
	}

	if (vinfo.bits_per_pixel != 16 && vinfo.bits_per_pixel != 32) {
		fprintf(stderr, "%s: unsupported pixel depth %u bpp\n",
		        fb_dev, vinfo.bits_per_pixel);
		goto out;
	}

	printf("fb-splash: %s %ux%u %ubpp stride=%u\n",
	       fb_dev, vinfo.xres, vinfo.yres,
	       vinfo.bits_per_pixel, finfo.line_length);

	fb_size = (size_t)finfo.line_length * vinfo.yres;
	fb = mmap(NULL, fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (fb == MAP_FAILED) {
		perror("mmap");
		goto out;
	}

	blit_centred(fb, vinfo.xres, vinfo.yres, finfo.line_length,
	             &vinfo, img.pixels, img.width, img.height);

	free(img.pixels);
	img.pixels = NULL;

	printf("fb-splash: displaying %s, waiting for SIGTERM\n", image_path);

	struct sigaction sa = { .sa_handler = sig_handler };
	sigemptyset(&sa.sa_mask);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT,  &sa, NULL);

	while (!g_terminate)
		pause();

	printf("fb-splash: received signal, exiting\n");
	ret = 0;

out:
	if (fb != MAP_FAILED) munmap(fb, fb_size);
	if (fd >= 0) close(fd);
	if (img.pixels) free(img.pixels);
	return ret;
}
