// SPDX-License-Identifier: GPL-2.0-only

#ifdef __UBOOT__
#include <cpu_func.h>
#include <fdtdec.h>
#include <asm/io.h>
#include <asm/system.h>
#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/math64.h>
#include <mapmem.h>
#include <stdio.h>

#include "ironvideo.h"

#define IV_POLL_US 50
#define IV_TIMEOUT_US 250000
#define IV_POLL_BUDGET (IV_TIMEOUT_US / IV_POLL_US)
#define IV_FRAME_POLL_MS 10
#define IV_MIN_SCANOUT_WAIT_MS 100

static u32 iv_boot_read(void *context, u32 offset)
{
	return readl((u8 __iomem *)context + offset);
}

static void iv_boot_write(void *context, u32 offset, u32 value)
{
	writel(value, (u8 __iomem *)context + offset);
}

static void iv_boot_delay(void *context)
{
	udelay(IV_POLL_US);
}

static void iv_boot_barrier(void *context)
{
	wmb();
}

static struct iv_mmio iv_boot_io(u8 __iomem *regs)
{
	return (struct iv_mmio) {
		.context = regs,
		.read32 = iv_boot_read,
		.write32 = iv_boot_write,
		.barrier = iv_boot_barrier,
		.poll_delay = iv_boot_delay,
	};
}

static int iv_boot_errno(int ret)
{
	switch (ret) {
	case IV_OK: return 0;
	case IV_INVALID: return -EINVAL;
	case IV_UNSUPPORTED: return -ENODEV;
	case IV_TIMEOUT: return -ETIMEDOUT;
	default: return -EIO;
	}
}

static int iv_check_scanout(const struct iv_mmio *io, u32 beats, u32 timeout_ms)
{
	struct iv_snapshot snapshot;
	unsigned int elapsed;
	u32 first;
	int ret;

	ret = iv_read_snapshot(io, &snapshot, IV_POLL_BUDGET);
	if (ret)
		return iv_boot_errno(ret);
	first = snapshot.frames;
	for (elapsed = 0; elapsed < timeout_ms; elapsed += IV_FRAME_POLL_MS) {
		mdelay(IV_FRAME_POLL_MS);
		ret = iv_read_snapshot(io, &snapshot, IV_POLL_BUDGET);
		if (ret)
			return iv_boot_errno(ret);
		if (snapshot.faults)
			return -EIO;
		if (snapshot.frames - first >= 2 && snapshot.read_beats >= beats)
			return 0;
	}
	return -ETIMEDOUT;
}

static int iv_paint_plane(const struct iv_fb_plane *plane, enum iv_format format,
			  u32 row_bytes, u32 height, u32 color, bool uv)
{
	u32 bytes = iv_plane_span(plane->stride, row_bytes, height);
	unsigned int r = (color >> 16) & 255, g = (color >> 8) & 255, b = color & 255;
	u32 rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
	u32 luma = 16 + (47 * r + 157 * g + 16 * b + 128) / 256;
	u32 cb = (32896 - 26 * r - 86 * g + 112 * b) / 256;
	u32 cr = (32896 + 112 * r - 102 * g - 10 * b) / 256;
	u32 yuyv = luma | (cb << 8) | (luma << 16) | (cr << 24);
	u8 *pixels = map_sysmem(plane->base, bytes);
	u32 y, x;

	if (!pixels)
		return -ENOMEM;
	for (y = 0; y < height; y++) {
		u8 *line = pixels + y * plane->stride;

		switch (format) {
		case IV_FORMAT_XRGB8888:
			for (x = 0; x < row_bytes / 4; x++)
				((u32 *)line)[x] = cpu_to_le32(color);
			break;
		case IV_FORMAT_RGB565:
			for (x = 0; x < row_bytes / 2; x++)
				((u16 *)line)[x] = cpu_to_le16(rgb565);
			break;
		case IV_FORMAT_YUV422:
			for (x = 0; x < row_bytes / 4; x++)
				((u32 *)line)[x] = cpu_to_le32(yuyv);
			break;
		case IV_FORMAT_YUV420:
			for (x = 0; x < row_bytes; x++)
				line[x] = uv ? (x & 1 ? cr : cb) : luma;
			break;
		}
	}
	flush_cache((ulong)pixels, bytes);
	unmap_sysmem(pixels);
	return 0;
}

