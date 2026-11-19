// SPDX-License-Identifier: GPL-2.0-only

#ifdef __UBOOT__
/* Polled U-Boot scanout for the IronVideo v1 register ABI. */
#include <cpu_func.h>
#include <fdtdec.h>
#include <asm/io.h>
#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/math64.h>
#include <mapmem.h>
#include <stdio.h>

#include "ironvideo_regs.h"
#include "ironvideo.h"

#define IV_POLL_US 50
#define IV_TIMEOUT_US 250000
#define IV_FRAME_POLL_MS 10
#define IV_MIN_SCANOUT_WAIT_MS 100

static int iv_wait(u8 __iomem *regs, u32 mask, u32 expected)
{
	unsigned int elapsed;

	for (elapsed = 0; elapsed < IV_TIMEOUT_US; elapsed += IV_POLL_US) {
		if ((readl(regs + IV_REG_STATUS) & mask) == expected)
			return 0;
		udelay(IV_POLL_US);
	}

	return -ETIMEDOUT;
}

static int iv_stop(u8 __iomem *regs)
{
	int ret;

	ret = iv_wait(regs, IV_ST_BUSY, 0);
	if (ret)
		return ret;

	writel(0, regs + IV_REG_CONTROL);
	return iv_wait(regs, IV_ST_BUSY | IV_ST_QUIESCED, IV_ST_QUIESCED);
}

static int iv_frame(u8 __iomem *regs, u32 *frame)
{
	int ret;

	ret = iv_wait(regs, IV_ST_SNAPSHOT_BUSY, 0);
	if (ret)
		return ret;

	writel(IV_CTL_ENABLE | IV_CTL_SNAPSHOT, regs + IV_REG_CONTROL);
	ret = iv_wait(regs, IV_ST_SNAPSHOT_BUSY, 0);
	if (!ret)
		*frame = readl(regs + IV_REG_FRAME);

	return ret;
}

static int iv_check_scanout(u8 __iomem *regs, u32 beats, u32 timeout_ms)
{
	u32 first, frame;
	unsigned int elapsed;
	int ret;

	ret = iv_frame(regs, &first);
	if (ret)
		return ret;

	for (elapsed = 0; elapsed < timeout_ms; elapsed += IV_FRAME_POLL_MS) {
		mdelay(IV_FRAME_POLL_MS);
		ret = iv_frame(regs, &frame);
		if (ret)
			return ret;
		if (readl(regs + IV_REG_FAULT) & IV_FAULT_ALL)
			return -EIO;
		if (frame - first >= 2 && readl(regs + IV_REG_READ_BEATS) >= beats)
			return 0;
	}

	return -ETIMEDOUT;
}

