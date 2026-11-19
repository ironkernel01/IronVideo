/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef IRONVIDEO_CORE_H
#define IRONVIDEO_CORE_H

#include "ironvideo_regs.h"

/* Common freestanding interface. MMIO callbacks convert little-endian words. */
typedef unsigned int iv_u32;
typedef unsigned long long iv_u64;

enum iv_format {
	IV_FORMAT_XRGB8888 = 0,
	IV_FORMAT_RGB565 = 1,
	IV_FORMAT_YUV422 = 2,	/* Packed YUYV byte order. */
	IV_FORMAT_YUV420 = 3,	/* NV12: Y plane, then separate interleaved Cb/Cr plane. */
};

enum iv_result {
	IV_OK = 0,
	IV_INVALID = -1,
	IV_UNSUPPORTED = -2,
	IV_TIMEOUT = -3,
	IV_FAULT = -4,
};

#define IV_FORMAT_MASK_ALL	0x0fU
#define IV_FORMAT_BIT(id)	(1U << (id))
#define IV_NV12_SOURCE_BEATS	3U
#define IV_NV12_AXI_CYCLES	5U

struct iv_mmio {
	void *context;
	iv_u32 (*read32)(void *context, iv_u32 offset);
	void (*write32)(void *context, iv_u32 offset, iv_u32 value);
	void (*barrier)(void *context);
	void (*poll_delay)(void *context);
	iv_u64 (*time_us)(void *context);
	iv_u32 timeout_us;
};

struct iv_caps {
	iv_u32 version, format_mask, beat_bytes, burst_beats, fifo_bytes;
};

struct iv_mode {
	iv_u32 h_active, h_front, h_sync, h_back;
	iv_u32 v_active, v_front, v_sync, v_back;
	iv_u32 polarity, prefill, pixel_hz;
};

struct iv_fb_plane {
	iv_u32 base, stride, window_base, window_bytes;
};

struct iv_scanout {
	struct iv_mode mode;
	enum iv_format format;
	iv_u32 pattern;
	struct iv_fb_plane primary, uv;
};

struct iv_geometry {
	iv_u32 row_bytes, uv_row_bytes, uv_height, prefill_beats;
	iv_u64 frame_bytes;
};

struct iv_snapshot {
	iv_u32 status, underflows, fifo_low_water, raster_xy, frames;
	iv_u32 underflow_xy, faults, first_fault, first_fault_addr;
	iv_u32 read_beats, read_bursts, read_errors;
};

static inline int iv_discover(const struct iv_mmio *io, struct iv_caps *caps)
{
	iv_u32 bits, shift, value;

	if (io->read32(io->context, IV_REG_ID) != IV_ID)
		return IV_UNSUPPORTED;
	caps->version = io->read32(io->context, IV_REG_VERSION);
	if (caps->version != IV_VERSION_LEGACY &&
	    caps->version != IV_VERSION_FORMATS)
		return IV_UNSUPPORTED;
	value = io->read32(io->context, IV_REG_CAPS);
	bits = value & IV_CAP_WIDTH_MASK;
	shift = (value & IV_CAP_FIFO_AW_MASK) >> 8;
	caps->burst_beats = (value & IV_CAP_BURST_MASK) >> 16;
	caps->fifo_bytes = io->read32(io->context, IV_REG_FIFO_BYTES);
	caps->beat_bytes = bits / 8;
	if ((bits != 32 && bits != 64 && bits != 128) || shift > 15 ||
	    !caps->burst_beats || caps->burst_beats > 256 ||
	    caps->fifo_bytes < 16384 || caps->fifo_bytes > 131072 ||
	    caps->fifo_bytes != (caps->beat_bytes << shift))
		return IV_INVALID;
	caps->format_mask = IV_FORMAT_BIT(IV_FORMAT_XRGB8888);
	if (caps->version == IV_VERSION_FORMATS) {
		caps->format_mask = io->read32(io->context, IV_REG_FORMAT_CAPS);
		if (!caps->format_mask || (caps->format_mask & ~IV_FORMAT_MASK_ALL))
			return IV_INVALID;
	}
	return IV_OK;
}

static inline int iv_format_supported(const struct iv_caps *caps,
				     enum iv_format format)
{
	return (unsigned int)format <= IV_FORMAT_YUV420 &&
	       (caps->version != IV_VERSION_LEGACY || format == IV_FORMAT_XRGB8888) &&
	       (caps->format_mask & IV_FORMAT_BIT(format));
}

static inline enum iv_format iv_preferred_format(const struct iv_caps *caps)
{
	enum iv_format format;

	for (format = IV_FORMAT_XRGB8888; format < IV_FORMAT_YUV420; format++)
		if (iv_format_supported(caps, format))
			return format;
	return IV_FORMAT_YUV420;
}