static int iv_boot_start(const struct iv_mmio *io, const struct iv_caps *caps,
			 const struct iv_scanout *config, u32 color)
{
	const struct iv_mode *mode = &config->mode;
	struct iv_geometry geometry;
	u32 htotal, vtotal, wait_ms, beats = 0;
	int ret;

	if (!mode->pixel_hz)
		return -EINVAL;
	ret = iv_validate(caps, config);
	if (ret)
		return iv_boot_errno(ret);
	io->write32(io->context, IV_REG_MASK, 0);
	ret = iv_stop(io, IV_POLL_BUDGET);
	if (ret)
		return iv_boot_errno(ret);
	if (!config->pattern) {
		ret = iv_format_geometry(caps, config->format, mode->h_active,
					 mode->v_active, &geometry);
		if (ret)
			return iv_boot_errno(ret);
		ret = iv_paint_plane(&config->primary, config->format,
				     geometry.row_bytes, mode->v_active, color, false);
		if (!ret && geometry.uv_height)
			ret = iv_paint_plane(&config->uv, config->format, geometry.uv_row_bytes,
					     geometry.uv_height, color, true);
		if (ret)
			return ret;
		beats = div_u64(geometry.frame_bytes, caps->beat_bytes);
	}
	htotal = mode->h_active + mode->h_front + mode->h_sync + mode->h_back;
	vtotal = mode->v_active + mode->v_front + mode->v_sync + mode->v_back;
	wait_ms = clamp_t(u64, div_u64((u64)htotal * vtotal * 6000, mode->pixel_hz),
			  IV_MIN_SCANOUT_WAIT_MS, IV_TIMEOUT_US / 1000);

	iv_clear_faults(io, IV_FAULT_ALL);
	ret = iv_boot_errno(iv_commit(io, caps, config, true, IV_POLL_BUDGET));
	if (!ret)
		ret = iv_check_scanout(io, beats, wait_ms);
	if (ret) {
		printf("IronVideo: scanout fault status 0x%02x\n",
		       io->read32(io->context, IV_REG_FAULT));
		if (iv_stop(io, IV_POLL_BUDGET))
			puts("IronVideo: scanout did not quiesce\n");
	}
	return ret;
}

int ironvideo_boot_scanout_format(u8 __iomem *regs,
				  const struct iv_scanout *config, u32 color)
{
	struct iv_mmio io = iv_boot_io(regs);
	struct iv_caps caps;
	int ret = iv_discover(&io, &caps);

	return ret ? iv_boot_errno(ret) : iv_boot_start(&io, &caps, config, color);
}

int ironvideo_boot_scanout(u8 __iomem *regs, u32 fb, u32 size, u32 stride,
			   const struct display_timing *mode, u32 color)
{
	struct iv_mmio io = iv_boot_io(regs);
	struct iv_caps caps;
	struct iv_scanout config = { 0 };
	struct iv_geometry geometry;
	enum iv_format format;
	u64 uv_base;
	int ret;

	if (mode->flags & (DISPLAY_FLAGS_INTERLACED | DISPLAY_FLAGS_DOUBLESCAN |
			   DISPLAY_FLAGS_DOUBLECLK))
		return -EINVAL;
	ret = iv_discover(&io, &caps);
	if (ret)
		return iv_boot_errno(ret);
	config.mode = (struct iv_mode) {
		.h_active = mode->hactive.typ, .h_front = mode->hfront_porch.typ,
		.h_sync = mode->hsync_len.typ, .h_back = mode->hback_porch.typ,
		.v_active = mode->vactive.typ, .v_front = mode->vfront_porch.typ,
		.v_sync = mode->vsync_len.typ, .v_back = mode->vback_porch.typ,
		.pixel_hz = mode->pixelclock.typ,
		.polarity = (mode->flags & DISPLAY_FLAGS_HSYNC_HIGH ? IV_POL_HPOS : 0) |
			    (mode->flags & DISPLAY_FLAGS_VSYNC_HIGH ? IV_POL_VPOS : 0),
	};
	format = iv_preferred_format(&caps);
	for (; format <= IV_FORMAT_YUV420; format++) {
		ret = iv_format_geometry(&caps, format, config.mode.h_active,
					 config.mode.v_active, &geometry);
		if (!ret && (format == IV_FORMAT_XRGB8888 || geometry.frame_bytes <= size))
			break;
		/* Keep the legacy XRGB8888 caller's stride and validation behavior. */
		if (format == IV_FORMAT_XRGB8888)
			return iv_boot_errno(ret);
	}
	if (format > IV_FORMAT_YUV420)
		return -EINVAL;
	config.format = format;
	config.mode.prefill = geometry.prefill_beats;
	config.primary = (struct iv_fb_plane) {
		.base = fb, .stride = config.format == IV_FORMAT_XRGB8888 ? stride : geometry.row_bytes,
		.window_base = fb, .window_bytes = size,
	};
	if (config.format == IV_FORMAT_YUV420) {
		uv_base = (u64)fb + (u64)config.primary.stride * config.mode.v_active;
		if (uv_base > U32_MAX || uv_base >= (u64)fb + size)
			return -EINVAL;
		config.primary.window_bytes = uv_base - fb;
		config.uv = (struct iv_fb_plane) {
			.base = uv_base, .stride = geometry.uv_row_bytes,
			.window_base = uv_base, .window_bytes = (u64)fb + size - uv_base,
		};
	}
	return iv_boot_start(&io, &caps, &config, color);
}

#else

#include <linux/delay.h>
#include <linux/clk.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/ktime.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/sysfs.h>
#include <video/of_display_timing.h>
#include <video/of_videomode.h>
#include <video/videomode.h>

#include <drm/clients/drm_client_setup.h>
#include <drm/drm_atomic.h>
#include <drm/drm_atomic_helper.h>
#include <drm/drm_color_mgmt.h>
#include <drm/drm_drv.h>
#include <drm/drm_fb_dma_helper.h>
#include <drm/drm_fbdev_dma.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_framebuffer.h>
#include <drm/drm_gem_atomic_helper.h>
#include <drm/drm_gem_dma_helper.h>
#include <drm/drm_gem_framebuffer_helper.h>
#include <drm/drm_print.h>
#include <drm/drm_probe_helper.h>

