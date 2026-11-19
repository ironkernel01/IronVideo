# IronVideo driver

`ironvideo.c` implements U-Boot firmware scanout and Linux DRM/KMS.
Both paths and freestanding programs use the same `ironvideo_core.h`
format validation and MMIO sequences. `ironvideo_regs.h` defines the register
ABI. The header needs standard C integer widths and platform MMIO callbacks.

| ID | Portable format | Buffer layout |
|---:|---|---|
| 0 | `IV_FORMAT_XRGB8888` | Little-endian 32-bit pixels |
| 1 | `IV_FORMAT_RGB565` | Little-endian 16-bit RGB |
| 2 | `IV_FORMAT_YUV422` | Packed YUYV bytes, two pixels per group |
| 3 | `IV_FORMAT_YUV420` | NV12 Y plane and separate interleaved Cb/Cr plane |

Hardware with the legacy XRGB8888-only mask uses ABI v1.1 (`0x00010001`).
The common driver assumes format zero and avoids all extension registers.
ABI v1.2 (`0x00010002`) advertises its actual formats at `0x98` and accepts a
shadow format selection at `0x9c`. NV12 adds UV base, pitch, window base and
window size at offsets `0xa0` through `0xac`. Every supported mask is
discovered at runtime.

## Linux DRM/KMS

The driver exposes one atomic CRTC, primary plane, and DVI-compatible output.
It advertises the hardware's supported linear formats as `DRM_FORMAT_XRGB8888`,
`DRM_FORMAT_RGB565`, `DRM_FORMAT_YUYV` and `DRM_FORMAT_NV12`. The last format
uses two independently validated memory planes on the same KMS primary
plane. YUV uses fixed BT.709 and limited range, exposed as DRM color
properties. The driver supports locally allocated GEM DMA buffers. The
fbdev console prefers XRGB8888 or, when unavailable, uses RGB565. YUV-only
profiles expose KMS without a fbdev console.
The primary plane spans the full mode and starts at the programmed plane
offset. It accepts no scaling, cropping coordinates or destination offsets.

The driver uses the device's DMA mappings and board address translation.
Each memory plane has an aperture that covers only the accessed portion
of its GEM buffer, including inter-row stride. DMA addresses are limited
to 32 bits. The first pixel address, active
row byte count, and stride must align to the configured AXI data beat. The
driver stops and drains scanout before changing timing or the aperture.
A framebuffer switch can blank the display. DRM completes events in software.
The interface covers progressive video at the board's supplied pixel rates and local DMA buffers.
Hardware vblank events, seamless flips, EDID/hotplug, imported DMA buffers,
and HDMI audio are outside its scope.

### Device tree and clocks

| Property | Meaning |
| --- | --- |
| `compatible` | `"ironkernel,ironvideo-v1"` |
| `reg` | AXI4-Lite range through `0x97` for v1.1, `0xb7` for the format extension, or `0xbb` for the clock selector |
| `clocks` / `clock-names` | Clock handles named `"axi"` and `"pixel"`. Add `"pixel-alt"` for the second clock pair on a selectable design. |
| `display-timings` | Progressive modes with pixel rate, active dimensions, porches, sync lengths and polarities. The `native-mode` property selects the preferred mode. |

The platform supplies a running serializer clock at five times the pixel rate
with a fixed phase relationship and releases the common reset after clock
startup. Keep the supplied clocks running through stop, commit and snapshot
handshakes. When the hardware advertises the clock selector, the driver drains
scanout, selects the pair matching the requested mode and waits for the selector
to report ready before enabling the raster. Additional DRM modes
must match a supplied pixel rate in integer kHz, use valid progressive timing,
fit the hardware's 16-bit axis totals, and pass FIFO and alignment checks.
The frame period limit is 200 ms. Packed formats use raw AXI bandwidth as
their admission ceiling. For NV12, inserting the expanded chroma/luma data
takes at least five AXI cycles per three source beats. The resulting
ceiling is three fifths of raw AXI bandwidth. At 25 MHz with a 32-bit port,
the raw ceiling is 100 MB/s and the NV12 ceiling is 60 MB/s, below the
82.944 MB/s required for 720p60 NV12. These ceilings are necessary checks.
Use actual row service and FIFO measurements under the intended DDR
contention to qualify a board.

