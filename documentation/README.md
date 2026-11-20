# IronVideo documentation

The [IronVideo Specification](ironvideo_specification.md) covers FPGA compatibility, registers, DDR measurement, firmware and Linux integration, and verification. It includes illustrated examples from the Nexys Video bare-metal MicroBlaze demo and the Zybo Z7-20 Linux demo. The [PDF](ironvideo_specification.pdf) is generated from the Markdown source.

## Publish the specification

From the IronVideo checkout, run the following command in PowerShell. The IronForge checkout supplies the shared publication style and renderer. The tools require Node.js, Chrome or Edge, and Poppler on the rendering host.

```powershell
.\documentation\build.ps1
```

The command finds IronForge when IronVideo is in `rtl/ironvideo/` or beside the IronForge checkout. For another layout, pass `-IronForgeRoot` with the workspace path. It writes the PDF next to its Markdown source and validates page bounds, rasterization and link output. Review images are written under `build/documentation/`.

## Edit the architecture drawing

Edit the objects and wires in `diagrams/src/architecture.js`. With the IronForge drawing dependencies installed, the following commands generate an editable PowerPoint deck and export the publication figure using LibreOffice and Poppler. Run them from `rtl/ironvideo/`, or set `$forge` to the IronForge workspace when using a standalone checkout.

```powershell
$forge = (Resolve-Path ..\..).Path
node .\documentation\diagrams\src\architecture.js $forge
$out = (Resolve-Path .\documentation\diagrams\out).Path
& "$env:ProgramFiles\LibreOffice\program\soffice.com" --headless --convert-to pdf --outdir $out "$out\architecture.pptx"
pdftoppm -f 1 -l 1 -singlefile -r 160 -png "$out\architecture.pdf" .\documentation\assets\architecture
```

Regenerate the specification PDF after changing the figure.
