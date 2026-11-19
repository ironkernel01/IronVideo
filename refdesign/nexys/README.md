# Nexys Video bare-metal reference design

This standalone example targets the Nexys Video rev A and its XC7A200T-1
Artix-7. It builds a BRAM-bootable FPGA image with a cacheless MicroBlaze,
the board’s DDR3 MIG, UARTLite and IronVideo. It needs no operating system,
Vitis BSP, or IronForge workspace.

## Build on Windows

Install AMD Vivado and the AMD bare-metal MicroBlaze GCC toolchain. The build
uses Vivado, UpdateMEM and `mb-gcc` from the same AMD installation. From the
IronVideo checkout, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File refdesign/nexys/build.ps1
```

Use `-AmdRoot` for a non-default installation, `-Stage firmware` for just
the executable, and `-Stage generate` to validate the Vivado block design
without routing. The default build compiles the firmware, routes the design,
checks timing and CDC, and inserts the ELF into the routed bitstream. Each
invocation uses a separate folder under `build/nexys-ref/`. The complete
image is `nexys-ironvideo-demo.bit`. The receipt records the actual input,
tool and output hashes.

The first hardware build fetches Digilent's Nexys Video rev A board MIG
project from the immutable `vivado-boards` revision
`d8d43ed9f3f7e367ee3de82782ed601d88305677`. The build script pins the exact
URL and SHA-256. Use `-Offline` for a verified cached file or
`-MigPrj <path>` to supply an existing copy with that hash. The original
MIG project is a Digilent input. The build derives the 128-bit AXI and
unbuffered system clock configuration in its output folder. AMD distributes
the generated MIG and MicroBlaze infrastructure under its tool and IP terms.

The reference example source is GPL-2.0-only, as identified in its source
headers. It instantiates the canonical `hdl/` modules and uses the same
portable register driver as the Linux adapter.

## Demonstration

UART is **115200 8N1**. The demo presents color bars at fixed **1280 × 720,
60 Hz** and automatically cycles through XRGB8888, RGB565, YUV422 (YUYV)
and YUV420 (NV12). It writes each format directly to DDR, using limited-range
BT.709 for the YUV formats. NV12 has a separate interleaved UV plane. The
reference CPU and AXI control fabric run at 80 MHz, with separate 100 MHz
and 200 MHz MIG inputs. The transmitter uses 74.25 MHz pixel and
371.25 MHz phase-related serial clocks. This design supports 720p60 as its
maximum mode.

The firmware drains scanout before rewriting DDR, programs the four formats
through the common register driver, and measures accepted DDR read beats and
completed frames over a 60-frame interval. UART displays average payload
MB/s, peak row MB/s, latest row time, FIFO low-water and scanout status.
The expected active payload is about
221.184 MB/s for XRGB8888, 110.592 MB/s for RGB565 and YUV422, and
82.944 MB/s for YUV420. It stops on a timed-out or rejected switch, bad DDR
payload count, read error, or scanout underflow. Measured scanout payload
does not include unrelated DDR traffic.
