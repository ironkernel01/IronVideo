/* SPDX-License-Identifier: GPL-2.0-only */
#include <stdint.h>
#include <stddef.h>
#include "animation.h"

#define UART_BASE UINT32_C(0x40600000)
#define VIDEO_BASE UINT32_C(0x43000000)
#define FB_BASE UINT32_C(0x90000000)
#define FB_BYTES UINT32_C(0x00400000)
#define UV_BASE UINT32_C(0x90100000)
#define WIDTH DEMO_WIDTH
#define HEIGHT DEMO_HEIGHT
#define PIXEL_HZ 74250000u
#define FRAMES_PER_READING 120u
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

/* UARTLite's short FIFO can fill in the middle of a measurement. Queue
 * diagnostic text in BRAM and drain it between raster polls. */
static char tx_ring[1024];
static unsigned tx_read, tx_write;

static void service_tx(void)
{
    while (tx_read != tx_write && !(load32(UART_BASE + 8) & 8u)) {
        store32(UART_BASE + 4, (uint8_t)tx_ring[tx_read]);
        tx_read = (tx_read + 1u) % sizeof(tx_ring);
    }
}

static void put_character(char value)
{
    unsigned next = (tx_write + 1u) % sizeof(tx_ring);
    while (next == tx_read) service_tx();
    tx_ring[tx_write] = value;
    tx_write = next;
    service_tx();
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
    while (tx_read != tx_write) service_tx();
    for (;;) { }
}

enum scene { CUBE, BARS, CYCLE };

static enum scene selected_scene = CUBE;
static unsigned selected_format = IV_FORMAT_RGB565;

static void show_menu(void)
{
    put_text("\nC cube | B bars | A cycle bars | 1 XRGB8888 | 2 RGB565 | "
             "3 YUV422/YUYV | 4 YUV420/NV12 | ? menu\n");
}

static struct iv_snapshot snapshot(void)
{
    struct iv_snapshot sample;
    if (iv_read_snapshot(&video, &sample, POLL_BUDGET))
        fail("snapshot");
    if (sample.underflows || sample.faults || sample.read_errors)
        fail("DDR read or scanout");
    return sample;
}

/* Return true if the scene must be restarted. One key selects either a
 * demonstration or its native framebuffer layout while the raster runs. */
static int menu_input(void)
{
    if (!(load32(UART_BASE + 8) & 1u)) return 0;
    unsigned key = load32(UART_BASE) & 255u;
    if (key >= 'A' && key <= 'Z') key += 'a' - 'A';
    if (key >= '1' && key <= '4') {
        selected_format = key - '1';
        if (selected_scene == CYCLE) selected_scene = BARS;
    } else if (key == 'c') selected_scene = CUBE;
    else if (key == 'b') selected_scene = BARS;
    else if (key == 'a') {
        selected_scene = CYCLE;
        selected_format = IV_FORMAT_XRGB8888;
    } else {
        if (key != '\r' && key != '\n') show_menu();
        return 0;
    }
    return 1;
}

static struct iv_geometry start_scene(const struct iv_caps *caps)
{
    const struct format_info *format = &formats[selected_format];
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
    if (iv_format_geometry(caps, config.format, WIDTH, HEIGHT, &geometry))
        fail("plane geometry");
    config.mode.prefill = geometry.prefill_beats;
    put_text("\n720p60 ");
    put_text(selected_scene == CUBE ? "cube " : selected_scene == BARS ? "bars " : "cycle bars ");
    put_text(format->name);
    put_text("\n");
    if (iv_stop(&video, POLL_BUDGET))
        fail("drain before DDR update");
    if (selected_scene == CUBE)
        animation_start(format->format, FB_BASE, UV_BASE);
    else
        fill_frame(format->format);
    bus_barrier(0);
    iv_clear_faults(&video, IV_FAULT_ALL);
    if (iv_commit(&video, caps, &config, 1, POLL_BUDGET))
        fail("mode commit");
    return geometry;
}

struct animation_stats {
    unsigned presented, missed, late;
    unsigned worst_lines;
};

static void report(const struct iv_snapshot *first, const struct iv_snapshot *last,
                   const struct iv_geometry *geometry, unsigned beat_bytes,
                   const struct animation_stats *stats)
{
    uint32_t frames = last->frames - first->frames;
    uint32_t beats = last->read_beats - first->read_beats;
    uint64_t bytes = (uint64_t)beats * beat_bytes;
    /* Snapshots can be at different positions within their frames. */
    if (bytes < geometry->frame_bytes * (frames - 1) ||
        bytes > geometry->frame_bytes * (frames + 1))
        fail("DDR payload");
    uint32_t peak_cycles = read_register(video.context, IV_REG_PEAK_RATE_CYCLES);
    uint32_t peak_bytes = read_register(video.context, IV_REG_PEAK_RATE_BYTES);
    uint32_t last_cycles = read_register(video.context, IV_REG_ROW_LAST);
    if (!peak_cycles || !peak_bytes || !last_cycles)
        fail("row telemetry");
    put_text("720p60 ");
    put_text(formats[selected_format].name);
    put_text(" DDR average MB/s=");
    put_fixed_3((uint32_t)((bytes * 60u) / (frames * 1000u)));
    put_text(" peak row MB/s=");
    put_fixed_3((uint32_t)(((uint64_t)peak_bytes * PIXEL_HZ) /
                           ((uint64_t)peak_cycles * 1000u)));
    put_text(" last row us=");
    put_fixed_3((uint32_t)((uint64_t)last_cycles * 1000000000u / PIXEL_HZ));
    put_text(" FIFO low (beats)=");
    put_decimal(last->fifo_low_water);
    put_text(" underflows=0 faults=0");
    if (selected_scene == CUBE) {
        put_text(" cube fps=");
        put_fixed_3(stats->presented * 60000u / frames);
        put_text(" missed=");
        put_decimal(stats->missed);
        put_text(" late=");
        put_decimal(stats->late);
        put_text(" worst update lines=");
        put_decimal(stats->worst_lines);
    }
    put_text("\n");
}

