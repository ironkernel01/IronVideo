/* SPDX-License-Identifier: GPL-2.0-only */
/* Portable register, format and geometry contract exercised without hardware. */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "ironvideo_core.h"

struct fixture {
	iv_u32 registers[IV_REG_CLOCK_SELECT / 4 + 1];
	iv_u32 extension_reads, extension_writes, writes, barriers, delays;
	iv_u32 next_status, status_reads;
	int frozen, reject_commit;
};

static iv_u32 fixture_read(void *context, iv_u32 offset)
{
	struct fixture *f = context;

	assert(!(offset & 3) && offset <= IV_REG_CLOCK_SELECT);
	if (offset >= IV_REG_FORMAT_CAPS)
		f->extension_reads++;
	if (offset == IV_REG_STATUS && f->status_reads && !f->frozen &&
	    !--f->status_reads)
		f->registers[offset / 4] = f->next_status;
	return f->registers[offset / 4];
}

static void fixture_write(void *context, iv_u32 offset, iv_u32 value)
{
	struct fixture *f = context;

	assert(!(offset & 3) && offset <= IV_REG_CLOCK_SELECT);
	f->writes++;
	if (offset >= IV_REG_FORMAT_CAPS)
		f->extension_writes++;
	if (offset == IV_REG_FAULT) {
		f->registers[offset / 4] &= ~value;
		return;
	}
	if (offset == IV_REG_CLOCK_SELECT) {
		f->registers[offset / 4] = f->frozen ? value :
			IV_CLOCK_READY | (value ? IV_CLOCK_ACTIVE | IV_CLOCK_REQUEST : 0);
		return;
	}
	f->registers[offset / 4] = value;
	if (offset != IV_REG_CONTROL)
		return;
	if (value & IV_CTL_COMMIT) {
		if (f->reject_commit) {
			f->registers[IV_REG_FAULT / 4] |= IV_FAULT_CONTROL;
			return;
		}
		f->registers[IV_REG_STATUS / 4] = IV_ST_BUSY;
		f->next_status = IV_ST_CONFIGURED |
			(value & IV_CTL_ENABLE ? IV_ST_APPLIED : IV_ST_QUIESCED);
		f->status_reads = 2;
	} else if (value & IV_CTL_SNAPSHOT) {
		f->next_status = f->registers[IV_REG_STATUS / 4];
		f->registers[IV_REG_STATUS / 4] |= IV_ST_SNAPSHOT_BUSY;
		f->status_reads = 2;
	} else {
		f->registers[IV_REG_STATUS / 4] = IV_ST_BUSY;
		f->next_status = IV_ST_CONFIGURED | IV_ST_QUIESCED;
		f->status_reads = 2;
	}
	f->registers[offset / 4] &= IV_CTL_ENABLE | IV_CTL_PATTERN;
}

static void fixture_barrier(void *context)
{
	((struct fixture *)context)->barriers++;
}

static void fixture_delay(void *context)
{
	((struct fixture *)context)->delays++;
}

static iv_u64 fixture_time(void *context)
{
	return ((struct fixture *)context)->delays;
}

static const iv_u32 widths[] = { 32, 64, 128 };

static void fixture_init(struct fixture *f, iv_u32 width, iv_u32 mask)
{
	iv_u32 addr_bits = width == 32 ? 12 : width == 64 ? 11 : 10;

	memset(f, 0, sizeof(*f));
	f->registers[IV_REG_ID / 4] = IV_ID;
	f->registers[IV_REG_VERSION / 4] =
		mask == 1 ? IV_VERSION_LEGACY : IV_VERSION_FORMATS;
	f->registers[IV_REG_CAPS / 4] = width | (addr_bits << 8) | (32 << 16);
	f->registers[IV_REG_FIFO_BYTES / 4] = 16384;
	f->registers[IV_REG_FORMAT_CAPS / 4] = mask;
	f->registers[IV_REG_STATUS / 4] = IV_ST_QUIESCED;
}

static struct iv_scanout make_config(enum iv_format format)
{
	struct iv_scanout config = {
		.format = format,
		.mode = {
			.h_active = 1280, .h_front = 110, .h_sync = 40, .h_back = 220,
			.v_active = 720, .v_front = 5, .v_sync = 5, .v_back = 20,
			.polarity = IV_POL_HPOS | IV_POL_VPOS, .pixel_hz = 74250000,
		},
		.primary = { 0x88000000, 0, 0x88000000, 0x00400000 },
		.uv = { 0x89000000, 1280 + 16, 0x89000000, 0x00100000 },
	};

	return config;
}