#include "ironvideo_core.h"

struct ironvideo {
	struct drm_device drm;
	struct drm_plane plane;
	struct drm_crtc crtc;
	struct drm_encoder encoder;
	struct drm_connector connector;
	struct drm_display_mode native_mode;

	void __iomem *regs;
	struct clk_bulk_data clocks[2];
	unsigned long pixel_hz;
	unsigned long axi_hz;
	struct iv_mmio io;
	struct iv_caps caps;
	u32 formats[4];
	u32 format_count;

	struct mutex hw_lock; /* protects MMIO transactions and the active DMA reference */
	struct drm_framebuffer *scanout;
	u32 htotal;
	u64 epoch;
	bool quiescing;
};

#define to_ironvideo(drm_dev) container_of(drm_dev, struct ironvideo, drm)
#define IV_POLL_US	50
#define IV_TIMEOUT_US	250000
#define IV_POLL_BUDGET	(IV_TIMEOUT_US / IV_POLL_US)
#define IV_DRAIN_MARGIN_US	50000

static u32 ironvideo_read32(void *context, u32 offset)
{
	return readl((u8 __iomem *)context + offset);
}

static void ironvideo_write32(void *context, u32 offset, u32 value)
{
	writel(value, (u8 __iomem *)context + offset);
}

static void ironvideo_write_barrier(void *context)
{
	dma_wmb();
}

static void ironvideo_poll_delay(void *context)
{
	usleep_range(IV_POLL_US / 4 + 1, IV_POLL_US);
}

static iv_u64 ironvideo_time_us(void *context)
{
	return ktime_to_us(ktime_get());
}

static int ironvideo_errno(int ret)
{
	switch (ret) {
	case IV_OK: return 0;
	case IV_INVALID: return -EINVAL;
	case IV_UNSUPPORTED: return -ENODEV;
	case IV_TIMEOUT: return -ETIMEDOUT;
	default: return -EIO;
	}
}

static int ironvideo_stop(struct ironvideo *iv)
{
	int ret = ironvideo_errno(iv_stop(&iv->io, IV_POLL_BUDGET));

	if (ret)
		return ret;
	if (iv->scanout) {
		drm_framebuffer_put(iv->scanout);
		iv->scanout = NULL;
		module_put(THIS_MODULE);
	}
	return 0;
}

static const u32 ironvideo_fourcc[] = {
	[IV_FORMAT_XRGB8888] = DRM_FORMAT_XRGB8888,
	[IV_FORMAT_RGB565] = DRM_FORMAT_RGB565,
	[IV_FORMAT_YUV422] = DRM_FORMAT_YUYV,
	[IV_FORMAT_YUV420] = DRM_FORMAT_NV12,
};

static bool ironvideo_bandwidth(const struct ironvideo *iv,
				const struct drm_display_mode *mode,
				enum iv_format format,
				const struct iv_geometry *geometry)
{
	u64 total_pixels = (u64)mode->htotal * mode->vtotal;
	u64 frame_bytes = geometry->frame_bytes;
	u64 rate = (u64)iv->axi_hz * iv->caps.beat_bytes;

	/* A UV beat and two Y beats require at least five NV12 AXI cycles. */
	if (format == IV_FORMAT_YUV420) {
		frame_bytes *= IV_NV12_AXI_CYCLES;
		rate *= IV_NV12_SOURCE_BEATS;
	}
	return mul_u64_u64_div_u64_roundup(frame_bytes, iv->pixel_hz,
					  total_pixels) <= rate;
}

static enum drm_mode_status ironvideo_mode_valid(struct drm_crtc *crtc,
						const struct drm_display_mode *mode)
{
	struct ironvideo *iv = to_ironvideo(crtc->dev);
	struct iv_geometry geometry;
	enum iv_format format;
	u64 total_pixels;
	bool geometry_valid = false;

	if (mode->flags & DRM_MODE_FLAG_INTERLACE)
		return MODE_NO_INTERLACE;
	if (mode->flags & DRM_MODE_FLAG_DBLSCAN)
		return MODE_NO_DBLESCAN;
	if (mode->vscan > 1 || mode->flags & ~(DRM_MODE_FLAG_PHSYNC |
					      DRM_MODE_FLAG_NHSYNC |
					      DRM_MODE_FLAG_PVSYNC |
					      DRM_MODE_FLAG_NVSYNC |
					      DRM_MODE_FLAG_PIC_AR_MASK))
		return MODE_BAD;
	if (mode->clock <= 0 || (u64)mode->clock != (iv->pixel_hz / 1000))
		return MODE_CLOCK_RANGE;
	if ((mode->flags & (DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_NHSYNC)) ==
	    (DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_NHSYNC) ||
	    (mode->flags & (DRM_MODE_FLAG_PVSYNC | DRM_MODE_FLAG_NVSYNC)) ==
	    (DRM_MODE_FLAG_PVSYNC | DRM_MODE_FLAG_NVSYNC))
		return MODE_BAD;
	if (!mode->hdisplay || mode->hsync_start < mode->hdisplay ||
	    mode->hsync_end <= mode->hsync_start || mode->htotal < mode->hsync_end)
		return MODE_BAD_HVALUE;
	if (!mode->vdisplay || mode->vsync_start < mode->vdisplay ||
	    mode->vsync_end <= mode->vsync_start || mode->vtotal < mode->vsync_end)
		return MODE_BAD_VVALUE;

	total_pixels = (u64)mode->htotal * mode->vtotal;
	/* Stop can take one complete frame plus the AXI drain handshake. */
	if (total_pixels * USEC_PER_SEC >
	    (u64)iv->pixel_hz * (IV_TIMEOUT_US - IV_DRAIN_MARGIN_US))
		return MODE_BAD;

	/* A connector mode can be offered if at least one advertised format fits. */
	for (format = IV_FORMAT_XRGB8888; format <= IV_FORMAT_YUV420; format++) {
		if (!iv_format_geometry(&iv->caps, format, mode->hdisplay,
					 mode->vdisplay, &geometry)) {
			geometry_valid = true;
			if (ironvideo_bandwidth(iv, mode, format, &geometry))
				return MODE_OK;
		}
	}
	return geometry_valid ? MODE_CLOCK_HIGH : MODE_BAD_HVALUE;
}

