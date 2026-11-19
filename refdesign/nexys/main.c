/* SPDX-License-Identifier: GPL-2.0-only */
#include <stdint.h>
#include <stddef.h>
#include "ironvideo_core.h"

#define UART_BASE UINT32_C(0x40600000)
#define VIDEO_BASE UINT32_C(0x43000000)
#define FB_BASE UINT32_C(0x90000000)
#define FB_BYTES UINT32_C(0x00400000)
#define UV_BASE UINT32_C(0x90100000)
#define WIDTH 1280u
#define HEIGHT 720u
#define PIXEL_HZ 74250000u
#define FRAMES_PER_READING 60u
#define POLL_BUDGET 1000000u
#define POLL_LIMIT 10000000u

struct color {
    uint32_t rgb;
    uint8_t y, u, v;
};

/* Limited-range BT.709 color bars, in display order. */
static const struct color bars[] = {
    {0xffffff, 235, 128, 128}, {0xffff00, 219,  16, 138},
    {0x00ffff, 188, 154,  16}, {0x00ff00, 173,  42,  26},
    {0xff00ff,  78, 214, 230}, {0xff0000,  63, 102, 240},
    {0x0000ff,  32, 240, 118}, {0x000000,  16, 128, 128},
};

struct format_info {
    const char *name;
    uint32_t format;
    uint32_t stride;
};

static const struct format_info formats[] = {
    {"XRGB8888", IV_FORMAT_XRGB8888, WIDTH * 4},
    {"RGB565", IV_FORMAT_RGB565, WIDTH * 2},
    {"YUV422 (YUYV)", IV_FORMAT_YUV422, WIDTH * 2},
    {"YUV420 (NV12)", IV_FORMAT_YUV420, WIDTH},
};

void *memset(void *destination, int value, size_t length)
{
    volatile unsigned char *output = destination;
    for (size_t i = 0; i < length; ++i)
        output[i] = (unsigned char)value;
    return destination;
}

static const struct color *color_at(unsigned x, unsigned y)
{
    /* Even-aligned pattern edges keep every 2x1 and 2x2 chroma sample coherent. */
    unsigned bar = x / (WIDTH / 8);
    if (y >= (HEIGHT * 3 / 4))
        bar ^= 7u;
    return &bars[bar];
}

static void fill_frame(uint32_t format)
{
    for (unsigned y = 0; y < HEIGHT; ++y) {
        if (format == IV_FORMAT_XRGB8888) {
            volatile uint32_t *row = (void *)(uintptr_t)(FB_BASE + y * WIDTH * 4);
            for (unsigned x = 0; x < WIDTH; ++x)
                row[x] = color_at(x, y)->rgb;
        } else if (format == IV_FORMAT_RGB565) {
            volatile uint32_t *row = (void *)(uintptr_t)(FB_BASE + y * WIDTH * 2);
            for (unsigned x = 0; x < WIDTH; x += 2) {
                uint32_t rgb = color_at(x, y)->rgb;
                uint32_t pixel = ((rgb >> 8) & 0xf800u) |
                                 ((rgb >> 5) & 0x07e0u) | ((rgb >> 3) & 0x001fu);
                row[x / 2] = pixel | pixel << 16;
            }
        } else if (format == IV_FORMAT_YUV422) {
            volatile uint32_t *row = (void *)(uintptr_t)(FB_BASE + y * WIDTH * 2);
            for (unsigned x = 0; x < WIDTH; x += 2) {
                const struct color *c = color_at(x, y);
                row[x / 2] = c->y | (uint32_t)c->u << 8 |
                             (uint32_t)c->y << 16 | (uint32_t)c->v << 24;
            }
        } else {
            volatile uint32_t *row = (void *)(uintptr_t)(FB_BASE + y * WIDTH);
            for (unsigned x = 0; x < WIDTH; x += 4)
                row[x / 4] = (uint32_t)color_at(x, y)->y * 0x01010101u;
            if (!(y & 1u)) {
                volatile uint32_t *uv = (void *)(uintptr_t)(UV_BASE + (y / 2) * WIDTH);
                for (unsigned x = 0; x < WIDTH; x += 4) {
                    const struct color *c = color_at(x, y);
                    uint32_t uv_pair = c->u | (uint32_t)c->v << 8;
                    uv[x / 4] = uv_pair | uv_pair << 16;
                }
            }
        }
    }
}

static uint32_t load32(uint32_t address)
{
    return *(volatile uint32_t *)(uintptr_t)address;
}

static void store32(uint32_t address, uint32_t value)
{
    *(volatile uint32_t *)(uintptr_t)address = value;
}

static iv_u32 read_register(void *context, iv_u32 offset)
{
    return load32((uint32_t)(uintptr_t)context + offset);
}

static void write_register(void *context, iv_u32 offset, iv_u32 value)
{
    store32((uint32_t)(uintptr_t)context + offset, value);
}

static void bus_barrier(void *context)
{
    (void)context;
    __asm__ volatile("mbar 1" ::: "memory");
}

static const struct iv_mmio video = {
    .context = (void *)(uintptr_t)VIDEO_BASE,
    .read32 = read_register, .write32 = write_register, .barrier = bus_barrier,
};

static void put_character(char value)
{
    while (load32(UART_BASE + 8) & 8u) { }
    store32(UART_BASE + 4, (uint8_t)value);
}