int ironvideo_boot_scanout(u8 __iomem *regs, u32 fb, u32 size, u32 stride,
			   const struct display_timing *mode, u32 color)
{
	const u32 active = IV_ST_CONFIGURED | IV_ST_APPLIED | IV_ST_REQUEST_ENABLE;
	u64 htotal, vtotal, frame_bytes, wait_ms;
	u32 width, height, data_bits, beat_bytes, row_bytes, x, y, polarity = 0;
	u8 *pixels;
	int ret;

	if (readl(regs + IV_REG_ID) != IV_ID ||
	    readl(regs + IV_REG_VERSION) != IV_VERSION)
		return -ENODEV;

	data_bits = readl(regs + IV_REG_CAPS) & IV_CAP_WIDTH_MASK;
	if (data_bits != 32 && data_bits != 64 && data_bits != 128)
		return -ENODEV;
	beat_bytes = data_bits / 8;

	width = mode->hactive.typ;
	height = mode->vactive.typ;
	htotal = (u64)width + mode->hfront_porch.typ +
		 mode->hsync_len.typ + mode->hback_porch.typ;
	vtotal = (u64)height + mode->vfront_porch.typ +
		 mode->vsync_len.typ + mode->vback_porch.typ;
	if (!width || !height || !mode->hsync_len.typ || !mode->vsync_len.typ ||
	    !mode->pixelclock.typ || htotal > U16_MAX || vtotal > U16_MAX ||
	    (mode->flags & (DISPLAY_FLAGS_INTERLACED | DISPLAY_FLAGS_DOUBLESCAN |
			    DISPLAY_FLAGS_DOUBLECLK)))
		return -EINVAL;

	row_bytes = width * sizeof(u32);
	frame_bytes = (u64)(height - 1) * stride + row_bytes;
	if (!size || (u64)fb + size > (1ULL << 32) || frame_bytes > size ||
	    stride < row_bytes || (fb | stride | row_bytes) % beat_bytes ||
	    row_bytes > readl(regs + IV_REG_FIFO_BYTES))
		return -EINVAL;

	if (mode->flags & DISPLAY_FLAGS_HSYNC_HIGH)
		polarity |= IV_POL_HPOS;
	if (mode->flags & DISPLAY_FLAGS_VSYNC_HIGH)
		polarity |= IV_POL_VPOS;
	wait_ms = div_u64(htotal * vtotal * 6000, mode->pixelclock.typ);
	wait_ms = clamp_t(u64, wait_ms, IV_MIN_SCANOUT_WAIT_MS, IV_TIMEOUT_US / 1000);

	writel(0, regs + IV_REG_MASK);
	ret = iv_stop(regs);
	if (ret)
		return ret;

	pixels = map_sysmem(fb, frame_bytes);
	if (!pixels)
		return -ENOMEM;
	for (y = 0; y < height; y++) {
		u32 *line = (u32 *)(pixels + y * stride);

		for (x = 0; x < width; x++)
			line[x] = cpu_to_le32(color);
	}
	flush_cache((ulong)pixels, frame_bytes);
	unmap_sysmem(pixels);

	writel(IV_FAULT_ALL, regs + IV_REG_FAULT);
	writel(fb, regs + IV_REG_BASE);
	writel(stride, regs + IV_REG_STRIDE);
	writel(fb, regs + IV_REG_WINDOW);
	writel(size, regs + IV_REG_SIZE);
	writel(width, regs + IV_REG_HA);
	writel(mode->hfront_porch.typ, regs + IV_REG_HF);
	writel(mode->hsync_len.typ, regs + IV_REG_HS);
	writel(mode->hback_porch.typ, regs + IV_REG_HB);
	writel(height, regs + IV_REG_VA);
	writel(mode->vfront_porch.typ, regs + IV_REG_VF);
	writel(mode->vsync_len.typ, regs + IV_REG_VS);
	writel(mode->vback_porch.typ, regs + IV_REG_VB);
	writel(polarity, regs + IV_REG_POLARITY);
	writel(row_bytes / beat_bytes, regs + IV_REG_PREFILL);

	writel(IV_CTL_ENABLE | IV_CTL_COMMIT, regs + IV_REG_CONTROL);
	ret = iv_wait(regs, IV_ST_BUSY, 0);
	if (!ret && (readl(regs + IV_REG_STATUS) & active) != active)
		ret = -EIO;
	if (!ret)
		ret = iv_check_scanout(regs, height * row_bytes / beat_bytes, wait_ms);
	if (ret) {
		printf("IronVideo: scanout fault status 0x%02x\n",
		       readl(regs + IV_REG_FAULT));
		if (iv_stop(regs))
			puts("IronVideo: scanout did not quiesce\n");
	}

	return ret;
}

#else

#include <linux/bitfield.h>
#include <linux/clk.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/sizes.h>
#include <linux/sysfs.h>
#include <video/of_display_timing.h>
#include <video/of_videomode.h>
#include <video/videomode.h>

#include <drm/clients/drm_client_setup.h>
#include <drm/drm_atomic.h>
#include <drm/drm_atomic_helper.h>
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

#include "ironvideo_regs.h"

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
	u32 beat_bytes;
	u32 fifo_bytes;

	struct mutex hw_lock; /* protects MMIO transactions and the active DMA reference */
	struct drm_framebuffer *scanout;
	u32 htotal;
	u64 epoch;
	bool quiescing;
};

#define to_ironvideo(drm_dev) container_of(drm_dev, struct ironvideo, drm)
#define IV_POLL_US	50
#define IV_TIMEOUT_US	250000
#define IV_DRAIN_MARGIN_US	50000

