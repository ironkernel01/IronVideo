# IronVideo

IronVideo is a progressive framebuffer scanout core. It reads little-endian
XRGB8888 pixels from DDR over a read-only AXI4 master, applies software-defined
raster timing, and generates RGB, data enable, and horizontal and vertical
sync. Use the portable SystemVerilog scanout core with an external display
transmitter, or instantiate the included AMD 7-series AXI-to-TMDS top.
AXI4-Lite controls timing, framebuffer selection, and diagnostics.

The 7-series backend produces DVI-compatible TMDS video over an HDMI connector.
720p60 has been verified on a physical Nexys Video. Independent serialized
720p60 and 1080p60 benches verify their full rasters in simulation.
The shared C driver supports U-Boot firmware scanout and Linux DRM/KMS.
Board design, constraints, device tree, and boot policy belong to the
integrating project.

The three-page product brief is in `documentation/ironvideo_brief.pdf`.
The full integration and register specification is in
`documentation/ironvideo_specification.pdf`. Their Markdown sources and
architecture drawing are in the same documentation directory.

| Module | Interface and role |
| --- | --- |
| `ironvideo_scanout` | AXI4-Lite registers and IRQ on `axi_clk`. Validates modes and coordinates configuration and status handshakes with the raster. |
| `ironvideo_reader` | Read-only DDR AXI4 on `axi_clk`. Reserves FIFO space and fetches active lines. |
| `ironvideo_fifo` | Dual-clock RAM carries read beats and line/frame markers from the reader to the raster. |
| `ironvideo_raster` | Unpacks pixels and generates RGB, DE, HS and VS on `pixel_clk`. |
| `ironvideo_top` | Public AXI-to-TMDS top with Vivado interface metadata. Nexys sets 128-bit reads, 32-beat bursts and a 16 KiB FIFO. |
| `ironvideo_row_stats` | Measures completed DDR row fetches and records diagnostic counters. |
| `ironvideo_hdmi_7series` | Internal composition of the scanout and 7-series TMDS backend. |
| `ironvideo_tmds_7series` | Converts RGB and sync to three differential data pairs and a forwarded differential clock pair. |

## RTL and interfaces

Compile `ironvideo_pkg.sv`, `ironvideo_reset.sv`, `ironvideo_fifo.sv`,
`ironvideo_reader.sv`, `ironvideo_raster.sv`, `ironvideo_row_stats.sv`,
and `ironvideo_scanout.sv` in that order from `hdl/` for RGB scanout. Supply `axi_clk` for both AXI interfaces,
`pixel_clk` for the raster, and the common active-low `reset_n`.

| Parameter | Default | Supported values |
| --- | ---: | --- |
| `DATA_WIDTH` | 64 | 32, 64, or 128 bits |
| `MAX_BURST` | 64 | 1–256 AXI beats |
| `FIFO_KIB` | 16 | Requested payload capacity in KiB, clamped to at least 16, rounded up to a power of two, maximum 128 |
| `ARQOS` | 15 | 0–15 |
| `AXI_ID_WIDTH` | 1 | Positive integer. All requests use ID zero. |

The read master issues full-width, aligned INCR bursts with ARLOCK=0,
ARCACHE=3, and ARPROT=0. It reserves room for the entire active line before
presenting its first request, then fetches that line without waiting for
more FIFO space. Each burst is capped by the configured limit, remaining
beats on the line, and the next 4 KiB boundary. Only one burst is in flight.
RREADY remains asserted through the response. ARVALID and its payload remain
stable until ARREADY, including during a stop. The reader skips stride padding
and restarts at the base after the last active line.

The minimum 16 KiB of FIFO payload holds two 1920-pixel XRGB8888 rows
(15,360 bytes). The payload size determines the power-of-two beat depth for
the selected bus width. Per-beat markers and the held read beat use additional
storage. Actual implementation resource use depends on the target memory
resources and packing.

Each 32-bit little-endian pixel is `0xXXRRGGBB`. A beat begins with the pixel
in bits [31:0] and continues in increasing byte address order. The RGB output
is `{R,G,B}`. DE is high for the active rectangle and RGB is black in blanking.
HS and VS are active in the programmed sync intervals at their programmed
polarities. The raster begins at the top-left active pixel. A test pattern uses
`R=x[7:0]`, `G=y[7:0]`, `B=R ^ G` and produces no DDR requests.

