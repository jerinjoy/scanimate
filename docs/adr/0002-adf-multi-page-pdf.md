# ADF scans default to multi-page PDF

When the input source is ADF, the ScanJob retrieves pages until the feeder is empty, accumulating them as an array of JPEG images. The NSSavePanel defaults to PDF for ADF scans, and at export time PDFKit assembles a single multi-page PDF from the page array.

PDF is the natural format for multi-page document workflows on macOS, and it is what users expect when scanning a stack of papers. Multi-page TIFF is technically equivalent but uncommon in practice and poorly supported by consumer apps.

Flatbed scans default to PNG (single page, lossless) since they are more commonly photos or individual documents where a multi-page container adds no value.
