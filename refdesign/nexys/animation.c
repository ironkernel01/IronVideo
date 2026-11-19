/* SPDX-License-Identifier: GPL-2.0-only */
#include "animation.h"

/* Scratch and animation data in the reference design's 512 MiB DDR. Each
 * phase can have at most one span per source pixel. The upper bound is under
 * 14 MiB, well inside the 16 MiB reserved from 0x91000000. */
#define PREVIOUS ((unsigned char *)(uintptr_t)0x90800000u)
#define SPANS ((uint32_t *)(uintptr_t)0x91000000u)
_Static_assert(CUBE_WIDTH <= 255 && CUBE_HEIGHT <= 255, "span coordinate size");
_Static_assert(CUBE_PHASES * CUBE_WIDTH * CUBE_HEIGHT * sizeof(uint32_t) <=
               16u * 1024u * 1024u, "DDR span capacity");

static unsigned char canvas[CUBE_WIDTH * CUBE_HEIGHT];
/* Three offsets delimit the top and bottom half of each phase. */
static unsigned phase_offset[CUBE_PHASES][3];
static unsigned prepared, used;
static enum iv_format native_format;
static uintptr_t fb, uv;
static uint32_t native[32], native_uv[32];

static unsigned rgb565(uint32_t rgb)
{
    return ((rgb >> 8) & 0xf800u) | ((rgb >> 5) & 0x07e0u) | ((rgb >> 3) & 31u);
}

static void prepare_palette(void)
{
    for (unsigned i = 0; i < 32; ++i) {
        uint32_t rgb = cube_palette[i];
        int r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255;
        /* BT.709 limited-range, rounded with a positive accumulator. */
        uint32_t y = (16*256 + 47*r + 157*g + 16*b + 128) >> 8;
        uint32_t u = (128*256 - 26*r - 87*g + 113*b + 128) >> 8;
        uint32_t v = (128*256 + 112*r - 102*g - 10*b + 128) >> 8;
        uint32_t pair = u | (v << 8);
        native_uv[i] = pair | (pair << 16);
        switch (native_format) {
        case IV_FORMAT_XRGB8888: native[i] = rgb; break;
        case IV_FORMAT_RGB565: native[i] = rgb565(rgb) * 0x10001u; break;
        case IV_FORMAT_YUV422: native[i] = y | (u << 8) | (y << 16) | (v << 24); break;
        case IV_FORMAT_YUV420: native[i] = y * 0x01010101u; break;
        }
    }
}

/* A source pixel covers a complete 2x2 output cell, including exactly one
 * chroma sample in NV12. Only the changed cells are written during playback. */
static void draw_run(unsigned x, unsigned y, unsigned length, unsigned ink)
{
    unsigned dest_x = CUBE_LEFT + 2*x, dest_y = CUBE_TOP + 2*y;
    unsigned offset = dest_y * DEMO_WIDTH + dest_x;
    uint32_t value = native[ink];
    if (native_format == IV_FORMAT_YUV420) {
        volatile uint16_t *p = (volatile uint16_t *)(fb + offset);
        volatile uint16_t *c = (volatile uint16_t *)(uv + dest_y/2 * DEMO_WIDTH + dest_x);
        uint16_t color = (uint16_t)native_uv[ink];
        for (unsigned k = 0; k < length; ++k) {
            p[k] = (uint16_t)value;
            p[k + DEMO_WIDTH/2] = (uint16_t)value;
            c[k] = color;
        }
    } else {
        unsigned words = native_format == IV_FORMAT_XRGB8888 ? 2 : 1;
        volatile uint32_t *p = (volatile uint32_t *)fb + offset/2 * words;
        unsigned stride = DEMO_WIDTH/2 * words;
        for (unsigned k = 0; k < length * words; ++k) {
            p[k] = value;
            p[k + stride] = value;
        }
    }
}

static void paint_background(void)
{
    unsigned stride_words = DEMO_WIDTH;
    if (native_format == IV_FORMAT_YUV420)
        stride_words /= 4;
    else if (native_format != IV_FORMAT_XRGB8888)
        stride_words /= 2;
    for (unsigned y = 0; y < DEMO_HEIGHT; ++y) {
        unsigned sy = y < CUBE_TOP ? 0 : (y - CUBE_TOP)/2;
        if (sy >= CUBE_HEIGHT) sy = CUBE_HEIGHT - 1;
        const unsigned char *row = canvas + sy * CUBE_WIDTH;
        /* A lone star on the edge should remain a point. */
        unsigned ink = row[0] == row[1] ? row[0] : row[2];
        volatile uint32_t *p = (volatile uint32_t *)fb + y * stride_words;
        for (unsigned w = 0; w < stride_words; ++w)
            p[w] = native[ink];
        if (native_format == IV_FORMAT_YUV420 && !(y & 1)) {
            volatile uint32_t *c = (volatile uint32_t *)uv + (y/2) * stride_words;
            for (unsigned w = 0; w < stride_words; ++w)
                c[w] = native_uv[ink];
        }
    }
}

void animation_start(enum iv_format format, uintptr_t primary, uintptr_t chroma)
{
    native_format = format;
    fb = primary;
    uv = chroma;
    prepare_palette();
    cube_render(0, canvas);
    paint_background();
    for (unsigned y = 0; y < CUBE_HEIGHT; ++y) {
        const unsigned char *row = canvas + y * CUBE_WIDTH;
        for (unsigned x = 0; x < CUBE_WIDTH;) {
            unsigned first = x++;
            while (x < CUBE_WIDTH && row[x] == row[first]) ++x;
            draw_run(first, y, x - first, row[first]);
        }
    }
    if (!prepared) {
        for (unsigned i = 0; i < sizeof(canvas); ++i)
            PREVIOUS[i] = canvas[i];
    }
}

int animation_prepare_next(void)
{
    if (prepared == CUBE_PHASES) return 1;
    unsigned phase = (prepared + 1) % CUBE_PHASES;
    cube_render(phase, canvas);
    phase_offset[phase][0] = used;
    for (unsigned y = 0; y < CUBE_HEIGHT; ++y) {
        if (y == CUBE_HEIGHT / 2) phase_offset[phase][1] = used;
        unsigned start = y * CUBE_WIDTH;
        for (unsigned x = 0; x < CUBE_WIDTH;) {
            unsigned i = start + x;
            unsigned ink = canvas[i];
            if (ink == PREVIOUS[i]) {
                ++x;
                continue;
            }
            unsigned first = x;
            do {
                PREVIOUS[start + x++] = (unsigned char)ink;
            } while (x < CUBE_WIDTH && canvas[start+x] == ink && PREVIOUS[start+x] != ink);
            SPANS[used++] = first | (y << 8) | ((x - first) << 16) | (ink << 24);
        }
    }
    phase_offset[phase][2] = used;
    return ++prepared == CUBE_PHASES;
}

void animation_present(unsigned phase, unsigned band)
{
    for (unsigned i = phase_offset[phase][band]; i < phase_offset[phase][band + 1]; ++i) {
        uint32_t run = SPANS[i];
        draw_run(run & 255, (run >> 8) & 255, (run >> 16) & 255, run >> 24);
    }
}
