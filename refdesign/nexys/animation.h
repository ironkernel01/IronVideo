/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef IRONVIDEO_DEMO_ANIMATION_H
#define IRONVIDEO_DEMO_ANIMATION_H

#include <stdint.h>
#include "cube.h"
#include "ironvideo_core.h"

#define DEMO_WIDTH 1280u
#define DEMO_HEIGHT 720u
#define CUBE_LEFT ((DEMO_WIDTH - 2u * CUBE_WIDTH) / 2u)
#define CUBE_TOP ((DEMO_HEIGHT - 2u * CUBE_HEIGHT) / 2u)

/* The caller owns scanout arbitration and presents phases in sequence. */
void animation_start(enum iv_format format, uintptr_t primary, uintptr_t chroma);
int animation_prepare_next(void);
/* Present top then bottom once their respective rows have been scanned. */
void animation_present(unsigned phase, unsigned band);

#endif