static int ironvideo_fb_plane(struct drm_framebuffer *fb, unsigned int index,
			      u32 row, u32 height, struct iv_fb_plane *plane)
{
	struct drm_gem_dma_object *obj = drm_fb_dma_get_gem_obj(fb, index);
	u64 offset = fb->offsets[index];
	u64 span = iv_plane_span(fb->pitches[index], row, height);
	u32 base;

	if (!obj || obj->dma_addr > U32_MAX || offset > U32_MAX - obj->dma_addr ||
	    span > U32_MAX || offset + span > obj->base.size)
		return -EINVAL;
	base = obj->dma_addr + offset;
	if ((u64)base + span > (1ULL << 32))
		return -EINVAL;
	*plane = (struct iv_fb_plane) {
		.base = base, .stride = fb->pitches[index],
		.window_base = base, .window_bytes = span,
	};
	return 0;
}

static int ironvideo_fb_config(struct ironvideo *iv, const struct drm_display_mode *mode,
			       struct drm_framebuffer *fb, struct iv_scanout *config)
{
	struct iv_geometry geometry;
	enum iv_format format;
	int ret;

	for (format = IV_FORMAT_XRGB8888; format <= IV_FORMAT_YUV420; format++)
		if (ironvideo_fourcc[format] == fb->format->format)
			break;
	if (format > IV_FORMAT_YUV420 || fb->modifier != DRM_FORMAT_MOD_LINEAR ||
	    fb->format->num_planes != (format == IV_FORMAT_YUV420 ? 2 : 1))
		return -EINVAL;
	ret = iv_format_geometry(&iv->caps, format, mode->hdisplay,
				 mode->vdisplay, &geometry);
	if (ret || !ironvideo_bandwidth(iv, mode, format, &geometry))
		return -EINVAL;
	*config = (struct iv_scanout) {
		.format = format,
		.mode = {
			.h_active = mode->hdisplay,
			.h_front = mode->hsync_start - mode->hdisplay,
			.h_sync = mode->hsync_end - mode->hsync_start,
			.h_back = mode->htotal - mode->hsync_end,
			.v_active = mode->vdisplay,
			.v_front = mode->vsync_start - mode->vdisplay,
			.v_sync = mode->vsync_end - mode->vsync_start,
			.v_back = mode->vtotal - mode->vsync_end,
			.pixel_hz = iv->pixel_hz,
			.polarity = (mode->flags & DRM_MODE_FLAG_PHSYNC ? IV_POL_HPOS : 0) |
				    (mode->flags & DRM_MODE_FLAG_PVSYNC ? IV_POL_VPOS : 0),
			.prefill = geometry.prefill_beats,
		},
	};
	ret = ironvideo_fb_plane(fb, 0, geometry.row_bytes, mode->vdisplay,
				 &config->primary);
	if (!ret && geometry.uv_height)
		ret = ironvideo_fb_plane(fb, 1, geometry.uv_row_bytes,
					 geometry.uv_height, &config->uv);
	if (ret)
		return ret;
	return ironvideo_errno(iv_validate(&iv->caps, config));
}

static int ironvideo_check(struct drm_device *drm, struct drm_atomic_commit *state)
{
	struct ironvideo *iv = to_ironvideo(drm);
	struct drm_plane_state *plane = drm_atomic_get_new_plane_state(state, &iv->plane);
	struct drm_crtc_state *crtc;
	struct drm_framebuffer *fb;
	struct iv_scanout config;
	int ret;

	/* Include the CRTC when the update initially names only its primary plane. */
	if (plane) {
		crtc = drm_atomic_get_crtc_state(state, &iv->crtc);
		if (IS_ERR(crtc))
			return PTR_ERR(crtc);
	}
	ret = drm_atomic_helper_check(drm, state);
	if (ret)
		return ret;

	crtc = drm_atomic_get_new_crtc_state(state, &iv->crtc);
	if (!crtc || !crtc->enable)
		return 0;

	plane = drm_atomic_get_plane_state(state, &iv->plane);
	if (IS_ERR(plane))
		return PTR_ERR(plane);
	fb = plane->fb;
	if (!fb || plane->crtc != &iv->crtc ||
	    plane->src_x || plane->src_y || plane->crtc_x || plane->crtc_y ||
	    plane->crtc_w != crtc->mode.hdisplay || plane->crtc_h != crtc->mode.vdisplay ||
	    plane->src_w != plane->crtc_w << 16 || plane->src_h != plane->crtc_h << 16)
		return -EINVAL;

	return ironvideo_fb_config(iv, &crtc->mode, fb, &config);
}