The core generates pixels and timing at the externally supplied pixel rate.
For AXI-to-TMDS scanout, instantiate `ironvideo_top` directly in HDL or as
a Vivado module reference. It exposes the same AXI ports, register map,
parameters, and IRQ as the scanout core alongside the TMDS pairs. Its
`FAMILY` parameter defaults to `"7SERIES"`. Other families are rejected
at elaboration. Compile `ironvideo_tmds_encoder.sv`,
`ironvideo_tmds_lane_7series.sv`, `ironvideo_tmds_7series.sv`, and
`ironvideo_hdmi_7series.sv`, and `ironvideo_top.v` after the scanout sources,
with the 7-series primitives. The Vivado read-master metadata declares the AXI4 ceiling of 256 beats.
The configured `MAX_BURST` sets the actual request limit.
The backend is available separately as
`ironvideo_tmds_7series` for RGB/DE/HS/VS integration with independent
backend reset. Supply a phase-related clock at exactly 5× pixel rate.
Hold reset active through clock startup. The serializer sends TMDS symbols LSB
first with blue/green/red on lanes 0/1/2. The blue lane carries HS and VS
during blanking. The fourth differential pair forwards the pixel clock.
This is DVI-compatible video over an HDMI connector.

The board design must supply a compatible TMDS_33 output bank, a legal
OSERDESE2 master/slave placement, and I/O and clock constraints for the
selected connector. A physical mode also depends on DDR service, serializer
timing, signal integrity and the display. HDMI audio, HDMI infoframes,
DDC/EDID, interlace and color-space conversion are outside this interface.

## Register map

AXI4-Lite uses 32-bit data at aligned byte offsets. The scanout core has an
8-bit offset port. The public Vivado top exposes 16-bit offsets and rejects
nonzero upper address bits. Unaligned or unimplemented offsets and writes to
read-only registers return SLVERR. AW and W can
arrive in either order. WSTRB enables byte writes, and reserved fields read
zero. Registers reset to zero except identity and capabilities and the derived
status flags. The minimum FIFO level becomes `0xffff` on the first application
of a configuration, until the first framebuffer pixel is consumed.

| Offset | Register | Access | Definition |
| --- | --- | --- | --- |
| 0x00 | ID | RO | `0x49525644` |
| 0x04 | VERSION | RO | `0x00010001` |
| 0x08 | CAPABILITIES | RO | Data width in bits [7:0], FIFO address bits [15:8], maximum burst beats [24:16] |
| 0x0c | CONTROL | RW | [0] requested enable, [1] shadow test pattern, [2] commit, [3] snapshot. The two command bits read zero. Preserve bits [1:0] when issuing a snapshot. |
| 0x10 | STATUS | RO | [0] valid configuration accepted, [1] configuration busy, [2] applied enable, [3] quiesced, [4] snapshot busy, [5] requested enable |
| 0x14 | FAULT | W1C | [0] rejected control command, [1] non-OKAY RRESP or wrong RID, [2] unexpected RLAST position, [3] underflow or stream alignment loss. A new event wins over a simultaneous clear. |
| 0x18 | IRQ_MASK | RW | One enable per FAULT bit. IRQ is active high when any enabled fault is sticky. |
| 0x1c | FIRST_FAULT | RO | First event type as a one-hot FAULT mask. Clears with W1C of that type. For simultaneous faults, response/ID takes priority over RLAST, then stream, then control. |
| 0x20 | FB_BASE | RW shadow | First active pixel's byte address |
| 0x24 | FB_STRIDE | RW shadow | Bytes from one active line to the next |
| 0x28 | WINDOW_BASE | RW shadow | First allowed byte address |
| 0x2c | WINDOW_BYTES | RW shadow | Allowed size in bytes, exclusive end |
| 0x30 | H_ACTIVE | RW shadow | Active pixels, bits [15:0] |
| 0x34 | H_FRONT | RW shadow | Front porch pixels, bits [15:0] |
| 0x38 | H_SYNC | RW shadow | Sync pixels, bits [15:0] |
| 0x3c | H_BACK | RW shadow | Back porch pixels, bits [15:0] |
| 0x40 | V_ACTIVE | RW shadow | Active lines, bits [15:0] |
| 0x44 | V_FRONT | RW shadow | Front porch lines, bits [15:0] |
| 0x48 | V_SYNC | RW shadow | Sync lines, bits [15:0] |
| 0x4c | V_BACK | RW shadow | Back porch lines, bits [15:0] |
| 0x50 | POLARITY | RW shadow | [0] HS active high, [1] VS active high. Zero selects active low. |
| 0x54 | PREFILL | RW shadow | Minimum buffered beats for initial acquisition and stream recovery, bits [15:0] |
| 0x58 | UNDERFLOWS | RO snapshot | Number of stream lock losses modulo 2^32 |
| 0x5c | FIFO_LOW_WATER | RO snapshot | Minimum FIFO occupancy in beats at framebuffer pixel consumption since the last configuration application |
| 0x60 | RASTER_XY | RO snapshot | Scan counter [31:16] y, [15:0] x at snapshot |
| 0x64 | FRAMES | RO snapshot | Completed raster frames modulo 2^32, including black or test-pattern frames |
| 0x68 | UNDERFLOW_XY | RO snapshot | Latest lost pixel position [31:16] y, [15:0] x |
| 0x6c | FIRST_FAULT_ADDR | RO | AXI beat byte address for a first DDR fault, zero for other types |
| 0x70 | FIFO_CAPACITY_BYTES | RO | Actual rounded RAM payload capacity in bytes |
| 0x74 | DMA_STATUS | RO | [0] fetching a reserved row, [1] AR waiting for ARREADY, [2] R waiting for RVALID, [3] halted by DDR fault, [4] row-time saturation since commit |
| 0x78 | ROW_LAST_CYCLES | RO | Last completed row's fetch time in pixel ticks, or zero until a row completes |
| 0x7c | ROW_BYTES | RO | Active framebuffer row size in bytes, or zero in pattern mode or before first commit |
| 0x80 | ROW_SAMPLES | RO | Completed row fetches since commit, modulo 2^32 |
| 0x84 | ROW_WORST_CYCLES | RO, clear on read | Longest completed row fetch since this register was last read or the mode was committed |
| 0x88 | ROW_BEST_CYCLES | RO, clear on read | Shortest completed row fetch since this register was last read or the mode was committed |
| 0x8c | READ_BEATS | RO | Accepted R beats since commit, modulo 2^32, including discarded beats |
| 0x90 | READ_BURSTS | RO | Accepted AR requests since commit, modulo 2^32 |
| 0x94 | READ_ERRORS | RO | DDR fault events since commit, modulo 2^32. Faults first detected together count as one event. |

