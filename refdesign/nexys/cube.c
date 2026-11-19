/* SPDX-License-Identifier: GPL-2.0-only */
#include "cube.h"

#define HALF 24
#define BAND_ROWS 8
#define EDGE_ONE 256
#define DEPTH_BIAS 2
#define CENTER_X (CUBE_WIDTH / 2)
#define CENTER_Y (CUBE_HEIGHT / 2 - 7)
#define FRAME_MARGIN 2

enum {
	SKY, SEAM, STAR, FLOOR_DARK, FLOOR_LIGHT, FLOOR_HORIZON,
	FACE_FIRST,
};

const unsigned int cube_palette[32] = {
	0x080d22, 0x11182e, 0x54698a, 0x141e39, 0x233051, 0x3b5276,
	0x7b1e3b, 0xb92d4e, 0xf64b66, 0xff7789,
	0x226b49, 0x2a9b60, 0x4edb81, 0x7affac,
	0x275d87, 0x388fba, 0x52cbf0, 0x8ee9ff,
	0x856134, 0xc28f36, 0xf5c84d, 0xffe583,
	0x56458e, 0x8f64c6, 0xbe94f9, 0xdcc2ff,
	0x666e88, 0xa1b4d1, 0xd8e7f7, 0xf2f8ff,
	0x8095ba, 0xcbd7f0,
};

static const short quarter_wave[65] = {
	0, 6, 13, 19, 25, 31, 38, 44, 50, 56,
	62, 68, 74, 80, 86, 92, 98, 104, 109, 115,
	121, 126, 132, 137, 142, 147, 152, 157, 162, 167,
	172, 177, 181, 185, 190, 194, 198, 202, 206, 209,
	213, 216, 220, 223, 226, 229, 231, 234, 237, 239,
	241, 243, 245, 247, 248, 250, 251, 252, 253, 254,
	255, 255, 256, 256, 256
};

struct vector {
	int x, y, z;
};

struct panel {
	struct vector center, u, v;
};

struct view {
	int yaw_s, yaw_c, pitch_s, pitch_c, focal;
};

struct point {
	short x, y, depth;
};

struct quad {
	struct point a, b, c, d;
	unsigned char ink;
};

struct edge {
	int x, depth, x_dy, depth_dy;
};

static int wave(unsigned angle)
{
	unsigned offset = angle & 63u;
	unsigned quadrant = (angle >> 6) & 3u;
	int value = quarter_wave[(quadrant & 1u) ? 64 - offset : offset];

	return (quadrant & 2u) ? -value : value;
}

static int round_q8(int number)
{
	return number >= 0 ? (number + 128) / 256 : -((-number + 128) / 256);
}

static int fold_angle(unsigned phase)
{
	if (phase < 24 || phase >= 112)
		return 64;
	if (phase < 56)
		return (256 + wave(64u + (phase - 24u) * 4u)) / 8;
	if (phase < 72)
		return 0;
	return (256 - wave(64u + (phase - 72u) * 128u / 40u)) / 8;
}

static struct vector rotate(struct vector p, const struct view *view)
{
	int x = round_q8(p.x * view->yaw_c + p.z * view->yaw_s);
	int z = round_q8(p.z * view->yaw_c - p.x * view->yaw_s);

	return (struct vector) {
		x,
		round_q8(p.y * view->pitch_c - z * view->pitch_s),
		round_q8(p.y * view->pitch_s + z * view->pitch_c),
	};
}

static void make_panels(struct panel panels[6], unsigned hinge, const struct view *view)
{
	int s = wave(hinge), c = wave(hinge + 64u);
	int s2 = wave(2u * hinge), c2 = wave(2u * hinge + 64u);
	struct vector u = {256, 0, 0}, v = {0, 256, 0};
	int back_x = HALF * (256 + 2 * c + c2);
	int back_z = HALF * (2 * s + s2);

	/* The final panel hinges on the right panel's outer edge. */
	panels[0] = (struct panel) {{0, 0, 0}, u, v};
	panels[1] = (struct panel) {{-HALF * (256 + c), 0, HALF * s}, {c, 0, -s}, v};
	panels[2] = (struct panel) {{HALF * (256 + c), 0, HALF * s}, {c, 0, s}, v};
	panels[3] = (struct panel) {{0, -HALF * (256 + c), HALF * s}, u, {0, c, -s}};
	panels[4] = (struct panel) {{0, HALF * (256 + c), HALF * s}, u, {0, c, s}};
	panels[5] = (struct panel) {{back_x, 0, back_z}, {c2, 0, s2}, v};

	for (unsigned i = 0; i < 6; ++i) {
		panels[i].center.x -= back_x / 4;
		panels[i].center.z -= back_z / 2;
		panels[i].center = rotate(panels[i].center, view);
		panels[i].u = rotate(panels[i].u, view);
		panels[i].v = rotate(panels[i].v, view);
	}
}

