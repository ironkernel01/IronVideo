/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _WIN32
#define _DEFAULT_SOURCE
#endif
#include "animation.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#endif

#define GUARD 64u
#define SENTINEL 0xa5
#define VIEW_WIDTH (2u * CUBE_WIDTH)
#define VIEW_HEIGHT (2u * CUBE_HEIGHT)
#define PRIMARY_CAPACITY (DEMO_WIDTH * DEMO_HEIGHT * 4u)
#define UV_CAPACITY (DEMO_WIDTH * DEMO_HEIGHT / 2u)

_Alignas(4) static unsigned char primary[PRIMARY_CAPACITY + 2 * GUARD];
_Alignas(4) static unsigned char chroma[UV_CAPACITY + 2 * GUARD];
static unsigned char initial_primary[sizeof(primary)];
static unsigned char initial_chroma[sizeof(chroma)];
static unsigned char source[2][CUBE_WIDTH * CUBE_HEIGHT];

struct sample {
    unsigned r, g, b, y, u, v;
};

static struct sample samples[32];

static int map_scratch(uintptr_t address, size_t bytes)
{
    void *requested = (void *)address;
#ifdef _WIN32
    void *actual = VirtualAlloc(requested, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);

    if (actual && actual != requested)
        VirtualFree(actual, 0, MEM_RELEASE);
#else
    /* A hint plus equality check keeps existing process mappings intact. */
    void *actual = mmap(requested, bytes, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

    if (actual != MAP_FAILED && actual != requested)
        munmap(actual, bytes);
#endif
    return actual == requested;
}

static void make_samples(void)
{
    for (unsigned i = 0; i < 32; ++i) {
        unsigned rgb = cube_palette[i];
        struct sample *s = &samples[i];
        double luma;

        s->r = (rgb >> 16) & 255;
        s->g = (rgb >> 8) & 255;
        s->b = rgb & 255;
        luma = 0.2126 * s->r + 0.7152 * s->g + 0.0722 * s->b;
        s->y = (unsigned)(16.5 + 219.0 * luma / 255.0);
        s->u = (unsigned)(128.5 + 224.0 * (s->b - luma) / (255.0 * 1.8556));
        s->v = (unsigned)(128.5 + 224.0 * (s->r - luma) / (255.0 * 1.5748));
    }
}

static int within_code_value(unsigned actual, unsigned expected)
{
    return actual + 1 >= expected && actual <= expected + 1;
}

static int limited_yuv(unsigned y, unsigned u, unsigned v, const struct sample *s)
{
    return y >= 16 && y <= 235 && u >= 16 && u <= 240 && v >= 16 && v <= 240 &&
           within_code_value(y, s->y) && within_code_value(u, s->u) &&
           within_code_value(v, s->v);
}

static int check_pixel(enum iv_format format, const unsigned char *top,
                       const unsigned char *bottom, const unsigned char *uv,
                       const struct sample *s)
{
    switch (format) {
    case IV_FORMAT_XRGB8888: {
        unsigned char pair[] = { s->b, s->g, s->r, 0, s->b, s->g, s->r, 0 };

        return !memcmp(top, pair, sizeof(pair)) && !memcmp(bottom, pair, sizeof(pair));
    }
    case IV_FORMAT_RGB565: {
        unsigned rgb = (s->r / 8 << 11) | (s->g / 4 << 5) | (s->b / 8);
        unsigned char pair[] = { rgb & 255, rgb >> 8, rgb & 255, rgb >> 8 };

        return !memcmp(top, pair, sizeof(pair)) && !memcmp(bottom, pair, sizeof(pair));
    }
    case IV_FORMAT_YUV422:
        return !memcmp(top, bottom, 4) && top[0] == top[2] &&
               limited_yuv(top[0], top[1], top[3], s);
    case IV_FORMAT_YUV420:
        return !memcmp(top, bottom, 2) && top[0] == top[1] &&
               limited_yuv(top[0], uv[0], uv[1], s);
    }
    return 0;
}

static int exterior_equal(const unsigned char *actual, const unsigned char *initial,
                          size_t capacity, unsigned rows, unsigned stride,
                          unsigned x, unsigned y, unsigned width, unsigned height)
{
    size_t first = GUARD + (size_t)y * stride;
    size_t end = first + (size_t)height * stride;

    if (end > GUARD + (size_t)rows * stride ||
        memcmp(actual, initial, first) ||
        memcmp(actual + end, initial + end, capacity - end))
        return 0;
    for (size_t row = first; row < end; row += stride)
        if (memcmp(actual + row, initial + row, x) ||
            memcmp(actual + row + x + width, initial + row + x + width, stride - x - width))
            return 0;
    return 1;
}

static int guard_equal(const unsigned char *plane, size_t capacity, size_t active)
{
    for (size_t i = 0; i < GUARD; ++i)
        if (plane[i] != SENTINEL)
            return 0;
    for (size_t i = active + GUARD; i < capacity; ++i)
        if (plane[i] != SENTINEL)
            return 0;
    return 1;
}

static int check_frame(enum iv_format format, unsigned upper_phase, unsigned lower_phase)
{
    unsigned bpp = format == IV_FORMAT_XRGB8888 ? 4 : format == IV_FORMAT_YUV420 ? 1 : 2;
    unsigned stride = DEMO_WIDTH * bpp;

    if (!exterior_equal(primary, initial_primary, sizeof(primary), DEMO_HEIGHT,
                        stride, CUBE_LEFT * bpp, CUBE_TOP, VIEW_WIDTH * bpp, VIEW_HEIGHT))
        return 0;
    if (format == IV_FORMAT_YUV420) {
        if (!exterior_equal(chroma, initial_chroma, sizeof(chroma), DEMO_HEIGHT / 2,
                            DEMO_WIDTH, CUBE_LEFT, CUBE_TOP / 2, VIEW_WIDTH, CUBE_HEIGHT))
            return 0;
    } else if (memcmp(chroma, initial_chroma, sizeof(chroma))) {
        return 0;
    }

    cube_render(upper_phase, source[0]);
    if (upper_phase != lower_phase)
        cube_render(lower_phase, source[1]);
    for (unsigned y = 0; y < CUBE_HEIGHT; ++y) {
        unsigned old_band = upper_phase != lower_phase && y >= CUBE_HEIGHT / 2;
        const unsigned char *row = source[old_band] + y * CUBE_WIDTH;

        for (unsigned x = 0; x < CUBE_WIDTH; ++x) {
            unsigned ox = CUBE_LEFT + 2 * x;
            unsigned oy = CUBE_TOP + 2 * y;
            const unsigned char *top = primary + GUARD + oy * stride + ox * bpp;
            const unsigned char *uv = chroma + GUARD + (oy / 2) * DEMO_WIDTH + ox;

            if (!check_pixel(format, top, top + stride, uv, &samples[row[x]]))
                return 0;
        }
    }
    return 1;
}

int main(void)
{
    unsigned phase, format;

    if (!map_scratch(0x90800000u, CUBE_WIDTH * CUBE_HEIGHT) ||
        !map_scratch(0x91000000u, 16u * 1024u * 1024u)) {
        fputs("Cannot reserve animation scratch at the firmware addresses\n", stderr);
        return 1;
    }
    make_samples();
    for (format = IV_FORMAT_XRGB8888; format <= IV_FORMAT_YUV420; ++format) {
        size_t active = PRIMARY_CAPACITY;
        size_t active_uv = format == IV_FORMAT_YUV420 ? UV_CAPACITY : 0;

        if (format != IV_FORMAT_XRGB8888)
            active /= 2;
        if (format == IV_FORMAT_YUV420)
            active /= 2;
        memset(primary, SENTINEL, sizeof(primary));
        memset(chroma, SENTINEL, sizeof(chroma));
        animation_start(format, (uintptr_t)(primary + GUARD), (uintptr_t)(chroma + GUARD));
        phase = 0;
        if (!guard_equal(primary, sizeof(primary), active) ||
            !guard_equal(chroma, sizeof(chroma), active_uv))
            goto fail;
        memcpy(initial_primary, primary, sizeof(primary));
        memcpy(initial_chroma, chroma, sizeof(chroma));
        if (!check_frame(format, phase, phase))
            goto fail;

        if (format == IV_FORMAT_XRGB8888) {
            for (phase = 1; phase <= CUBE_PHASES; ++phase)
                if (animation_prepare_next() != (phase == CUBE_PHASES))
                    goto fail;
        }
        if (!animation_prepare_next())
            goto fail;

        for (phase = 1; phase <= CUBE_PHASES; ++phase) {
            unsigned current = phase % CUBE_PHASES;

            animation_present(current, 0);
            if (!check_frame(format, current, phase - 1))
                goto fail;
            animation_present(current, 1);
            if (!check_frame(format, current, current))
                goto fail;
        }
        if (memcmp(primary, initial_primary, sizeof(primary)) ||
            memcmp(chroma, initial_chroma, sizeof(chroma)))
            goto fail;
    }
    printf("PASS: %u transitions in both bands, including wrap, in each of four native formats\n", CUBE_PHASES);
    return 0;

fail:
    fprintf(stderr, "Animation check failed in format %u at step %u\n", format, phase);
    return 1;
}