A commit validates the nominated pattern or framebuffer mode. Active and
sync intervals must be positive. Either porch may be zero. Each axis total
must fit 16 bits. Framebuffer modes additionally require the base, stride,
and active line byte length to be beat-aligned, the stride at least the
active line byte length, that line to fit in FIFO RAM, and prefill from 1 to the RAM depth. The window is
nonempty and may have an exclusive end of exactly 2^32. The entire last
active line must end at or before the window's exclusive end. Widened
arithmetic prevents acceptance of wrapped frame or window addresses. The
pattern uses only the timing and polarity fields. Software owns the actual
DDR allocation and programs a matching aperture.

## Commit, stop, and diagnostics

1. Write all shadow fields and set CONTROL.PATTERN as desired on the commit
   write. Commit can include enable or leave the raster stopped. AXI-Lite
   accepts the address and data normally and can defer the write response
   until the validation pipeline reflects the latest shadow settings. Poll until
   STATUS.BUSY clears. A rejected command returns SLVERR, latches the control
   fault, and leaves the previous settings in force. Commit or changes of
   requested enable while busy return SLVERR. Shadow edits are permitted while
   busy and take effect at a subsequent commit.
2. An accepted commit freezes a copy of the configuration, stops issuing new
   bursts, and drains any already presented AR or accepted read. The AXI
   domain then captures the FIFO's final write cursor and toggles a request.
   The pixel domain discards the remaining FIFO entries and applies the new
   settings at the old raster's frame boundary, or immediately after flush
   if disabled. It acknowledges the request before the AXI domain restarts
   reads. A live commit can blank the end of the old frame and the initial
   frames of the new mode while new data accumulates.
3. Write enable zero and wait for STATUS.QUIESCED to stop. Quiesced means the
   last AXI transaction drained and the pixel raster is stopped. Re-enable
   the committed mode by writing enable one. To change the pixel frequency,
   stop and wait for quiesced with both clocks running. Hold the external
   TMDS backend in its safe state, change the clocks, wait for lock, then
   commit the matching timing and enable. The combined 7-series top has
   one reset for the backend and scanout. After quiescing, assert that
   reset through the clock change and rewrite configuration after release.
