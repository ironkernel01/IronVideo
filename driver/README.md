# IronVideo driver

`ironvideo.c` implements U-Boot firmware scanout and Linux DRM/KMS for
the IronVideo v1.1 register ABI (version `0x00010001`). Both builds use
`ironvideo_regs.h`. U-Boot selects the firmware implementation with
`__UBOOT__` and calls the API declared in `ironvideo.h`.

## Linux DRM/KMS

The driver exposes one atomic CRTC, primary plane, and DVI-compatible output.
It supports locally allocated, linear XRGB8888 GEM DMA buffers, including
userspace dumb buffers. The DRM fbdev client can supply the text console.
The primary plane spans the full mode and starts at the programmed plane
offset. It accepts no scaling, cropping coordinates or destination offsets.

The driver uses the device's DMA mapping, including board-defined address
translation. It programs an aperture covering the accessed portion of the
buffer. DMA addresses are limited to 32 bits. The first pixel address, active
row byte count, and stride must align to the configured AXI data beat. The
driver stops and drains scanout before changing timing or the aperture.
A framebuffer switch can blank the display. DRM completes events in software.
The interface covers fixed-clock progressive video and local DMA buffers.
Hardware vblank events, seamless flips, EDID/hotplug, imported DMA buffers,
and HDMI audio are outside its scope.

### Device tree and clocks

| Property | Meaning |
| --- | --- |
| `compatible` | `"ironkernel,ironvideo-v1"` |
| `reg` | AXI4-Lite MMIO range including offset `0x97` |
| `clocks` / `clock-names` | Clock handles named `"axi"` and `"pixel"` |
| `display-timings` | Native progressive timing with an exact `clock-frequency`, active dimensions, porches, sync lengths and polarities |

The platform supplies a running serializer clock at five times the pixel rate
with a fixed phase relationship and releases the common reset after clock
startup. The driver enables and holds the AXI and pixel clock rates while
bound. Both clocks must continue during stop, commit, and snapshot handshakes.
The native mode pixel rate must match the clock in Hz. Additional DRM modes
must match the pixel clock in integer kHz, use valid progressive timing,
fit the hardware's 16-bit axis totals, and pass FIFO, alignment and raw AXI
throughput checks. The frame period limit is 200 ms. Qualify each mode under
the intended DDR contention. Changing the pixel rate requires a platform
clock and reset sequence.

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

Add `ironvideo.c` to the board build and call `ironvideo_boot_scanout()`
from board glue. The provided `builtin.mk` selects the U-Boot build when
`IRONFORGE_IRONVIDEO_UBOOT` is set and optionally includes a board makefile
from `IRONVIDEO_BOOT_GLUE`.

Reserve the framebuffer region before load or allocation. Supply the mapped
register base, framebuffer address, reserved size, line stride, video timing,
and XRGB8888 fill color. The firmware driver validates the mode and window,
drains an active engine, paints and flushes the framebuffer, programs the
aperture, commits, and checks scanout through polled status. The board
supplies clocking, reset, MMIO mapping and the memory reservation. Keep DDR
and the display clocks running for Linux to take over.

## Row and raster diagnostics

Read `row_stats` under the bound platform device in sysfs. Each successful
read reports a configured measurement epoch and consumes the hardware's best
and worst completed row samples since their prior reads. A modeset or
framebuffer switch starts a new epoch. The extrema are read separately. If
`row_samples_after_extrema` differs from `row_samples`, at least one row
completed while the driver read the extrema.

`current_bytes_per_sec` uses the last complete row and `peak_bytes_per_sec`
uses the shortest measured row. Both use `row_bytes * pixel_clock_hz / cycles`.
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

IronForge binds the canonical checkout at `rtl/ironvideo/sources/IronVideo/`
and builds it in place. The physical IronVideo checkout can be a sibling of
the IronForge and RTLNet checkouts. IronForge owns the Nexys device tree,
board glue and boot integration.

`compile_check.py` is an object-only regression for a configured IronForge
MicroBlaze kernel and its pinned Linux source. From the standalone checkout,
set `$ironForgeRoot` to the IronForge workspace and run:

```powershell
& "$ironForgeRoot/downloads/tools/python-arm/python.exe" driver/compile_check.py `
    "$ironForgeRoot/build/nexys-video/linux" --ironforge-root "$ironForgeRoot"
```

The check compares the C and RTL registers, runs the pinned kernel's Kbuild
with the AMD MicroBlaze compiler, and records the object and build inputs.
A standalone run writes under `build/driver/`. The full IronForge Linux build
links the driver into the bootable kernel.
