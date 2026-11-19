# IronVideo documentation

| Publication | Contents |
| --- | --- |
| `iron_brief.md` and `iron_brief.pdf` | Product brief with a Nexys bare-metal demo guide on page 4 covering the Vivado sources, programming image, UART controls and measured performance. |
| `ironvideo_specification.pdf` | Engineering specification for native formats, registers, DDR measurement, firmware and Linux integration, the Nexys bare-metal demo, and verification. |

The matching Markdown files are the publication sources. Both use the architecture illustration in `assets/architecture.png`.

## Publish the PDFs

From the IronVideo checkout, run the following command in PowerShell. The IronForge checkout supplies the shared publication style and renderer. The tools require Node.js, Chrome or Edge, and Poppler on the rendering host.

```powershell
.\documentation\build.ps1 -IronForgeRoot ..\IronForge
```

The command writes both PDFs next to their Markdown sources and validates page bounds, rasterization and link output. Review images are written under `build/documentation/`.

## Edit the architecture drawing

Edit the objects and wires in `diagrams/src/architecture.js`. With the IronForge drawing dependencies installed, the following commands generate an editable PowerPoint deck and export the publication figure using LibreOffice and Poppler. Run them from the IronVideo checkout.

```powershell
$forge = (Resolve-Path ..\IronForge).Path
node .\documentation\diagrams\src\architecture.js $forge
$out = (Resolve-Path .\documentation\diagrams\out).Path
& "$env:ProgramFiles\LibreOffice\program\soffice.com" --headless --convert-to pdf --outdir $out "$out\architecture.pptx"
pdftoppm -f 1 -l 1 -singlefile -r 160 -png "$out\architecture.pdf" .\documentation\assets\architecture
```

Regenerate the two publications after changing the figure.