4. Request a status snapshot while preserving CONTROL[1:0]. Poll
   STATUS.SNAPSHOT_BUSY until clear and read the coherent snapshot bank.
   A new request while a snapshot is busy returns SLVERR. Snapshot and
   configuration are separate handshakes. Serialize concurrent MMIO users
   so all fields in a software sample come from the same snapshot.
5. A stream underflow leaves the raster timing running. RGB is black from
   the missing pixel and the rest of that frame is discarded. The reader
   continues, and the raster resumes only from a new start-of-frame marker
   with prefill at a raster frame boundary. Initial prefill blacking before
   a stream first acquires does not count as a loss. A DDR response or ID
   fault, early RLAST, or missing RLAST suppresses further useful data.
   Read FAULT and FIRST_FAULT_ADDR, correct the fault source, and stop/start
   or issue a valid commit to restart. W1C acknowledges diagnostics and
   does not restart the DMA engine. A malformed transaction that never
   produces matching RLAST can require a coordinated fabric reset.

## CDC and reset contract

The Gray FIFO cursors, Gray pixel timebase, and Gray underflow count are registered at the
source and synchronized through four stages. The pixel domain's BRAM read
port prefetches one held beat. The write-side capacity tracks only RAM
entries and conservatively delays newly freed space until pointer
synchronization. Held valid data never relies on simultaneous cross-port
read and write of the same physical RAM address.

Configuration payload, enable, and final FIFO cursor are bundled with the
config toggle and held until acknowledgment. The pixel domain compares its
read cursor against that final cursor, including draining the held beat.
Snapshot data is bundled with the return toggle and held until a new request.
Single-bit request/acknowledgment and DDR-fault level crossings use four
synchronizer stages. The continuously synchronized Gray count is only used
to detect new fault events. Software reads the binary count via a snapshot.

At integration, constrain Gray bus skew and source-to-first-stage max delay
to keep consecutive Gray transitions from overlapping at the destination.
Bound bundled-data paths to settle before the earliest receive-side capture
through the four-stage control synchronizer. Apply CDC constraints to the
specific endpoints, retain synchronizer attributes and stages, and check
actual post-synthesis and post-route reports. The AXI and pixel clocks can
be independent.

Assert the common reset for both domains. The reset synchronizers assert
asynchronously and release after four corresponding rising edges. Local
state resets on its domain clock. The AXI valid and ready outputs are
masked immediately on reset assertion. Run both clocks through reset and release.
Resetting during bus activity requires the AXI fabric to cancel its
outstanding work. A normal stop or mode change drains both sides using the
cursor handshake with both clocks running and preserves the shared FIFO
pointer state. The BRAM contents require no reset.

## Row fetch measurements

IronVideo measures each DDR line from the first ARVALID presentation, after
reserving the whole line, to the final successful write into FIFO RAM.
The measurement includes request stalls, response stalls and gaps between
bursts. It excludes the initial wait for FIFO space and omits rows aborted
by a stop, mode change, or read fault. The counters measure IronVideo's own
row fetch timing. They provide no aggregate DDR-controller utilization.

The free-running video-domain counter advances each pixel clock and crosses
to AXI as 64-bit Gray code. Both timestamps use the same synchronized counter.
Tick quantization is approximately one pixel clock. Completed rows report
at least one tick. Values above 32 bits saturate at `0xffffffff` and set
DMA_STATUS[4]. A successful commit resets the measurement epoch after old
DMA drains. Read the statistics after STATUS.BUSY clears. An enable-only
transition preserves the current epoch.

A successful AXI4-Lite read address handshake for either extreme captures
the old value for the response and clears that register once. A row completing
in the same AXI cycle begins the next interval. Zero means no sample. The
read response stays stable under backpressure. Serialize diagnostic polling
with mode changes when reading multiple registers.

- Calculate effective transfer rate for a sample as
  `ROW_BYTES * pixel_clock_hz / row_cycles` in bytes/s. The shortest row
  time gives peak measured bandwidth. The longest row time gives worst latency.
- Calculate the fraction of the horizontal row budget used as
  `100 * row_cycles / (H_ACTIVE + H_FRONT + H_SYNC + H_BACK)`.
  This is a row-fetch budget measurement, and includes no unrelated DDR traffic.

## Boot and Linux handoff

- In U-Boot, reserve the framebuffer's physical DDR range before allocation
  or loading. Initialize XRGB8888 pixels, clean the CPU cache to the
  point visible to the DDR master as required by the platform, and order the
  framebuffer writes before enabling scanout. Program the validated aperture,
  geometry and timing, then enable and commit. Check status and faults.