static int ironvideo_start(struct ironvideo *iv, const struct drm_display_mode *mode,
			   struct drm_framebuffer *fb)
{
	struct iv_scanout config;
	int ret = ironvideo_fb_config(iv, mode, fb, &config);

	if (ret)
		return ret;
	if (!try_module_get(THIS_MODULE))
		return -ENODEV;
	drm_framebuffer_get(fb);
	iv->scanout = fb;
	iv->htotal = 0;
	iv_clear_faults(&iv->io, IV_FAULT_ALL);
	ret = ironvideo_errno(iv_commit(&iv->io, &iv->caps, &config, true, IV_POLL_BUDGET));
	if (ret)
		return ret;
	iv->htotal = mode->htotal;
	iv->epoch++;
	return 0;
}

static void ironvideo_commit_tail(struct drm_atomic_commit *state)
{
	struct ironvideo *iv = to_ironvideo(state->dev);
	struct drm_crtc_state *crtc = drm_atomic_get_new_crtc_state(state, &iv->crtc);
	struct drm_plane_state *plane = drm_atomic_get_new_plane_state(state, &iv->plane);
	int ret;

	if (crtc) {
		mutex_lock(&iv->hw_lock);
		/*
		 * Stop before switching the aperture. Preserve the current GEM
		 * reference if the fabric cannot confirm that all reads drained.
		 */
		if (!iv->quiescing &&
		    (!crtc->active || !plane || plane->fb != iv->scanout ||
		     drm_atomic_crtc_needs_modeset(crtc) || !iv->htotal)) {
			ret = ironvideo_stop(iv);
			if (!ret && crtc->active && plane)
				ret = ironvideo_start(iv, &crtc->mode, plane->fb);
			if (ret)
				drm_err(&iv->drm, "scanout transition failed (%d)\n", ret);
		}
		mutex_unlock(&iv->hw_lock);
	}

	drm_atomic_helper_commit_tail(state);
}

static const struct drm_mode_config_helper_funcs ironvideo_mode_helpers = {
	.atomic_commit_tail = ironvideo_commit_tail,
};

static const struct drm_mode_config_funcs ironvideo_mode_funcs = {
	.fb_create = drm_gem_fb_create,
	.atomic_check = ironvideo_check,
	.atomic_commit = drm_atomic_helper_commit,
};

static const struct drm_plane_funcs ironvideo_plane_funcs = {
	.update_plane = drm_atomic_helper_update_plane,
	.disable_plane = drm_atomic_helper_disable_plane,
	.reset = drm_atomic_helper_plane_reset,
	.atomic_duplicate_state = drm_atomic_helper_plane_duplicate_state,
	.atomic_destroy_state = drm_atomic_helper_plane_destroy_state,
	.destroy = drm_plane_cleanup,
};

static void ironvideo_plane_atomic_update(struct drm_plane *plane,
					  struct drm_atomic_commit *state)
{
	/* ironvideo_commit_tail() already handled the scanout transition. */
}

static const struct drm_plane_helper_funcs ironvideo_plane_helpers = {
	.prepare_fb = drm_gem_plane_helper_prepare_fb,
	.atomic_update = ironvideo_plane_atomic_update,
};

static const struct drm_crtc_funcs ironvideo_crtc_funcs = {
	.reset = drm_atomic_helper_crtc_reset,
	.set_config = drm_atomic_helper_set_config,
	.page_flip = drm_atomic_helper_page_flip,
	.atomic_duplicate_state = drm_atomic_helper_crtc_duplicate_state,
	.atomic_destroy_state = drm_atomic_helper_crtc_destroy_state,
	.destroy = drm_crtc_cleanup,
};

static const struct drm_crtc_helper_funcs ironvideo_crtc_helpers = {
	.mode_valid = ironvideo_mode_valid,
};

static const struct drm_encoder_funcs ironvideo_encoder_funcs = {
	.destroy = drm_encoder_cleanup,
};

static const struct drm_connector_funcs ironvideo_connector_funcs = {
	.reset = drm_atomic_helper_connector_reset,
	.fill_modes = drm_helper_probe_single_connector_modes,
	.atomic_duplicate_state = drm_atomic_helper_connector_duplicate_state,
	.atomic_destroy_state = drm_atomic_helper_connector_destroy_state,
	.destroy = drm_connector_cleanup,
};

static int ironvideo_get_modes(struct drm_connector *connector)
{
	struct ironvideo *iv = to_ironvideo(connector->dev);
	struct drm_display_mode *mode;

	mode = drm_mode_duplicate(&iv->drm, &iv->native_mode);
	if (!mode)
		return 0;
	mode->type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED;
	drm_mode_probed_add(connector, mode);
	return 1;
}

static const struct drm_connector_helper_funcs ironvideo_connector_helpers = {
	.get_modes = ironvideo_get_modes,
};

