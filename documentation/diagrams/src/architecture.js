// Editable IronVideo engineering drawing. Pass the IronForge workspace as argv[2].
const path = require("node:path");
const fs = require("node:fs");

async function main() {
  const ironForgeRoot = process.argv[2];
  if (!ironForgeRoot) {
    throw new Error("Usage: node architecture.js <IronForge workspace>");
  }
  const helperPath = path.resolve(ironForgeRoot, "documentation/drawings/lib/engslides.js");
  const { newDeck, helpers } = require(helperPath);
  const deck = newDeck("IronVideo scanout architecture", "IronKernel");
  const { box, container, wire, label, notes, frame } = helpers(deck);
  const slide = deck.addSlide();
  frame(slide);
  container(slide, 2.78, 1.20, 8.42, 3.67, "ironvideo_top — AXI-to-TMDS integration");

  box(slide, 0.66, 1.68, 1.45, 0.70, "Software host", ["Mode and buffer control", "Fault handling"]);
  box(slide, 3.08, 1.68, 1.50, 0.70, "Control/status", ["AXI clock domain", "Timing, DMA and diagnostics"]);
  wire(slide, 2.11, 2.03, 3.08, 2.03, { start: true, dash: "dash" });
  label(slide, 2.12, 1.81, 0.64, "AXI4-Lite", 7.5, "center");

  box(slide, 0.66, 3.30, 1.45, 0.82, "DDR / AXI fabric", ["Packed RGB or YUV", "NV12 luma and chroma"]);
  box(slide, 3.08, 3.30, 1.50, 0.82, "AXI4 reader", ["Aligned read bursts", "Optional UV row cache"]);
  box(slide, 5.12, 3.30, 1.46, 0.82, "Dual-clock FIFO", ["Beats and row markers", "AXI write / pixel read"]);
  box(slide, 7.15, 3.30, 1.48, 0.82, "Raster", ["Pixel unpack and timing", "Optional YUV to RGB"]);
  box(slide, 9.18, 3.30, 1.64, 0.82, "7-series TMDS", ["Pixel clock encoder", "5× clock serializer"]);
  box(slide, 11.60, 3.30, 1.10, 0.82, "Display sink", ["HDMI connector"]);

  wire(slide, 2.11, 3.71, 3.08, 3.71, { start: true });
  label(slide, 2.13, 3.48, 0.63, "AXI4 read", 7.5, "center");
  wire(slide, 4.58, 3.71, 5.12, 3.71);
  wire(slide, 6.58, 3.71, 7.15, 3.71);
  wire(slide, 8.63, 3.71, 9.18, 3.71);
  wire(slide, 10.82, 3.71, 11.60, 3.71);
  label(slide, 11.24, 3.48, 0.34, "TMDS", 7.5, "center");

  wire(slide, 3.83, 2.38, 3.83, 2.78, { end: false, dash: "dash" });
  wire(slide, 3.83, 2.78, 3.83, 3.30, { dash: "dash" });
  wire(slide, 3.83, 2.78, 7.89, 2.78, { end: false, dash: "dash" });
  wire(slide, 7.89, 2.78, 7.89, 3.30, { dash: "dash" });
  label(slide, 4.95, 2.55, 2.10, "Configuration handshake", 7.5, "center");

  box(slide, 3.08, 5.19, 1.50, 0.54, "AXI clock", ["Board supplied"]);
  box(slide, 7.15, 5.19, 1.48, 0.54, "Pixel clock", ["Board supplied"]);
  box(slide, 9.18, 5.19, 1.64, 0.54, "5× serial clock", ["Phase-related"]);
  wire(slide, 3.83, 5.19, 3.83, 4.12, { dash: "dash" });
  wire(slide, 7.89, 5.19, 7.89, 4.12, { dash: "dash" });
  wire(slide, 10.00, 5.19, 10.00, 4.12, { dash: "dash" });

  notes(slide, 0.66, 6.09, 12.0, 0.81, [
    "The AXI clock serves both AXI interfaces and the FIFO write port. The pixel clock serves the FIFO read port, raster and TMDS encoder.",
    "The portable ironvideo_scanout produces RGB, data enable and sync at the raster output. The 7-series backend is used for TMDS output.",
    "TMDS comprises three data pairs and a forwarded pixel clock pair. Reset, interrupt and diagnostic return wiring are omitted."
  ]);

  const output = path.join(__dirname, "..", "out");
  fs.mkdirSync(output, { recursive: true });
  await deck.writeFile({ fileName: path.join(output, "architecture.pptx") });
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