/* Write each half after its last row has passed. Finish before the next
 * scan approaches that half, leaving 32 rows for FIFO and AXI prefetch. */
#define PRESENT_LINE (CUBE_TOP + CUBE_HEIGHT + 2u)
#define PREFETCH_LINES 32u
#define RASTER_LINES 750u

static unsigned raster_distance(const struct iv_snapshot *from, const struct iv_snapshot *to)
{
    return (to->frames - from->frames) * RASTER_LINES +
           (to->raster_xy >> 16) - (from->raster_xy >> 16);
}

static void present_phase(unsigned phase, const struct iv_snapshot *start,
                          struct animation_stats *stats)
{
    struct iv_snapshot before = *start;
    unsigned work = 0;
    int late = 0;
    for (unsigned band = 0; band < 2; ++band) {
        unsigned inset = CUBE_HEIGHT * band;
        unsigned safe_end = RASTER_LINES + CUBE_TOP + inset - PREFETCH_LINES;
        unsigned open = PRESENT_LINE + inset;
        unsigned wait = 0;
        while (before.frames == start->frames && (before.raster_xy >> 16) < open) {
            if (++wait == POLL_LIMIT) fail("band deadline timeout");
            service_tx();
            before = snapshot();
        }
        animation_present(phase, band);
        bus_barrier(0);
        struct iv_snapshot end = snapshot();
        work += raster_distance(&before, &end);
        if (raster_distance(start, &end) + (start->raster_xy >> 16) >= safe_end)
            late = 1;
        before = end;
    }
    if (work > stats->worst_lines) stats->worst_lines = work;
    stats->late += late;
    ++stats->presented;
}

static void run_scene(const struct iv_caps *caps)
{
    struct iv_geometry geometry = start_scene(caps);
    static int cached;
    if (selected_scene == CUBE && !cached) {
        put_text("Generating 128 cube phases on MicroBlaze...\n");
        while (!(cached = animation_prepare_next())) {
            service_tx();
            if (menu_input()) return;
        }
        put_text("Cube cache ready\n");
    }
    /* Settle startup prefetch before measuring steady-state reads. */
    struct iv_snapshot first = snapshot(), now = first;
    unsigned timeout = 0;
    while (now.frames == first.frames) {
        service_tx();
        if (menu_input()) return;
        if (++timeout == POLL_LIMIT) fail("frame timeout");
        now = snapshot();
    }
    first = now;
    (void)read_register(video.context, IV_REG_PEAK_RATE_CYCLES);
    unsigned phase = 0, next_window = now.frames;
    struct animation_stats stats = {0};
    unsigned last_progress = now.frames;
    timeout = 0;
    for (;;) {
        service_tx();
        if (menu_input()) return;
        now = snapshot();
        if (now.frames != last_progress) {
            last_progress = now.frames;
            timeout = 0;
        } else if (++timeout == POLL_LIMIT) fail("frame timeout");
        unsigned y = now.raster_xy >> 16;
        if (selected_scene == CUBE) {
            /* Charge an expired window immediately, including consecutive
             * failures when no subsequent presentation has yet succeeded. */
            unsigned expired = now.frames + (y >= PRESENT_LINE + 12);
            if ((int32_t)(expired - next_window) > 0) {
                stats.missed += expired - next_window;
                next_window = expired;
            }
            if (now.frames == next_window && y >= PRESENT_LINE) {
                ++next_window;
                phase = (phase + 1u) % CUBE_PHASES;
                present_phase(phase, &now, &stats);
            }
        }
        if (now.frames - first.frames >= FRAMES_PER_READING) {
            report(&first, &now, &geometry, caps->beat_bytes, &stats);
            if (selected_scene == CYCLE) {
                selected_format = (selected_format + 1) % 4;
                return;
            }
            first = now;
            stats = (struct animation_stats){0};
        }
    }
}

int main(void)
{
    struct iv_caps caps;
    put_text("\nIronVideo Nexys bare-metal demo, fixed 1280x720p60\n");
    show_menu();
    if (iv_discover(&video, &caps) || caps.beat_bytes != 16 ||
        caps.format_mask != IV_FORMAT_MASK_ALL)
        fail("core discovery");
    for (;;) run_scene(&caps);
}