static const u64 ironvideo_modifiers[] = { DRM_FORMAT_MOD_LINEAR, DRM_FORMAT_MOD_INVALID };

static int ironvideo_modeset_init(struct ironvideo *iv)
{
	struct drm_device *drm = &iv->drm;
	int ret;

	ret = drmm_mode_config_init(drm);
	if (ret)
		return ret;
	drm->mode_config.min_width = iv->caps.version == IV_VERSION_LEGACY ?
				     iv->caps.beat_bytes / 4 : 1;
	drm->mode_config.min_height = 1;
	drm->mode_config.max_width = iv->caps.version == IV_VERSION_LEGACY ?
				     iv->caps.fifo_bytes / 4 :
				     min_t(u32, iv->caps.fifo_bytes, U16_MAX);
	drm->mode_config.max_height = U16_MAX;
	drm->mode_config.preferred_depth =
		iv_format_supported(&iv->caps, IV_FORMAT_XRGB8888) ? 24 :
		iv_format_supported(&iv->caps, IV_FORMAT_RGB565) ? 16 : 0;
	drm->mode_config.funcs = &ironvideo_mode_funcs;
	drm->mode_config.helper_private = &ironvideo_mode_helpers;

	ret = drm_universal_plane_init(drm, &iv->plane, 0, &ironvideo_plane_funcs,
				       iv->formats, iv->format_count,
				       ironvideo_modifiers, DRM_PLANE_TYPE_PRIMARY, NULL);
	if (ret)
		return ret;

	if (iv->caps.format_mask & (IV_FORMAT_BIT(IV_FORMAT_YUV422) |
				    IV_FORMAT_BIT(IV_FORMAT_YUV420))) {
		ret = drm_plane_create_color_properties(&iv->plane,
							BIT(DRM_COLOR_YCBCR_BT709),
							BIT(DRM_COLOR_YCBCR_LIMITED_RANGE),
							DRM_COLOR_YCBCR_BT709,
							DRM_COLOR_YCBCR_LIMITED_RANGE);
		if (ret)
			return ret;
	}
	drm_plane_helper_add(&iv->plane, &ironvideo_plane_helpers);

	ret = drm_crtc_init_with_planes(drm, &iv->crtc, &iv->plane, NULL,
					&ironvideo_crtc_funcs, NULL);
	if (ret)
		return ret;
	drm_crtc_helper_add(&iv->crtc, &ironvideo_crtc_helpers);

	ret = drm_encoder_init(drm, &iv->encoder, &ironvideo_encoder_funcs,
			       DRM_MODE_ENCODER_TMDS, NULL);
	if (ret)
		return ret;
	iv->encoder.possible_crtcs = drm_crtc_mask(&iv->crtc);

	ret = drm_connector_init(drm, &iv->connector, &ironvideo_connector_funcs,
				 DRM_MODE_CONNECTOR_DVID);
	if (ret)
		return ret;
	drm_connector_helper_add(&iv->connector, &ironvideo_connector_helpers);

	ret = drm_connector_attach_encoder(&iv->connector, &iv->encoder);
	if (ret)
		return ret;

	drm_mode_config_reset(drm);
	return 0;
}

static ssize_t row_stats_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct ironvideo *iv = dev_get_drvdata(dev);
	u64 epoch, current_bps, peak_bps, budget_permille;
	u32 before, samples, after, bytes, last, worst, best, beats, bursts, errors;
	u32 status, htotal, peak_cycles, peak_bytes;
	struct iv_snapshot snapshot;
	ssize_t length;
	int tries, ret;

	mutex_lock(&iv->hw_lock);
	ret = ironvideo_errno(iv_read_snapshot(&iv->io, &snapshot, IV_POLL_BUDGET));
	if (ret)
		goto unlock;

	for (tries = 0; tries < 8; tries++) {
		before = readl(iv->regs + IV_REG_ROW_SAMPLES);
		bytes = readl(iv->regs + IV_REG_ROW_BYTES);
		last = readl(iv->regs + IV_REG_ROW_LAST);
		samples = readl(iv->regs + IV_REG_ROW_SAMPLES);
		if (before == samples)
			break;
	}
	if (before != samples) {
		ret = -EAGAIN;
		goto unlock;
	}

	/* Each of these two reads consumes the corresponding hardware interval. */
	worst = readl(iv->regs + IV_REG_ROW_WORST);
	best = readl(iv->regs + IV_REG_ROW_BEST);
	peak_cycles = best;
	peak_bytes = bytes;
	if (iv->caps.version == IV_VERSION_FORMATS) {
		peak_cycles = readl(iv->regs + IV_REG_PEAK_RATE_CYCLES);
		peak_bytes = readl(iv->regs + IV_REG_PEAK_RATE_BYTES);
	}
	after = readl(iv->regs + IV_REG_ROW_SAMPLES);
	beats = readl(iv->regs + IV_REG_READ_BEATS);
	bursts = readl(iv->regs + IV_REG_READ_BURSTS);
	errors = readl(iv->regs + IV_REG_READ_ERRORS);
	status = readl(iv->regs + IV_REG_DMA_STATUS);
	htotal = iv->htotal;
	epoch = iv->epoch;
	mutex_unlock(&iv->hw_lock);

	current_bps = last ? div_u64((u64)bytes * iv->pixel_hz, last) : 0;
	peak_bps = peak_cycles ? div_u64((u64)peak_bytes * iv->pixel_hz, peak_cycles) : 0;
	budget_permille = htotal ? div_u64((u64)worst * 1000, htotal) : 0;

	length = sysfs_emit(buf,
			  "epoch %llu\npixel_clock_hz %lu\nhtotal %u\n"
			  "axi_clock_hz %lu\naxi_data_width %u\nfifo_capacity_bytes %u\n"
			  "row_bytes %u\nrow_samples %u\nrow_samples_after_extrema %u\n"
			  "last_cycles %u\nbest_cycles %u\nworst_cycles %u\n"
			  "current_bytes_per_sec %llu\npeak_bytes_per_sec %llu\n"
			  "worst_row_budget_permille %llu\n"
			  "read_beats %u\nread_bursts %u\nread_errors %u\ndma_status 0x%08x\n"
			  "status 0x%08x\nunderflows %u\nfifo_low_water_beats %u\nframes %u\n"
			  "raster_xy 0x%08x\nunderflow_xy 0x%08x\nfaults 0x%08x\n"
			  "first_fault 0x%08x\nfirst_fault_addr 0x%08x\n",
			  epoch, iv->pixel_hz, htotal, iv->axi_hz, iv->caps.beat_bytes * 8,
			  iv->caps.fifo_bytes, bytes, samples, after, last, best,
			  worst, current_bps, peak_bps, budget_permille,
			  beats, bursts, errors, status, snapshot.status, snapshot.underflows,
			  snapshot.fifo_low_water, snapshot.frames, snapshot.raster_xy,
			  snapshot.underflow_xy, snapshot.faults, snapshot.first_fault,
			  snapshot.first_fault_addr);
	if (iv->caps.version == IV_VERSION_FORMATS)
		length += sysfs_emit_at(buf, length, "peak_rate_cycles %u\npeak_rate_bytes %u\n",
					peak_cycles, peak_bytes);
	return length;