static struct vector camera_point(const struct panel *p, int x, int y)
{
	return (struct vector) {
		p->center.x + p->u.x * x + p->v.x * y,
		p->center.y + p->u.y * x + p->v.y * y,
		p->center.z + p->u.z * x + p->v.z * y + 168 * 256,
	};
}

static int fit_axis(int focal, int position, int depth, int before, int after)
{
	int distance = position < 0 ? -position : position;
	int available = position < 0 ? before : after;

	if (distance * focal > available * depth)
		return available * depth / distance;
	return focal;
}

static int frame_focal(const struct panel panels[6], int focal)
{
	/* With all corners in front of the camera, the whole projected panel
	 * lies inside their bounds. Keep the nominal scale whenever it fits. */
	for (unsigned i = 0; i < 6; ++i) {
		for (int y = -HALF; y <= HALF; y += 2 * HALF) {
			for (int x = -HALF; x <= HALF; x += 2 * HALF) {
				struct vector p = camera_point(&panels[i], x, y);

				focal = fit_axis(focal, p.x, p.z, CENTER_X - FRAME_MARGIN,
						 CUBE_WIDTH - 1 - CENTER_X - FRAME_MARGIN);
				focal = fit_axis(focal, p.y, p.z, CENTER_Y - FRAME_MARGIN,
						 CUBE_HEIGHT - 1 - CENTER_Y - FRAME_MARGIN);
			}
		}
	}
	return focal;
}

static struct point project(const struct panel *p, int x, int y, int focal, int bias)
{
	struct vector v = camera_point(p, x, y);

	return (struct point) {
		(short)(CENTER_X + v.x * focal / v.z),
		(short)(CENTER_Y + v.y * focal / v.z),
		(short)((1 << 24) / v.z + bias),
	};
}

static void add_quad(struct quad *q, const struct panel *p, int left, int top,
		     int right, int bottom, int focal, int depth_bias, unsigned ink)
{
	q->a = project(p, left, top, focal, depth_bias);
	q->b = project(p, right, top, focal, depth_bias);
	q->c = project(p, right, bottom, focal, depth_bias);
	q->d = project(p, left, bottom, focal, depth_bias);
	q->ink = (unsigned char)ink;
}

static unsigned panel_shade(const struct panel *p)
{
	int nx = round_q8(p->u.y * p->v.z - p->u.z * p->v.y);
	int ny = round_q8(p->u.z * p->v.x - p->u.x * p->v.z);
	int nz = round_q8(p->u.x * p->v.y - p->u.y * p->v.x);
	int light;

	/* Both surfaces of an unfolding panel are visible. */
	if (nz > 0) {
		nx = -nx;
		ny = -ny;
		nz = -nz;
	}
	light = -2 * nx - 3 * ny - 4 * nz;
	return (light > 250) + (light > 670) + (light > 1050);
}

static struct edge edge_at(const struct point *a, const struct point *b, int y)
{
	int dy = b->y - a->y;
	int x_dy = ((b->x - a->x) * EDGE_ONE) / dy;
	int d_dy = ((b->depth - a->depth) * EDGE_ONE) / dy;

	return (struct edge) {a->x * EDGE_ONE + (y - a->y) * x_dy,
		a->depth * EDGE_ONE + (y - a->y) * d_dy, x_dy, d_dy};
}

static void paint_span(unsigned char *row, unsigned short *zrow, struct edge a,
		       struct edge b, unsigned char ink)
{
	int x, end, slope, depth;

	if (a.x > b.x) {
		struct edge swap = a;
		a = b;
		b = swap;
	}
	if (a.x == b.x)
		return;

	x = (a.x + EDGE_ONE - 1) >> 8;
	end = (b.x + EDGE_ONE - 1) >> 8;
	if (x < 0)
		x = 0;
	if (end > CUBE_WIDTH)
		end = CUBE_WIDTH;
	if (x >= end)
		return;

	slope = (b.depth - a.depth) * EDGE_ONE / (b.x - a.x);
	depth = a.depth + ((x * EDGE_ONE - a.x) * slope) / EDGE_ONE;
	for (; x < end; ++x, depth += slope) {
		unsigned short sample = (unsigned short)(depth >> 8);

		if (sample >= zrow[x]) {
			zrow[x] = sample;
			row[x] = ink;
		}
	}
}