static inline int iv_format_geometry(const struct iv_caps *caps,
				     enum iv_format format, iv_u32 width,
				     iv_u32 height, struct iv_geometry *geometry)
{
	iv_u32 beat_bytes = caps->beat_bytes;
	iv_u32 row, uv_row = 0, uv_height = 0, prefill_bytes;

	if (!iv_format_supported(caps, format))
		return IV_UNSUPPORTED;
	if (!width || !height || width > 65535 || height > 65535 || !beat_bytes)
		return IV_INVALID;

	switch (format) {
	case IV_FORMAT_XRGB8888:
		row = 4 * width;
		break;
	case IV_FORMAT_RGB565:
		row = 2 * width;
		break;
	case IV_FORMAT_YUV422:
		if (width & 1)
			return IV_INVALID;
		row = 2 * width;
		break;
	case IV_FORMAT_YUV420:
		if ((width | height) & 1)
			return IV_INVALID;
		row = width;
		uv_row = width;
		uv_height = height / 2;
		break;
	default:
		return IV_UNSUPPORTED;
	}

	prefill_bytes = row + uv_row;
	if ((row | uv_row) % beat_bytes || prefill_bytes > caps->fifo_bytes ||
	    prefill_bytes / beat_bytes > 65535)
		return IV_INVALID;
	geometry->row_bytes = row;
	geometry->uv_row_bytes = uv_row;
	geometry->uv_height = uv_height;
	geometry->prefill_beats = prefill_bytes / beat_bytes;
	geometry->frame_bytes = (iv_u64)row * height + (iv_u64)uv_row * uv_height;
	return IV_OK;
}

static inline iv_u64 iv_plane_span(iv_u32 stride, iv_u32 row, iv_u32 height)
{
	return height ? (iv_u64)(height - 1) * stride + row : 0;
}

static inline int iv_plane_valid(const struct iv_fb_plane *plane, iv_u32 row,
				 iv_u32 height, iv_u32 beat_bytes)
{
	iv_u64 end = (iv_u64)plane->window_base + plane->window_bytes;
	iv_u64 span = iv_plane_span(plane->stride, row, height);

	return row && height && beat_bytes && plane->window_bytes &&
	       plane->base >= plane->window_base && plane->stride >= row &&
	       !((plane->base | plane->stride | row) % beat_bytes) &&
	       end <= (1ULL << 32) && (iv_u64)plane->base + span <= end;
}

static inline int iv_check_mode(const struct iv_mode *mode)
{
	iv_u64 htotal = (iv_u64)mode->h_active + mode->h_front + mode->h_sync + mode->h_back;
	iv_u64 vtotal = (iv_u64)mode->v_active + mode->v_front + mode->v_sync + mode->v_back;

	return mode->h_active && mode->v_active && mode->h_sync && mode->v_sync &&
	       htotal <= 65535 && vtotal <= 65535 && !(mode->polarity & ~3U);
}

static inline int iv_validate(const struct iv_caps *caps,
			      const struct iv_scanout *config)
{
	const struct iv_mode *mode = &config->mode;
	struct iv_geometry geometry;
	int ret;

	if (!iv_check_mode(mode))
		return IV_INVALID;
	if (config->pattern)
		return IV_OK;
	ret = iv_format_geometry(caps, config->format, mode->h_active,
				 mode->v_active, &geometry);
	if (ret)
		return ret;
	if (!mode->prefill || mode->prefill > 65535 ||
	    mode->prefill > caps->fifo_bytes / caps->beat_bytes ||
	    !iv_plane_valid(&config->primary, geometry.row_bytes,
			    mode->v_active, caps->beat_bytes))
		return IV_INVALID;
	if (geometry.uv_height &&
	    !iv_plane_valid(&config->uv, geometry.uv_row_bytes,
			    geometry.uv_height, caps->beat_bytes))
		return IV_INVALID;
	return IV_OK;
}

static inline int iv_wait(const struct iv_mmio *io, iv_u32 mask,
			  iv_u32 expected, iv_u32 poll_budget)
{
	iv_u64 start = io->time_us ? io->time_us(io->context) : 0;

	while (poll_budget--) {
		if ((io->read32(io->context, IV_REG_STATUS) & mask) == expected)
			return IV_OK;
		if (io->time_us && io->time_us(io->context) - start >= io->timeout_us)
			break;
		if (io->poll_delay)
			io->poll_delay(io->context);
	}
	return IV_TIMEOUT;
}

static inline int iv_stop(const struct iv_mmio *io, iv_u32 poll_budget)
{
	int ret = iv_wait(io, IV_ST_BUSY, 0, poll_budget);

	if (ret || (io->read32(io->context, IV_REG_STATUS) & IV_ST_QUIESCED))
		return ret;
	io->write32(io->context, IV_REG_CONTROL, 0);
	return iv_wait(io, IV_ST_BUSY | IV_ST_QUIESCED, IV_ST_QUIESCED, poll_budget);
}

static inline void iv_clear_faults(const struct iv_mmio *io, iv_u32 mask)
{
	io->write32(io->context, IV_REG_FAULT, mask & IV_FAULT_ALL);
}