unlock:
	mutex_unlock(&iv->hw_lock);
	return ret;
}

static DEVICE_ATTR_RO(row_stats);

DEFINE_DRM_GEM_DMA_FOPS(ironvideo_fops);

static const struct drm_driver ironvideo_drm_driver = {
	.driver_features = DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
	.fops = &ironvideo_fops,
	.dumb_create = drm_gem_dma_dumb_create,
	DRM_FBDEV_DMA_DRIVER_OPS,
	.name = "ironvideo",
	.desc = "IronKernel IronVideo",
	.major = 1,
};

static int ironvideo_clocks_enable(struct ironvideo *iv)
{
	struct device *dev = iv->drm.dev;
	int ret;

	iv->clocks[0].id = "axi";
	iv->clocks[1].id = "pixel";

	ret = clk_bulk_get(dev, ARRAY_SIZE(iv->clocks), iv->clocks);
	if (ret)
		return ret;
	ret = clk_rate_exclusive_get(iv->clocks[0].clk);
	if (ret)
		goto put_clocks;
	ret = clk_rate_exclusive_get(iv->clocks[1].clk);
	if (ret)
		goto release_axi_rate;
	ret = clk_bulk_prepare_enable(ARRAY_SIZE(iv->clocks), iv->clocks);
	if (ret)
		goto release_pixel_rate;

	iv->axi_hz = clk_get_rate(iv->clocks[0].clk);
	iv->pixel_hz = clk_get_rate(iv->clocks[1].clk);
	return 0;

release_pixel_rate:
	clk_rate_exclusive_put(iv->clocks[1].clk);
release_axi_rate:
	clk_rate_exclusive_put(iv->clocks[0].clk);
put_clocks:
	clk_bulk_put(ARRAY_SIZE(iv->clocks), iv->clocks);
	return ret;
}

static void ironvideo_clocks_disable(struct ironvideo *iv)
{
	clk_bulk_disable_unprepare(ARRAY_SIZE(iv->clocks), iv->clocks);
	clk_rate_exclusive_put(iv->clocks[1].clk);
	clk_rate_exclusive_put(iv->clocks[0].clk);
	clk_bulk_put(ARRAY_SIZE(iv->clocks), iv->clocks);
}