- Retain the firmware framebuffer reservation and keep the display clocks
  and DDR master running until the Linux DRM/KMS driver
  stops and drains the engine. Linux then commits a framebuffer backed by
  its own GEM DMA allocation at the preconfigured pixel rate. The
  driver integration contract and build commands are in `driver/README.md`.

## Throughput

The scanout needs `width * height * refresh_hz * 4` bytes/s on average, plus
enough buffering to cover DDR service gaps during active video. For example,
720p60 requires about 221 MB/s and 1080p60 about 498 MB/s. Raw AXI bandwidth
is `DATA_WIDTH / 8 * axi_clk_hz`. The scheduler has two idle AXI cycles
between bursts even with immediately ready AR and a response on the next
cycle. With B beats per burst the ideal scheduler efficiency is B/(B+2)
before arbitration, DDR response latency, R bubbles and short boundary bursts.
A 32-bit port at 100 MHz has a 400 MB/s raw ceiling. Mode support needs
measurement under the intended DDR contention and routed clock rates.

## Test benches

Run the scripts from the standalone checkout in Windows PowerShell. Set the
tool paths for your installation. The XSim runner uses AMD Vivado 2026.1
with UNISIM and SecureIP simulation libraries.

```powershell
./simulate.ps1 -VivadoBin 'C:/AMDDesignTools/2026.1/Vivado/bin'
```

The nine XSim gates exercise the 32-, 64-, and 128-bit scanout configurations,
reader burst caps of 1, 64 and 256 beats, FIFO credit stalls, row statistics,
and TMDS encoding and serialization. The three full-frame RGB gates cover
720p60 under modeled DDR arbitration and response stalls. The 64-bit gate
uses a 64-beat cap and padded stride. The two 128-bit gates use 64-beat and
32-beat caps. The combined-top bench verifies decoded colors and AXI4-Lite
address checks. A separate elaboration control exercises rejection of an
unsupported FPGA family.

The end-to-end Active-HDL runners use Aldec Active-HDL 11.1 and AMD Vivado
device models. The benches `testbench/tb_ironvideo_720p_serial.sv` and
`testbench/tb_ironvideo_1080p_serial.sv` drive the public top through startup
and DDR-backed frames with read stalls. `testbench/ironvideo_serial_receiver.sv`
recovers the serialized symbols at the modeled differential pins and checks
decoded pixels and timing. Both simulators check the forwarded-clock phase
with the falling edge at the start of the `1111100000` word. The reversed-clock
negative test expects rejection at the first pixel.

```powershell
$aldecBin = 'C:/Aldec/Active-HDL-11.1-x64/bin'
$vivadoData = 'C:/AMDDesignTools/2026.1/data'
./activehdl.ps1 -AldecBin $aldecBin -VivadoData $vivadoData
./activehdl-negative-clock.ps1 -AldecBin $aldecBin -PositiveReceipt 'build/<positive-run>/receipt.json'
```

Replace the example receipt path with the successful two-mode path printed
by the first command. Each run creates logs and a receipt in a unique
directory under `build/`. The negative control checks the positive-run tool
and input identities before replaying them. All three runners accept
`-IronForgeRoot` to place results under the named workspace's
`build/ironvideo/` directory.

## Board integration example

Nexys Video uses 128-bit DDR reads at 100 MHz, a 32-beat request limit, a
16 KiB FIFO and CTA 720p60 clocks at 74.25 and 371.25 MHz. At 720p60
the horizontal intervals are 1280/110/40/220 pixels and the vertical
intervals are 720/5/5/20 lines, in active/front porch/sync/back porch order.
Both sync polarities are positive. A packed line is 5,120 bytes. On a 128-bit
port, a prefill of 320 beats buffers one packed row. The 1080p60 simulation
uses 148.5 MHz pixel and 742.5 MHz serializer clocks. Actual 1080p60 hardware
requires its own clock, timing, DDR and signal-integrity validation.

IronForge supplies the Nexys I/O pinout, clocking, CDC constraints, display
timings, and U-Boot and Linux build integration. Its logical reference is
`rtl/ironvideo/sources/IronVideo/`, which can bind to a physical IronVideo
checkout alongside IronForge and RTLNet. Other projects provide their own
board policy and implementation constraints and instantiate the same RTL
and driver directly from this checkout.
