/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef IRONVIDEO_DEMO_CUBE_H
#define IRONVIDEO_DEMO_CUBE_H

#define CUBE_WIDTH 192
#define CUBE_HEIGHT 144
#define CUBE_PHASES 128

/* Little-endian XRGB8888 values, with the high byte set to zero. */
extern const unsigned int cube_palette[32];

/* Write CUBE_WIDTH * CUBE_HEIGHT palette indices, row-major, at phase modulo CUBE_PHASES. */
void cube_render(unsigned phase, unsigned char *pixels);

#endif
