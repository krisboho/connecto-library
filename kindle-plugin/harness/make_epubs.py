#!/usr/bin/env python3
"""Generate small, valid EPUB 2 files for the Shelf Sync test harness.

Usage: make_epubs.py OUT_DIR
Each book gets a few KB of filler so file-size checks are meaningful.
"""
import sys
import uuid
import zipfile
from pathlib import Path

BOOKS = [
    ("Book One", "Ada Tester"),
    ("Book Two", "Ben Tester"),
    ("Book Three", "Cy Tester"),
    ("Book Four", "Dee Tester"),
    ("Book Five: A Colon? Title", "Eve Tester"),
]


def make(path: Path, title: str, author: str) -> None:
    uid = str(uuid.uuid4())
    para = f"<p>{title} by {author}. " + ("Lorem ipsum dolor sit amet. " * 400) + "</p>"
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>{title}</dc:title><dc:creator>{author}</dc:creator>
    <dc:language>en</dc:language><dc:identifier id="bookid">urn:uuid:{uid}</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/></spine>
</package>"""
    ncx = f"""<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:{uid}"/></head>
  <docTitle><text>{title}</text></docTitle>
  <navMap><navPoint id="n1" playOrder="1"><navLabel><text>Start</text></navLabel><content src="c1.xhtml"/></navPoint></navMap>
</ncx>"""
    xhtml = f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head>
<body><h1>{title}</h1>{para}</body></html>"""
    container = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("toc.ncx", ncx, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("c1.xhtml", xhtml, compress_type=zipfile.ZIP_STORED)


def main() -> None:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for title, author in BOOKS:
        name = title.replace(":", " -").replace("?", "")
        make(out / f"{name}.epub", title, author)
    print(f"wrote {len(BOOKS)} epubs to {out}")


if __name__ == "__main__":
    main()
