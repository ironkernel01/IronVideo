// SPDX-License-Identifier: GPL-2.0-only
#ifndef IRONVIDEO_REGS_H
#define IRONVIDEO_REGS_H

#define IV_REG_ID		0x00
#define IV_REG_VERSION		0x04
#define IV_REG_CAPS		0x08
#define IV_REG_CONTROL		0x0c
#define IV_REG_STATUS		0x10
#define IV_REG_FAULT		0x14
#define IV_REG_MASK		0x18
#define IV_REG_FIRST		0x1c
#define IV_REG_BASE		0x20
#define IV_REG_STRIDE		0x24
#define IV_REG_WINDOW		0x28
#define IV_REG_SIZE		0x2c
#define IV_REG_HA		0x30
#define IV_REG_HF		0x34
#define IV_REG_HS		0x38
#define IV_REG_HB		0x3c
#define IV_REG_VA		0x40
#define IV_REG_VF		0x44
#define IV_REG_VS		0x48
#define IV_REG_VB		0x4c
#define IV_REG_POLARITY		0x50
#define IV_REG_PREFILL		0x54
#define IV_REG_UNDERFLOW	0x58
#define IV_REG_LOW_WATER	0x5c
#define IV_REG_XY		0x60
#define IV_REG_FRAME		0x64
#define IV_REG_FAULT_XY		0x68
#define IV_REG_FAULT_ADDR	0x6c
#define IV_REG_FIFO_BYTES	0x70
#define IV_REG_DMA_STATUS	0x74
#define IV_REG_ROW_LAST		0x78
#define IV_REG_ROW_BYTES	0x7c
#define IV_REG_ROW_SAMPLES	0x80
#define IV_REG_ROW_WORST	0x84
#define IV_REG_ROW_BEST		0x88
#define IV_REG_READ_BEATS	0x8c
#define IV_REG_READ_BURSTS	0x90
#define IV_REG_READ_ERRORS	0x94
#define IV_REG_FORMAT_CAPS	0x98
#define IV_REG_FORMAT		0x9c
#define IV_REG_UV_BASE		0xa0
#define IV_REG_UV_STRIDE	0xa4
#define IV_REG_UV_WINDOW	0xa8
#define IV_REG_UV_SIZE		0xac
#define IV_REG_PEAK_RATE_CYCLES	0xb0
#define IV_REG_PEAK_RATE_BYTES	0xb4
#define IV_REG_CLOCK_SELECT	0xb8
#define IV_CLOCK_REQUEST	(1U << 0)
#define IV_CLOCK_ACTIVE		(1U << 1)
#define IV_CLOCK_READY		(1U << 2)

#define IV_ID			0x49525644
#define IV_VERSION_LEGACY	0x00010001
#define IV_VERSION_FORMATS	0x00010002
#define IV_VERSION		IV_VERSION_LEGACY
#define IV_CAP_WIDTH_MASK	0x000000ff
#define IV_CAP_FIFO_AW_MASK	0x0000ff00
#define IV_CAP_BURST_MASK	0x01ff0000
#define IV_CAP_CLOCK_SELECT	(1U << 25)

#define IV_CTL_ENABLE		(1U << 0)
#define IV_CTL_PATTERN		(1U << 1)
#define IV_CTL_COMMIT		(1U << 2)
#define IV_CTL_SNAPSHOT		(1U << 3)
#define IV_ST_CONFIGURED	(1U << 0)
#define IV_ST_BUSY		(1U << 1)
#define IV_ST_APPLIED		(1U << 2)
#define IV_ST_QUIESCED		(1U << 3)
#define IV_ST_SNAPSHOT_BUSY	(1U << 4)
#define IV_ST_REQUEST_ENABLE	(1U << 5)
#define IV_FAULT_CONTROL	(1U << 0)
#define IV_FAULT_ALL		0x0f
#define IV_POL_HPOS		(1U << 0)
#define IV_POL_VPOS		(1U << 1)
#define IV_DMA_ROW_BUSY		(1U << 0)
#define IV_DMA_AR_WAIT		(1U << 1)
#define IV_DMA_R_WAIT		(1U << 2)
#define IV_DMA_HALTED		(1U << 3)
#define IV_DMA_SATURATED	(1U << 4)

#endif