The driver checks the ID and ABI, masks the hardware fault IRQ, and stops
and drains any firmware scanout before accepting a KMS mode. Keep firmware's
framebuffer reservation in the device tree and remove any competing
framebuffer driver for this engine. The Linux allocator needs DMA memory
reachable by IronVideo. A transition timeout keeps the affected buffer alive
until scanout quiesces. Removal retains the DMA buffer and clocks until
system reset if it cannot confirm quiescence.

### Build as an external Linux module

Prepare a kernel for the target architecture with module support, DRM,
Open Firmware, DMA and the Common Clock Framework. Enable DRM KMS Helper,
DRM GEM DMA Helper, DRM Client Selection and Videomode Helpers in the kernel
configuration. For the framebuffer console, enable DRM fbdev emulation
and select the fbdev DRM client. Build the target kernel so the external
module has a matching build tree and symbol versions.

Set `linux_src` and `linux_out` to the source and configured output
directories, `ironvideo_driver` to this `driver/` directory, and `module_out`
to an absolute module output directory. Set `arch` and `cross_compile` for
the target toolchain.

```sh
make -C "$linux_src" O="$linux_out" M="$ironvideo_driver" MO="$module_out" \
    ARCH="$arch" CROSS_COMPILE="$cross_compile" CONFIG_DRM_IRONVIDEO=m modules
```

For a built-in driver, source `driver/Kconfig` from the integrating kernel
Kconfig and include `driver/builtin.mk` from the DRM Makefile with paths
appropriate to your source layout. Select `CONFIG_DRM_IRONVIDEO=y` and
compile the source in place. Both methods put artifacts in the configured
build output.

## U-Boot handoff

Add `ironvideo.c` to the board build. The original `ironvideo_boot_scanout()`
accepts an XRGB8888 stride and uses that format when available. For hardware
without XRGB8888 it tries supported formats in RGB565, YUV422, YUV420 order.
Fallback uses packed rows and places NV12 chroma after the Y plane in the
same reserved window. `ironvideo_boot_scanout_format()` accepts an explicit
`iv_scanout` with the selected format and each plane's address and aperture.
Both functions take an RGB fill color and encode it in the selected format.

The provided `builtin.mk` selects the U-Boot build when
`IRONFORGE_IRONVIDEO_UBOOT` is set and optionally includes a board makefile
from `IRONVIDEO_BOOT_GLUE`.

Reserve the framebuffer region before load or allocation. Supply the mapped
register base, framebuffer address, reserved size, line stride, video timing,
and XRGB8888 fill color. The firmware driver validates the mode and window,
drains an active engine, paints and flushes the framebuffer, programs the
aperture, commits, and checks scanout through polled status. The board
supplies clocking, reset, MMIO mapping and the memory reservation. Keep DDR
and the display clocks running for Linux to take over.

## Freestanding programming

Include `ironvideo_core.h` and provide ordered little-endian `read32` and
`write32` callbacks in `struct iv_mmio`. An optional `barrier` orders CPU/DMA
writes before COMMIT. `poll_delay` can yield between reads. If a monotonic
`time_us` callback is supplied, set `timeout_us` as well. Each operation
also honors the caller's polling budget. The core does not allocate memory,
map DMA addresses, maintain CPU caches or lock competing users.

1. Call `iv_discover()` and inspect `iv_caps.format_mask`. Choose a format
   explicitly, or use `iv_preferred_format()` for the first supported ID.