static int ironvideo_stop(struct ironvideo *iv)
{
	u32 status;
	int ret;

	ret = readl_poll_timeout(iv->regs + IV_REG_STATUS, status,
				 !(status & IV_ST_BUSY),
				 IV_POLL_US, IV_TIMEOUT_US);
	if (ret)
		return ret;

	if (!(status & IV_ST_QUIESCED)) {
		writel(0, iv->regs + IV_REG_CONTROL);
		ret = readl_poll_timeout(iv->regs + IV_REG_STATUS, status,
					 !(status & IV_ST_BUSY) &&
					 (status & IV_ST_QUIESCED),
					 IV_POLL_US, IV_TIMEOUT_US);
		if (ret)
			return ret;
	}

	if (iv->scanout) {
		drm_framebuffer_put(iv->scanout);
		iv->scanout = NULL;
		module_put(THIS_MODULE);
	}
	return 0;
}

static enum drm_mode_status ironvideo_mode_valid(struct drm_crtc *crtc,
						const struct drm_display_mode *mode)
{
	struct ironvideo *iv = to_ironvideo(crtc->dev);
	u32 line_bytes = mode->hdisplay * 4;
	u64 active_bytes, total_pixels;

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
	    mode->hsync_end <= mode->hsync_start || mode->htotal < mode->hsync_end ||
	    line_bytes > iv->fifo_bytes || !IS_ALIGNED(line_bytes, iv->beat_bytes))
		return MODE_BAD_HVALUE;
	if (!mode->vdisplay || mode->vsync_start < mode->vdisplay ||
	    mode->vsync_end <= mode->vsync_start || mode->vtotal < mode->vsync_end)
		return MODE_BAD_VVALUE;

	total_pixels = (u64)mode->htotal * mode->vtotal;
	/* Stop can take one complete frame plus the AXI drain handshake. */
	if (total_pixels * USEC_PER_SEC >
	    (u64)iv->pixel_hz * (IV_TIMEOUT_US - IV_DRAIN_MARGIN_US))
		return MODE_BAD;

	/* Necessary average throughput even with no AXI or DDR stalls. */
	active_bytes = (u64)line_bytes * mode->vdisplay;
	if (mul_u64_u64_div_u64(active_bytes, iv->pixel_hz, total_pixels) >
	    (u64)iv->axi_hz * iv->beat_bytes)
		return MODE_CLOCK_HIGH;
	return MODE_OK;
}

static int ironvideo_check(struct drm_device *drm, struct drm_atomic_commit *state)
{
	struct ironvideo *iv = to_ironvideo(drm);
	struct drm_plane_state *plane = drm_atomic_get_new_plane_state(state, &iv->plane);
	struct drm_crtc_state *crtc;
	struct drm_framebuffer *fb;
	struct drm_gem_dma_object *obj;
	u64 base, span, row_bytes;
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
	    fb->format->format != DRM_FORMAT_XRGB8888 ||
	    fb->modifier != DRM_FORMAT_MOD_LINEAR ||
	    plane->src_x || plane->src_y || plane->crtc_x || plane->crtc_y ||
	    plane->crtc_w != crtc->mode.hdisplay || plane->crtc_h != crtc->mode.vdisplay ||
	    plane->src_w != plane->crtc_w << 16 || plane->src_h != plane->crtc_h << 16)
		return -EINVAL;

	obj = drm_fb_dma_get_gem_obj(fb, 0);
	row_bytes = (u64)plane->crtc_w * 4;
	span = (u64)(plane->crtc_h - 1) * fb->pitches[0] + row_bytes;
	base = (u64)obj->dma_addr + fb->offsets[0];
	if (!IS_ALIGNED(base, iv->beat_bytes) ||
	    !IS_ALIGNED(fb->pitches[0], iv->beat_bytes) ||
	    fb->pitches[0] < row_bytes || span > U32_MAX ||
	    base > U32_MAX || base + span > (1ULL << 32) ||
	    (u64)fb->offsets[0] + span > obj->base.size)
		return -EINVAL;
	return 0;
}

static int ironvideo_start(struct ironvideo *iv, const struct drm_display_mode *mode,
			   struct drm_framebuffer *fb)
{
	struct drm_gem_dma_object *obj = drm_fb_dma_get_gem_obj(fb, 0);
	u32 base = obj->dma_addr + fb->offsets[0];
	u32 stride = fb->pitches[0];
	u32 row_bytes = mode->hdisplay * 4;
	u32 span = (mode->vdisplay - 1) * stride + row_bytes;
	u32 polarity = 0;
	u32 status;
	int ret;

