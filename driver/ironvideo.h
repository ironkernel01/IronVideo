/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef IRONVIDEO_UBOOT_H
#define IRONVIDEO_UBOOT_H

#include <linux/compiler.h>
#include <linux/types.h>

#include "ironvideo_core.h"

struct display_timing;

/* The caller owns the DDR reservation and has enabled the mode's pixel clock. */
int ironvideo_boot_scanout(u8 __iomem *regs, u32 fb, u32 size, u32 stride,
			   const struct display_timing *mode, u32 color);
int ironvideo_boot_scanout_format(u8 __iomem *regs,
				  const struct iv_scanout *config, u32 color);

#endif