2. Call `iv_format_geometry()` to calculate row payload, chroma height,
   frame payload and a one-row prefill. YUV422 needs even width.
   YUV420 needs even width and height. NV12 chroma rows contain one Cb/Cr
   byte pair per two luma columns and one chroma row per two luma rows.
   For width W, NV12 prefill is `2*W / beat_bytes` and frame traffic is
   `3*W*H/2` useful bytes.
3. Stop and wait for `iv_stop()` to report quiescence before overwriting or
   releasing old DMA memory. Fill and flush the new buffers. Populate
   `iv_scanout` with timing, prefill and DMA-visible plane descriptors.
   `iv_validate()` checks geometry and both apertures without touching MMIO.
4. Call `iv_commit()` with the enable request. `iv_read_snapshot()` captures
   raster progress and reads faults and traffic counters. `iv_clear_faults()`
   acknowledges sticky bits. A failed drain keeps the old memory owned
   until the engine quiesces or the fabric is reset.

## Row and raster diagnostics

Read `row_stats` under the bound platform device in sysfs. Each successful
read reports a configured measurement epoch and consumes the hardware's best
and worst completed row samples since their prior reads. A modeset or
framebuffer switch starts a new epoch. The extrema are read separately. If
`row_samples_after_extrema` differs from `row_samples`, at least one row
completed while the driver read the extrema.

`current_bytes_per_sec` uses the last completed row's actual DDR bytes and
cycles. In ABI v1.2, `peak_bytes_per_sec` uses the matched byte and cycle
pair from the greatest measured bytes-per-time ratio. Reading cycles at
`0xb0` clears that interval and latches the paired byte count at `0xb4`.
Read the pair in that order. ABI v1.1 uses the shortest row and constant
row byte count. Both rates are computed as `bytes * pixel_clock_hz / cycles`.
A zero cycle count means no sample. `worst_row_budget_permille` measures the
longest row as a fraction of the full horizontal period. A value of 1,000
represents one horizontal period. `dma_status` bit 4 reports row-time
saturation in the current epoch. These statistics cover the reader's own
row fetches after FIFO reservation, including AXI stalls.

The hardware snapshot supplies `underflows`, `fifo_low_water_beats`,
`frames`, `raster_xy`, and `underflow_xy`. The driver serializes the sysfs
read against modesets and reports live DMA status and sticky faults. In packed
coordinates, Y occupies the upper 16 bits and X the lower 16 bits. The driver
acknowledges stale faults before programming a new scanout commit.

## IronForge integration

IronForge builds the driver from the canonical checkout in `rtl/ironvideo/`.
IronForge owns the Nexys device tree,
board glue and boot integration.

`compile_check.py` is an object-only regression for a configured IronForge
MicroBlaze kernel and its pinned Linux source. From the standalone checkout,
set `$ironForgeRoot` to the IronForge workspace and run:

```powershell
& "$ironForgeRoot/downloads/tools/python-arm/python.exe" driver/compile_check.py `
    "$ironForgeRoot/build/nexys-video/linux" --ironforge-root "$ironForgeRoot" `
    --uboot-output "$ironForgeRoot/build/nexys-video/u-boot"
```

The check compares the C and RTL registers and compiles a native MicroBlaze
Linux object with the configured kernel's Kbuild. `--uboot-output` adds a
firmware object using the configured U-Boot board compile flags. Both
objects, logs and receipts go under `build/driver/` in a standalone checkout.
Full board builds link the drivers into bootable images.

For an independent host check, compile the test with a standard C compiler:

```sh
mkdir -p build/driver
cc -std=c11 -Wall -Wextra -Werror -O2 driver/test_ironvideo_core.c -o build/driver/test-ironvideo-core
./build/driver/test-ironvideo-core
```

The test models discovery and MMIO sequencing for all 15 masks and three
bus widths, including legacy register isolation, separate NV12 windows,
overflow, rejected commits and bounded waits.
