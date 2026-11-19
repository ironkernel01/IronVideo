/* SPDX-License-Identifier: GPL-2.0-only */
#include "cube.h"

#include <stdio.h>
#include <string.h>

static unsigned char guarded[CUBE_WIDTH * CUBE_HEIGHT + 2];
static unsigned char repeat[CUBE_WIDTH * CUBE_HEIGHT];
static unsigned char montage[2 * CUBE_HEIGHT][4 * CUBE_WIDTH];
static const unsigned previews[] = { 0, 16, 32, 40, 56, 64, 88, 112 };

static int write_preview(const char *path)
{
	FILE *file = fopen(path, "wb");
	unsigned x, y;
	int failed;

	if (!file)
		return 1;
	fprintf(file, "P6\n%u %u\n255\n", 4 * CUBE_WIDTH, 2 * CUBE_HEIGHT);
	for (y = 0; y < 2 * CUBE_HEIGHT; y++)
		for (x = 0; x < 4 * CUBE_WIDTH; x++) {
			unsigned rgb = cube_palette[montage[y][x]];

			fputc((rgb >> 16) & 255, file);
			fputc((rgb >> 8) & 255, file);
			fputc(rgb & 255, file);
		}
	failed = ferror(file);
	return fclose(file) != 0 || failed;
}

int main(int argc, char **argv)
{
	unsigned char *frame = guarded + 1;
	unsigned phase, i, x, y, sample = 0;

	for (phase = 0; phase < CUBE_PHASES; phase++) {
		unsigned count[32] = { 0 };
		unsigned faces = 0;

		memset(frame, 255, sizeof(repeat));
		guarded[0] = 0x55;
		guarded[sizeof(guarded) - 1] = 0xaa;
		cube_render(phase, frame);
		if (guarded[0] != 0x55 || guarded[sizeof(guarded) - 1] != 0xaa)
			goto fail;
		for (i = 0; i < sizeof(repeat); i++) {
			if (frame[i] == 1 || (frame[i] >= 6 && frame[i] < 30)) {
				unsigned px = i % CUBE_WIDTH, py = i / CUBE_WIDTH;

				if (px < 2 || px >= CUBE_WIDTH - 2 ||
				    py < 2 || py >= CUBE_HEIGHT - 2)
					goto fail;
			}
			if (frame[i] >= 32)
				goto fail;
			count[frame[i]]++;
		}
		for (i = 6; i < 30; i += 4)
			faces += count[i] + count[i + 1] + count[i + 2] + count[i + 3] > 8;
		/* Each face has four shades. The closed cube hides three faces. */
		if (!faces || (phase == 0 && faces != 3) || (phase == 60 && faces != 6))
			goto fail;
		cube_render(phase + CUBE_PHASES, repeat);
		if (memcmp(frame, repeat, sizeof(repeat)))
			goto fail;
		if (sample < sizeof(previews) / sizeof(previews[0]) &&
		    phase == previews[sample]) {
			x = (sample % 4) * CUBE_WIDTH;
			y = (sample / 4) * CUBE_HEIGHT;
			for (i = 0; i < CUBE_HEIGHT; i++)
				memcpy(&montage[y + i][x], &frame[i * CUBE_WIDTH], CUBE_WIDTH);
			sample++;
		}
	}
	if (argc > 1 && write_preview(argv[1])) {
		fprintf(stderr, "Cannot write preview to %s\n", argv[1]);
		return 1;
	}
	printf("PASS: %u cube phases\n", CUBE_PHASES);
	return 0;

fail:
	fprintf(stderr, "Cube regression failed in phase %u\n", phase);
	return 1;
}