static int ironvideo_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct ironvideo *iv;
	struct resource *res;
	struct videomode vm;
	enum iv_format format;
	int ret;

	iv = devm_drm_dev_alloc(dev, &ironvideo_drm_driver, struct ironvideo, drm);
	if (IS_ERR(iv))
		return PTR_ERR(iv);

	iv->regs = devm_platform_get_and_ioremap_resource(pdev, 0, &res);
	if (IS_ERR(iv->regs))
		return PTR_ERR(iv->regs);
	if (resource_size(res) < IV_REG_READ_ERRORS + sizeof(u32))
		return -EINVAL;
	iv->io = (struct iv_mmio) {
		.context = iv->regs, .read32 = ironvideo_read32,
		.write32 = ironvideo_write32, .barrier = ironvideo_write_barrier,
		.poll_delay = ironvideo_poll_delay, .time_us = ironvideo_time_us,
		.timeout_us = IV_TIMEOUT_US,
	};

	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret)
		return dev_err_probe(dev, ret, "cannot configure 32-bit scanout DMA\n");

	mutex_init(&iv->hw_lock);

	ret = ironvideo_clocks_enable(iv);
	if (ret)
		return dev_err_probe(dev, ret, "cannot enable and claim scanout clocks\n");

	/* Guard the extension mapping before discovery reads FORMAT_CAPS. */
	if (readl(iv->regs + IV_REG_VERSION) == IV_VERSION_FORMATS &&
	    resource_size(res) < IV_REG_PEAK_RATE_BYTES + sizeof(u32)) {
		ret = -EINVAL;
		goto clocks_off;
	}
	ret = ironvideo_errno(iv_discover(&iv->io, &iv->caps));
	if (ret)
		goto clocks_off;
	for (format = IV_FORMAT_XRGB8888; format <= IV_FORMAT_YUV420; format++)
		if (iv_format_supported(&iv->caps, format))
			iv->formats[iv->format_count++] = ironvideo_fourcc[format];

	/* Drain any boot scanout; leave the firmware framebuffer reserved by the board. */
	writel(0, iv->regs + IV_REG_MASK);
	ret = ironvideo_stop(iv);
	if (ret)
		return dev_err_probe(dev, ret, "boot scanout failed to drain; retaining clocks\n");

	if (!iv->axi_hz || !iv->pixel_hz ||
	    iv->axi_hz > U32_MAX || iv->pixel_hz > U32_MAX) {
		ret = -EINVAL;
		goto clocks_off;
	}

	ret = of_get_videomode(dev->of_node, &vm, OF_USE_NATIVE_MODE);
	if (ret)
		goto clocks_off;
	if (vm.pixelclock != iv->pixel_hz ||
	    (u64)vm.hactive + vm.hfront_porch + vm.hsync_len + vm.hback_porch > U16_MAX ||
	    (u64)vm.vactive + vm.vfront_porch + vm.vsync_len + vm.vback_porch > U16_MAX) {
		ret = -EINVAL;
		goto clocks_off;
	}
	drm_display_mode_from_videomode(&vm, &iv->native_mode);
	/* mode_valid uses crtc->dev, set by modeset_init. */
	ret = ironvideo_modeset_init(iv);
	if (ret)
		goto clocks_off;
	if (ironvideo_mode_valid(&iv->crtc, &iv->native_mode) != MODE_OK) {
		ret = -EINVAL;
		goto clocks_off;
	}

	platform_set_drvdata(pdev, iv);
	ret = device_create_file(dev, &dev_attr_row_stats);
	if (ret)
		goto clocks_off;
	ret = drm_dev_register(&iv->drm, 0);
	if (ret)
		goto remove_stats;
	if (iv_format_supported(&iv->caps, IV_FORMAT_XRGB8888))
		drm_client_setup_with_fourcc(&iv->drm, DRM_FORMAT_XRGB8888);
	else if (iv_format_supported(&iv->caps, IV_FORMAT_RGB565))
		drm_client_setup_with_fourcc(&iv->drm, DRM_FORMAT_RGB565);
	return 0;

remove_stats:
	device_remove_file(dev, &dev_attr_row_stats);
clocks_off:
	ironvideo_clocks_disable(iv);
	return dev_err_probe(dev, ret, "failed to initialise IronVideo\n");
}

static int ironvideo_drain(struct ironvideo *iv)
{
	int ret;

	mutex_lock(&iv->hw_lock);
	iv->quiescing = true;
	mutex_unlock(&iv->hw_lock);
	drm_atomic_helper_shutdown(&iv->drm);
	mutex_lock(&iv->hw_lock);
	ret = ironvideo_stop(iv);
	mutex_unlock(&iv->hw_lock);
	if (ret)
		drm_err(&iv->drm, "scanout failed to drain; retaining DMA memory and clocks (%d)\n",
			ret);
	return ret;
}

static void ironvideo_remove(struct platform_device *pdev)
{
	struct ironvideo *iv = platform_get_drvdata(pdev);

	device_remove_file(&pdev->dev, &dev_attr_row_stats);
	drm_dev_unplug(&iv->drm);
	if (ironvideo_drain(iv)) {
		/*
		 * No isolated reset can legally cancel an outstanding AXI read.
		 * Keep the allocation and its owner alive until system reset.
		 */
		if (iv->scanout)
			drm_dev_get(&iv->drm);
		return;
	}
	ironvideo_clocks_disable(iv);
}

static void ironvideo_shutdown(struct platform_device *pdev)
{
	ironvideo_drain(platform_get_drvdata(pdev));
}

static const struct of_device_id ironvideo_of_match[] = {
	{ .compatible = "ironkernel,ironvideo-v1" },
	{ }
};
MODULE_DEVICE_TABLE(of, ironvideo_of_match);

static struct platform_driver ironvideo_platform_driver = {
	.probe = ironvideo_probe,
	.remove = ironvideo_remove,
	.shutdown = ironvideo_shutdown,
	.driver = {
		.name = "ironvideo",
		.of_match_table = ironvideo_of_match,
	},
};
module_platform_driver(ironvideo_platform_driver);

MODULE_DESCRIPTION("IronKernel IronVideo DRM/KMS driver");
MODULE_LICENSE("GPL");

#endif /* __UBOOT__ */