static void put_text(const char *text)
{
    while (*text) {
        if (*text == '\n')
            put_character('\r');
        put_character(*text++);
    }
}

static void put_decimal(uint32_t value)
{
    char digits[10];
    unsigned count = 0;
    do {
        digits[count++] = (char)('0' + value % 10);
        value /= 10;
    } while (value);
    while (count)
        put_character(digits[--count]);
}

static void put_fixed_3(uint32_t thousandths)
{
    uint32_t fraction = thousandths % 1000;
    put_decimal(thousandths / 1000);
    put_character('.');
    if (fraction < 100) put_character('0');
    if (fraction < 10) put_character('0');
    put_decimal(fraction);
}

static void fail(const char *stage)
{
    put_text("FAIL ");
    put_text(stage);
    put_text(" fault=");
    put_decimal(read_register(video.context, IV_REG_FAULT));
    put_text(" status=");
    put_decimal(read_register(video.context, IV_REG_STATUS));
    put_text("\n");
    (void)iv_stop(&video, POLL_BUDGET);
    for (;;) { }
}

static void measure(const struct format_info *format, const struct iv_geometry *geometry,
                    uint32_t beat_bytes)
{
    struct iv_snapshot snapshot;
    if (iv_read_snapshot(&video, &snapshot, POLL_BUDGET))
        fail("snapshot start");
    uint32_t first_frame = snapshot.frames;
    uint32_t first_beat = snapshot.read_beats;
    for (uint32_t wait = 0; wait < POLL_LIMIT; ++wait) {
        if (iv_read_snapshot(&video, &snapshot, POLL_BUDGET))
            fail("snapshot poll");
        uint32_t frames = snapshot.frames - first_frame;
        if (frames < FRAMES_PER_READING)
            continue;
        uint32_t beats = snapshot.read_beats - first_beat;
        uint64_t bytes_per_frame = geometry->frame_bytes;
        /* Frame sampling can straddle queued rows. Allow a one-frame payload difference. */
        uint64_t bytes = (uint64_t)beats * beat_bytes;
        if (bytes < bytes_per_frame * (frames - 1) ||
            bytes > bytes_per_frame * (frames + 1) || snapshot.underflows ||
            snapshot.faults || snapshot.read_errors)
            fail("DDR payload or scanout");
        uint32_t average = (uint32_t)((bytes * 60u) / (frames * 1000u));
        /* Reading peak cycles latches the corresponding byte count. */
        uint32_t peak_cycles = read_register(video.context, IV_REG_PEAK_RATE_CYCLES);
        uint32_t peak_bytes = read_register(video.context, IV_REG_PEAK_RATE_BYTES);
        uint32_t last_cycles = read_register(video.context, IV_REG_ROW_LAST);
        if (!peak_cycles || !peak_bytes || !last_cycles)
            fail("row telemetry");
        uint32_t peak = (uint32_t)(((uint64_t)peak_bytes * PIXEL_HZ) /
                                   ((uint64_t)peak_cycles * 1000u));
        put_text("720p60 ");
        put_text(format->name);
        put_text(" DDR average MB/s=");
        put_fixed_3(average);
        put_text(" peak row MB/s=");
        put_fixed_3(peak);
        put_text(" last row us=");
        put_fixed_3((uint32_t)((uint64_t)last_cycles * 1000000000u / PIXEL_HZ));
        put_text(" frames=");
        put_decimal(frames);
        put_text(" beats=");
        put_decimal(beats);
        put_text(" FIFO low (beats)=");
        put_decimal(snapshot.fifo_low_water);
        put_text(" underflows=0 faults=0\n");
        return;
    }
    fail("frame timeout");
}

int main(void)
{
    struct iv_caps caps;
    put_text("\nIronVideo Nexys bare-metal demo: fixed 1280x720p60\n");
    if (iv_discover(&video, &caps) || caps.beat_bytes != 16 ||
        caps.format_mask != IV_FORMAT_MASK_ALL)
        fail("core discovery");
    for (;;) {
        for (unsigned i = 0; i < sizeof(formats) / sizeof(formats[0]); ++i) {
            const struct format_info *format = &formats[i];
            struct iv_geometry geometry;
            struct iv_scanout config = {
                .primary = {FB_BASE, format->stride, FB_BASE, FB_BYTES},
                .mode = {
                    .h_active = WIDTH, .h_front = 110, .h_sync = 40, .h_back = 220,
                    .v_active = HEIGHT, .v_front = 5, .v_sync = 5, .v_back = 20,
                    .polarity = IV_POL_HPOS | IV_POL_VPOS, .pixel_hz = PIXEL_HZ,
                },
                .format = format->format,
            };
            if (format->format == IV_FORMAT_YUV420)
                config.uv = (struct iv_fb_plane){UV_BASE, WIDTH, UV_BASE, WIDTH * HEIGHT / 2};
            if (iv_format_geometry(&caps, config.format, WIDTH, HEIGHT, &geometry))
                fail("plane geometry");
            config.mode.prefill = geometry.prefill_beats;
            if (iv_stop(&video, POLL_BUDGET))
                fail("drain before DDR update");
            fill_frame(format->format);
            bus_barrier(0);
            iv_clear_faults(&video, IV_FAULT_ALL);
            if (iv_commit(&video, &caps, &config, 1, POLL_BUDGET))
                fail("mode commit");
            measure(format, &geometry, caps.beat_bytes);
        }
    }
}