int main(void)
{
	static const iv_u32 primary_bytes[] = { 5120, 2560, 2560, 1280 };
	static const iv_u64 frame_bytes[] = { 3686400, 1843200, 1843200, 1382400 };
	struct fixture f;
	struct iv_mmio io = { .context = &f, .read32 = fixture_read,
		.write32 = fixture_write, .barrier = fixture_barrier,
		.poll_delay = fixture_delay, .time_us = fixture_time, .timeout_us = 3 };
	struct iv_caps caps;
	struct iv_geometry geometry = { 0 };
	struct iv_snapshot snapshot;
	enum iv_format format;
	iv_u32 index, mask, writes;
	struct iv_scanout config;

	for (index = 0; index < sizeof(widths) / sizeof(widths[0]); index++) {
		for (mask = 1; mask <= IV_FORMAT_MASK_ALL; mask++) {
			fixture_init(&f, widths[index], mask);
			assert(iv_discover(&io, &caps) == IV_OK);
			assert(caps.format_mask == mask && caps.beat_bytes == widths[index] / 8);
			assert(f.extension_reads == (mask == 1 ? 0 : 1));
			assert(iv_format_supported(&caps, iv_preferred_format(&caps)));
			assert(!(mask & (IV_FORMAT_BIT(iv_preferred_format(&caps)) - 1)));
			for (format = IV_FORMAT_XRGB8888; format <= IV_FORMAT_YUV420; format++) {
				config = make_config(format);
				writes = f.writes;
				if (!(mask & IV_FORMAT_BIT(format))) {
					assert(iv_commit(&io, &caps, &config, 1, 8) == IV_UNSUPPORTED);
					assert(f.writes == writes);
					continue;
				}
				assert(iv_format_geometry(&caps, format, 1280, 720, &geometry) == IV_OK);
				assert(geometry.row_bytes == primary_bytes[format]);
				assert(geometry.frame_bytes == frame_bytes[format]);
				assert(geometry.uv_height == (format == IV_FORMAT_YUV420 ? 360 : 0));
				assert(geometry.prefill_beats * caps.beat_bytes ==
				       geometry.row_bytes + geometry.uv_row_bytes);
				config.primary.stride = geometry.row_bytes + 16;
				config.mode.prefill = geometry.prefill_beats;
				assert(iv_commit(&io, &caps, &config, 1, 8) == IV_OK);
				assert(f.registers[IV_REG_STRIDE / 4] == config.primary.stride);
				assert(f.registers[IV_REG_UV_BASE / 4] ==
				       (format == IV_FORMAT_YUV420 ? config.uv.base : 0));
				if (mask != 1)
					assert(f.registers[IV_REG_FORMAT / 4] == format);
				assert(iv_stop(&io, 8) == IV_OK);
			}
			if (mask == 1)
				assert(f.extension_writes == 0 && f.extension_reads == 0);
		}
	}

	fixture_init(&f, 128, IV_FORMAT_MASK_ALL);
	assert(iv_discover(&io, &caps) == IV_OK);
	assert(iv_format_geometry(&caps, IV_FORMAT_YUV420, 1280, 720, &geometry) == IV_OK);
	/* 720p60 fits 25 MHz x32 raw AXI, but exceeds the NV12 expansion ceiling. */
	assert(geometry.frame_bytes * 60 < 25000000ULL * 4);
	assert(geometry.frame_bytes * 60 * IV_NV12_AXI_CYCLES >
	       25000000ULL * 4 * IV_NV12_SOURCE_BEATS);
	assert(geometry.frame_bytes * 60 * IV_NV12_AXI_CYCLES <
	       50000000ULL * 4 * IV_NV12_SOURCE_BEATS);
	config = make_config(IV_FORMAT_YUV420);
	config.primary.stride = 1280;
	config.mode.prefill = 160;
	assert(iv_validate(&caps, &config) == IV_OK);
	config.uv.window_bytes = 1;
	assert(iv_validate(&caps, &config) == IV_INVALID);
	config.uv.window_bytes = 0x100000;
	config.uv.base++;
	assert(iv_validate(&caps, &config) == IV_INVALID);
	assert(iv_format_geometry(&caps, IV_FORMAT_YUV420, 1280, 719, &geometry) == IV_INVALID);
	assert(iv_format_geometry(&caps, IV_FORMAT_YUV420, 1279, 720, &geometry) == IV_INVALID);
	assert(iv_format_geometry(&caps, IV_FORMAT_YUV422, 1279, 720, &geometry) == IV_INVALID);
	assert(iv_format_geometry(&caps, IV_FORMAT_XRGB8888, 1281, 720, &geometry) == IV_INVALID);
	assert(iv_format_geometry(&caps, IV_FORMAT_YUV420, 16384, 720, &geometry) == IV_INVALID);
	assert(iv_format_geometry(&caps, (enum iv_format)-1, 1280, 720, &geometry) == IV_UNSUPPORTED);
	assert(!iv_plane_valid(&(struct iv_fb_plane){0xfffffff0, 16, 0xfffffff0, 17}, 16, 1, 16));
	assert(iv_plane_valid(&(struct iv_fb_plane){0xfffffff0, 16, 0xfffffff0, 16}, 16, 1, 16));
	assert(!iv_plane_valid(&(struct iv_fb_plane){0xfffffff0, 16, 0xfffffff0, 16}, 16, 2, 16));
	assert(!iv_plane_valid(&(struct iv_fb_plane){0xfffffff0, 16, 0xfffffff0, 16}, 16, 1, 0));

	config = make_config(IV_FORMAT_YUV420);
	config.primary.stride = 1280;
	config.mode.prefill = 160;
	f.reject_commit = 1;
	assert(iv_commit(&io, &caps, &config, 1, 8) == IV_FAULT);
	assert(f.registers[IV_REG_FAULT / 4] == IV_FAULT_CONTROL);
	f.reject_commit = 0;
	assert(iv_commit(&io, &caps, &config, 1, 8) == IV_OK);
	assert(f.barriers == 2 && f.registers[IV_REG_FAULT / 4] == 0);
	f.registers[IV_REG_FRAME / 4] = 123;
	f.registers[IV_REG_READ_BEATS / 4] = 456;
	f.registers[IV_REG_CONTROL / 4] = IV_CTL_ENABLE | IV_CTL_PATTERN;
	assert(iv_read_snapshot(&io, &snapshot, 8) == IV_OK);
	assert(snapshot.frames == 123 && snapshot.read_beats == 456);
	assert(f.registers[IV_REG_CONTROL / 4] == (IV_CTL_ENABLE | IV_CTL_PATTERN));
	f.frozen = 1;
	f.delays = 0;
	assert(iv_stop(&io, 8) == IV_TIMEOUT && f.delays == 3);

	fixture_init(&f, 128, 1);
	assert(iv_discover(&io, &caps) == IV_OK);
	config = make_config(IV_FORMAT_XRGB8888);
	config.pattern = 1;
	assert(iv_commit(&io, &caps, &config, 1, 8) == IV_OK);
	assert(f.extension_reads == 0 && f.extension_writes == 0);
	assert(f.registers[IV_REG_BASE / 4] == 0 && f.registers[IV_REG_PREFILL / 4] == 0);
	f.registers[IV_REG_VERSION / 4] = 0x10003;
	assert(iv_discover(&io, &caps) == IV_UNSUPPORTED && f.extension_reads == 0);
	f.registers[IV_REG_VERSION / 4] = IV_VERSION_FORMATS;
	f.registers[IV_REG_FORMAT_CAPS / 4] = 0;
	assert(iv_discover(&io, &caps) == IV_INVALID);
	f.registers[IV_REG_FORMAT_CAPS / 4] = 16;
	assert(iv_discover(&io, &caps) == IV_INVALID);

	fixture_init(&f, 64, 1);
	assert(iv_select_clock(&io, 0, 8) == IV_OK);
	assert(iv_select_clock(&io, 1, 8) == IV_UNSUPPORTED);
	assert(f.extension_reads == 0 && f.extension_writes == 0);
	f.registers[IV_REG_CAPS / 4] |= IV_CAP_CLOCK_SELECT;
	f.registers[IV_REG_CLOCK_SELECT / 4] = IV_CLOCK_READY;
	f.registers[IV_REG_STATUS / 4] = IV_ST_QUIESCED;
	assert(iv_discover(&io, &caps) == IV_OK && caps.clock_select);
	assert(iv_select_clock(&io, 1, 8) == IV_OK);
	assert(f.registers[IV_REG_CLOCK_SELECT / 4] == 7);
	assert(iv_select_clock(&io, 0, 8) == IV_OK);
	f.registers[IV_REG_STATUS / 4] = IV_ST_APPLIED;
	assert(iv_select_clock(&io, 1, 8) == IV_INVALID);
	f.registers[IV_REG_STATUS / 4] = IV_ST_QUIESCED;
	f.frozen = 1;
	assert(iv_select_clock(&io, 1, 8) == IV_TIMEOUT);
	puts("IronVideo portable driver PASS (format masks, legacy MMIO, NV12, faults and clock switching)");
	return 0;
}