	if (mode->flags & DRM_MODE_FLAG_PHSYNC)
		polarity |= IV_POL_HPOS;
	if (mode->flags & DRM_MODE_FLAG_PVSYNC)
		polarity |= IV_POL_VPOS;

	if (!try_module_get(THIS_MODULE))
		return -ENODEV;
	drm_framebuffer_get(fb);
	iv->scanout = fb;
	iv->htotal = 0;
	writel(IV_FAULT_ALL, iv->regs + IV_REG_FAULT);
	writel(base, iv->regs + IV_REG_BASE);
	writel(stride, iv->regs + IV_REG_STRIDE);
	writel(base, iv->regs + IV_REG_WINDOW);
	writel(span, iv->regs + IV_REG_SIZE);
	writel(mode->hdisplay, iv->regs + IV_REG_HA);
	writel(mode->hsync_start - mode->hdisplay, iv->regs + IV_REG_HF);
	writel(mode->hsync_end - mode->hsync_start, iv->regs + IV_REG_HS);
	writel(mode->htotal - mode->hsync_end, iv->regs + IV_REG_HB);
	writel(mode->vdisplay, iv->regs + IV_REG_VA);
	writel(mode->vsync_start - mode->vdisplay, iv->regs + IV_REG_VF);
	writel(mode->vsync_end - mode->vsync_start, iv->regs + IV_REG_VS);
	writel(mode->vtotal - mode->vsync_end, iv->regs + IV_REG_VB);
	writel(polarity, iv->regs + IV_REG_POLARITY);
	writel(row_bytes / iv->beat_bytes, iv->regs + IV_REG_PREFILL);
	dma_wmb();
	writel(IV_CTL_ENABLE | IV_CTL_COMMIT, iv->regs + IV_REG_CONTROL);