static void paint_half(const struct point *a, const struct point *b,
		       const struct point *top, const struct point *bottom,
		       unsigned char *pixels, unsigned short *z, int band,
		       unsigned char ink)
{
	int y = a->y < band ? band : a->y;
	int end = b->y > band + BAND_ROWS ? band + BAND_ROWS : b->y;
	struct edge left, right;

	if (y >= end)
		return;
	left = edge_at(a, b, y);
	right = edge_at(top, bottom, y);
	for (; y < end; ++y) {
		paint_span(pixels + y * CUBE_WIDTH, z + (y - band) * CUBE_WIDTH,
			   left, right, ink);
		left.x += left.x_dy;
		left.depth += left.depth_dy;
		right.x += right.x_dy;
		right.depth += right.depth_dy;
	}
}

static void paint_triangle(const struct point *a, const struct point *b,
			   const struct point *c, unsigned char *pixels,
			   unsigned short *z, int band, unsigned char ink)
{
	const struct point *swap;

	if (a->y > b->y) {
		swap = a; a = b; b = swap;
	}
	if (b->y > c->y) {
		swap = b; b = c; c = swap;
	}
	if (a->y > b->y) {
		swap = a; a = b; b = swap;
	}
	if (a->y == c->y || c->y <= band || a->y >= band + BAND_ROWS)
		return;
	paint_half(a, b, a, c, pixels, z, band, ink);
	paint_half(b, c, a, c, pixels, z, band, ink);
}

static void paint_stage(unsigned char *pixels, unsigned phase, int hinge)
{
	unsigned star = 0x5176u;
	int shadow = 44 + (64 - hinge) / 2;

	for (int y = 0; y < CUBE_HEIGHT; ++y) {
		for (int x = 0; x < CUBE_WIDTH; ++x) {
			int dx = x - CUBE_WIDTH / 2, dy = y - 119;
			unsigned ink = SKY;

			if (y >= 103) {
				ink = FLOOR_DARK;
				if (y == 103)
					ink = FLOOR_HORIZON;
				if (y == 106 || y == 110 || y == 116 || y == 125 || y == 137)
					ink = FLOOR_LIGHT;
				if (dx * dx * 64 + dy * dy * shadow * shadow < shadow * shadow * 64)
					ink = SKY;
			}
			pixels[y * CUBE_WIDTH + x] = (unsigned char)ink;
		}
	}
	for (unsigned i = 0; i < 30; ++i) {
		star = (star * 25173u + 13849u) & 0xffffu;
		unsigned x = (star >> 1) % CUBE_WIDTH;
		unsigned y = ((star >> 8) + i * 23) % 97;

		pixels[y * CUBE_WIDTH + x] = ((i + (phase >> 4)) & 7) ? STAR : 30;
	}
}

void cube_render(unsigned phase, unsigned char *pixels)
{
	enum { QUADS_PER_FACE = 19, QUADS = 6 * QUADS_PER_FACE };
	struct panel panels[6];
	struct quad quads[QUADS];
	unsigned short z[BAND_ROWS * CUBE_WIDTH];
	struct quad *q = quads;
	unsigned angle;
	int hinge, tilt;
	struct view view;

	phase &= CUBE_PHASES - 1;
	hinge = fold_angle(phase);
	angle = phase * 2 + 24;
	tilt = -15 + wave(phase * 2 + 48) / 32;
	view = (struct view) {
		wave(angle), wave(angle + 64),
		wave((unsigned)tilt), wave((unsigned)(tilt + 64)),
		114 + hinge * 60 / 64,
	};
	paint_stage(pixels, phase, hinge);
	make_panels(panels, (unsigned)hinge, &view);
	view.focal = frame_focal(panels, view.focal);

	for (unsigned i = 0; i < 6; ++i) {
		const struct panel *p = &panels[i];
		unsigned base = FACE_FIRST + i * 4;
		unsigned shade = panel_shade(p);

		add_quad(q++, p, -HALF, -HALF, HALF, HALF, view.focal, 0, SEAM);
		for (int y = -HALF; y < HALF; y += 16) {
			for (int x = -HALF; x < HALF; x += 16) {
				add_quad(q++, p, x + 1, y + 1, x + 15, y + 15,
					 view.focal, DEPTH_BIAS, base + (shade ? shade - 1 : 0));
				add_quad(q++, p, x + 2, y + 2, x + 14, y + 14,
					 view.focal, 2 * DEPTH_BIAS, base + shade);
			}
		}
	}

	for (int band = 0; band < CUBE_HEIGHT; band += BAND_ROWS) {
		for (unsigned i = 0; i < BAND_ROWS * CUBE_WIDTH; ++i)
			z[i] = 0;
		for (const struct quad *face = quads; face < q; ++face) {
			paint_triangle(&face->a, &face->b, &face->c, pixels, z, band, face->ink);
			paint_triangle(&face->a, &face->c, &face->d, pixels, z, band, face->ink);
		}
	}
}