static inline int iv_commit(const struct iv_mmio *io, const struct iv_caps *caps,
			    const struct iv_scanout *config, int enable,
			    iv_u32 poll_budget)
{
	const struct iv_mode *mode = &config->mode;
	iv_u32 control = IV_CTL_COMMIT | (enable ? IV_CTL_ENABLE : 0) |
			 (config->pattern ? IV_CTL_PATTERN : 0);
	iv_u32 mask = IV_ST_CONFIGURED | IV_ST_APPLIED;
	iv_u32 expected = IV_ST_CONFIGURED | (enable ? IV_ST_APPLIED : 0);
	int use_uv = !config->pattern && config->format == IV_FORMAT_YUV420;
	int ret = iv_validate(caps, config);

	if (ret)
		return ret;
	ret = iv_wait(io, IV_ST_BUSY, 0, poll_budget);
	if (ret)
		return ret;
	iv_clear_faults(io, IV_FAULT_CONTROL);
	io->write32(io->context, IV_REG_BASE, config->pattern ? 0 : config->primary.base);
	io->write32(io->context, IV_REG_STRIDE, config->pattern ? 0 : config->primary.stride);
	io->write32(io->context, IV_REG_WINDOW, config->pattern ? 0 : config->primary.window_base);
	io->write32(io->context, IV_REG_SIZE, config->pattern ? 0 : config->primary.window_bytes);
	io->write32(io->context, IV_REG_HA, mode->h_active);
	io->write32(io->context, IV_REG_HF, mode->h_front);
	io->write32(io->context, IV_REG_HS, mode->h_sync);
	io->write32(io->context, IV_REG_HB, mode->h_back);
	io->write32(io->context, IV_REG_VA, mode->v_active);
	io->write32(io->context, IV_REG_VF, mode->v_front);
	io->write32(io->context, IV_REG_VS, mode->v_sync);
	io->write32(io->context, IV_REG_VB, mode->v_back);
	io->write32(io->context, IV_REG_POLARITY, mode->polarity);
	io->write32(io->context, IV_REG_PREFILL, config->pattern ? 0 : mode->prefill);
	if (caps->version == IV_VERSION_FORMATS) {
		io->write32(io->context, IV_REG_FORMAT,
			    config->pattern ? iv_preferred_format(caps) : config->format);
		io->write32(io->context, IV_REG_UV_BASE, use_uv ? config->uv.base : 0);
		io->write32(io->context, IV_REG_UV_STRIDE, use_uv ? config->uv.stride : 0);
		io->write32(io->context, IV_REG_UV_WINDOW, use_uv ? config->uv.window_base : 0);
		io->write32(io->context, IV_REG_UV_SIZE, use_uv ? config->uv.window_bytes : 0);
	}
	if (io->barrier)
		(io->barrier)(io->context);
	io->write32(io->context, IV_REG_CONTROL, control);
	ret = iv_wait(io, IV_ST_BUSY, 0, poll_budget);
	if (ret)
		return ret;
	if ((io->read32(io->context, IV_REG_STATUS) & mask) != expected ||
	    (io->read32(io->context, IV_REG_FAULT) & IV_FAULT_CONTROL))
		return IV_FAULT;
	return IV_OK;
}

static inline int iv_read_snapshot(const struct iv_mmio *io,
				   struct iv_snapshot *snapshot, iv_u32 poll_budget)
{
	iv_u32 control;
	int ret = iv_wait(io, IV_ST_BUSY | IV_ST_SNAPSHOT_BUSY, 0, poll_budget);

	if (ret)
		return ret;
	control = io->read32(io->context, IV_REG_CONTROL) & (IV_CTL_ENABLE | IV_CTL_PATTERN);
	io->write32(io->context, IV_REG_CONTROL, control | IV_CTL_SNAPSHOT);
	ret = iv_wait(io, IV_ST_SNAPSHOT_BUSY, 0, poll_budget);
	if (ret)
		return ret;
	snapshot->status = io->read32(io->context, IV_REG_STATUS);
	snapshot->underflows = io->read32(io->context, IV_REG_UNDERFLOW);
	snapshot->fifo_low_water = io->read32(io->context, IV_REG_LOW_WATER);
	snapshot->raster_xy = io->read32(io->context, IV_REG_XY);
	snapshot->frames = io->read32(io->context, IV_REG_FRAME);
	snapshot->underflow_xy = io->read32(io->context, IV_REG_FAULT_XY);
	snapshot->faults = io->read32(io->context, IV_REG_FAULT);
	snapshot->first_fault = io->read32(io->context, IV_REG_FIRST);
	snapshot->first_fault_addr = io->read32(io->context, IV_REG_FAULT_ADDR);
	snapshot->read_beats = io->read32(io->context, IV_REG_READ_BEATS);
	snapshot->read_bursts = io->read32(io->context, IV_REG_READ_BURSTS);
	snapshot->read_errors = io->read32(io->context, IV_REG_READ_ERRORS);
	return IV_OK;
}

#endif