	ret = readl_poll_timeout(iv->regs + IV_REG_STATUS, status,
				 !(status & IV_ST_BUSY), IV_POLL_US, IV_TIMEOUT_US);
	if (ret)
		return ret;
	if (!(status & IV_ST_CONFIGURED) || !(status & IV_ST_APPLIED) ||
	    (readl(iv->regs + IV_REG_FAULT) & IV_FAULT_CONTROL))
		return -EIO;

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

static const u32 ironvideo_formats[] = { DRM_FORMAT_XRGB8888 };
static const u64 ironvideo_modifiers[] = { DRM_FORMAT_MOD_LINEAR, DRM_FORMAT_MOD_INVALID };

static int ironvideo_modeset_init(struct ironvideo *iv)
{
	struct drm_device *drm = &iv->drm;
	int ret;

	ret = drmm_mode_config_init(drm);
	if (ret)
		return ret;
	drm->mode_config.min_width = iv->beat_bytes / 4;
	drm->mode_config.min_height = 1;
	drm->mode_config.max_width = iv->fifo_bytes / 4;
	drm->mode_config.max_height = U16_MAX;
	drm->mode_config.preferred_depth = 24;
	drm->mode_config.funcs = &ironvideo_mode_funcs;
	drm->mode_config.helper_private = &ironvideo_mode_helpers;

	ret = drm_universal_plane_init(drm, &iv->plane, 0, &ironvideo_plane_funcs,
				       ironvideo_formats, ARRAY_SIZE(ironvideo_formats),
				       ironvideo_modifiers, DRM_PLANE_TYPE_PRIMARY, NULL);
	if (ret)
		return ret;

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
	u32 status, htotal, base_status, control, faults, first_fault, first_addr;
	u32 underflows, low_water, frames, xy, fault_xy;
	int tries, ret;

	mutex_lock(&iv->hw_lock);
	ret = readl_poll_timeout(iv->regs + IV_REG_STATUS, base_status,
				 !(base_status & (IV_ST_BUSY | IV_ST_SNAPSHOT_BUSY)),
				 IV_POLL_US, IV_TIMEOUT_US);
	if (ret)
		goto unlock;
	control = readl(iv->regs + IV_REG_CONTROL);
	writel((control & (IV_CTL_ENABLE | IV_CTL_PATTERN)) | IV_CTL_SNAPSHOT,
	       iv->regs + IV_REG_CONTROL);
	ret = readl_poll_timeout(iv->regs + IV_REG_STATUS, base_status,
				 !(base_status & IV_ST_SNAPSHOT_BUSY),
				 IV_POLL_US, IV_TIMEOUT_US);
	if (ret)
		goto unlock;

	underflows = readl(iv->regs + IV_REG_UNDERFLOW);
	low_water = readl(iv->regs + IV_REG_LOW_WATER);
	frames = readl(iv->regs + IV_REG_FRAME);
	xy = readl(iv->regs + IV_REG_XY);
	fault_xy = readl(iv->regs + IV_REG_FAULT_XY);
	faults = readl(iv->regs + IV_REG_FAULT);
	first_fault = readl(iv->regs + IV_REG_FIRST);
	first_addr = readl(iv->regs + IV_REG_FAULT_ADDR);

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
	after = readl(iv->regs + IV_REG_ROW_SAMPLES);
	beats = readl(iv->regs + IV_REG_READ_BEATS);
	bursts = readl(iv->regs + IV_REG_READ_BURSTS);
	errors = readl(iv->regs + IV_REG_READ_ERRORS);
	status = readl(iv->regs + IV_REG_DMA_STATUS);
	htotal = iv->htotal;
	epoch = iv->epoch;
	mutex_unlock(&iv->hw_lock);

	current_bps = last ? div_u64((u64)bytes * iv->pixel_hz, last) : 0;
	peak_bps = best ? div_u64((u64)bytes * iv->pixel_hz, best) : 0;
	budget_permille = htotal ? div_u64((u64)worst * 1000, htotal) : 0;

	return sysfs_emit(buf,
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
			  epoch, iv->pixel_hz, htotal, iv->axi_hz, iv->beat_bytes * 8,
			  iv->fifo_bytes, bytes, samples, after, last, best,
			  worst, current_bps, peak_bps, budget_permille, beats, bursts,
			  errors, status, base_status, underflows, low_water, frames,
			  xy, fault_xy, faults, first_fault, first_addr);

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
	u32 caps, width, aw, burst;
	int ret;

	iv = devm_drm_dev_alloc(dev, &ironvideo_drm_driver, struct ironvideo, drm);
	if (IS_ERR(iv))
		return PTR_ERR(iv);

	iv->regs = devm_platform_get_and_ioremap_resource(pdev, 0, &res);
	if (IS_ERR(iv->regs))
		return PTR_ERR(iv->regs);
	if (resource_size(res) < IV_REG_READ_ERRORS + sizeof(u32))
		return -EINVAL;

	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret)
		return dev_err_probe(dev, ret, "cannot configure 32-bit scanout DMA\n");

	mutex_init(&iv->hw_lock);

	ret = ironvideo_clocks_enable(iv);
	if (ret)
		return dev_err_probe(dev, ret, "cannot enable and claim scanout clocks\n");

	if (readl(iv->regs + IV_REG_ID) != IV_ID ||
	    readl(iv->regs + IV_REG_VERSION) != IV_VERSION) {
		ret = -ENODEV;
		goto clocks_off;
	}

	/* Drain any boot scanout; leave the firmware framebuffer reserved by the board. */
	writel(0, iv->regs + IV_REG_MASK);
	ret = ironvideo_stop(iv);
	if (ret)
		return dev_err_probe(dev, ret, "boot scanout failed to drain; retaining clocks\n");

	caps = readl(iv->regs + IV_REG_CAPS);
	width = FIELD_GET(IV_CAP_WIDTH_MASK, caps);
	aw = FIELD_GET(IV_CAP_FIFO_AW_MASK, caps);
	burst = FIELD_GET(IV_CAP_BURST_MASK, caps);
	iv->beat_bytes = width / 8;
	iv->fifo_bytes = readl(iv->regs + IV_REG_FIFO_BYTES);
	if ((width != 32 && width != 64 && width != 128) ||
	    aw > 15 || !burst || burst > 256 ||
	    iv->fifo_bytes < SZ_16K || iv->fifo_bytes > SZ_128K ||
	    iv->fifo_bytes != (iv->beat_bytes << aw) ||
	    !iv->axi_hz || !iv->pixel_hz || iv->axi_hz > U32_MAX || iv->pixel_hz > U32_MAX) {
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
	drm_client_setup_with_fourcc(&iv->drm, DRM_FORMAT_XRGB8888);
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
