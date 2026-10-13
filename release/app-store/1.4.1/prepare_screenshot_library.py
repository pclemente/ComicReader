#!/usr/bin/env python3
"""Create a dense, deterministic demo library from the approved 1905 scans.

This extends the existing nine-book screenshot fixture generator without changing
it. The extra books are explicitly demo cover editions, not distinct historical
issues. Only page-01.jpg, page-02.jpg and page-04.jpg are read. Nothing generated
by this script belongs in the application target or shipping app bundle.

The default output is outside the repository. The first nine books retain their
existing filenames and three full reading pages; later books have one approved
reading page, saving space while filling a realistic library grid.
"""

from __future__ import annotations

import argparse
from dataclasses import replace
from hashlib import sha256
import importlib.util
import io
import json
from pathlib import Path
import sys
import zipfile

from PIL import Image, ImageDraw, ImageOps

SCRIPT_DIR = Path(__file__).resolve().parent
BASE_SCRIPT = SCRIPT_DIR.parent / "prepare_sample_library.py"
COVER_SIZE = (600, 900)
EDITION_NAMES = ("Original", "Midnight", "Moonlight", "Sea Glass", "Golden Hour", "Twilight")
PALETTES = (
    ("#F3E2B8", "#172B3A", "#A3372B"),
    ("#172B3A", "#F3E2B8", "#C58A2A"),
    ("#A3372B", "#F3E2B8", "#172B3A"),
    ("#C58A2A", "#172B3A", "#F3E2B8"),
    ("#234E43", "#F5EACD", "#D2A750"),
    ("#F1E5CD", "#422D43", "#9B5C54"),
    ("#354B5B", "#EFE7D4", "#C87952"),
    ("#CBAE79", "#233542", "#486650"),
    ("#543748", "#F4E5BE", "#C9994E"),
    ("#E9DCC4", "#8B3F32", "#31544B"),
    ("#31556D", "#F1E6C8", "#D1A144"),
    ("#376C69", "#F0E7CF", "#253640"),
)


def base_generator():
    spec = importlib.util.spec_from_file_location("comicreader_sample_library", BASE_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load existing fixture generator: {BASE_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    if tuple(module.APPROVED_PAGES) != ("page-01.jpg", "page-02.jpg", "page-04.jpg"):
        raise RuntimeError("The source generator's approved scan list has changed")
    return module


def jpeg_bytes(image: Image.Image, quality: int) -> bytes:
    stream = io.BytesIO()
    image.save(stream, format="JPEG", quality=quality, optimize=True, progressive=True, subsampling=1)
    return stream.getvalue()


def compact_page(image: Image.Image) -> bytes:
    # These pages are only used by the additional library-grid demo editions.
    # The first nine books retain the existing generator's high-quality pages.
    page = ImageOps.contain(image, (1300, 1300), method=Image.Resampling.LANCZOS)
    return jpeg_bytes(page, quality=82)


def build(output: Path, count: int) -> dict:
    base = base_generator()
    output.mkdir(parents=True, exist_ok=True)
    source_images = {}
    for name in base.APPROVED_PAGES:
        with Image.open(base.SOURCE_DIR / name) as opened:
            source_images[name] = ImageOps.exif_transpose(opened).convert("RGB")
    reading_pages = {name: base.normalized_page_bytes(base.SOURCE_DIR / name) for name in base.APPROVED_PAGES}
    compact_pages = {name: compact_page(source_images[name]) for name in base.APPROVED_PAGES}

    columns, cell_width, cell_height = 9, 180, 285
    rows = (count + columns - 1) // columns
    contact = Image.new("RGB", (columns * cell_width + 40, rows * cell_height + 112), "#E7DECA")
    draw = ImageDraw.Draw(contact)
    draw.text((25, 20), "LITTLE NEMO · SCREENSHOT DEMO EDITIONS", font=base.load_font("display", 29), fill="#172B3A")
    draw.text((25, 58), "Approved 1905 artwork · Editorial cover variants · Not included with ComicReader",
              font=base.load_font("body", 19), fill="#425360")

    books = []
    for index in range(count):
        edition, original_index = divmod(index, len(base.VOLUMES))
        original = base.VOLUMES[original_index]
        if edition == 0:
            volume = original
        else:
            palette = PALETTES[(index + edition * 2) % len(PALETTES)]
            volume = replace(
                original, number=index + 1,
                slug=f"{original.slug}-{EDITION_NAMES[edition].lower().replace(' ', '-')}-edition",
                tagline=f"{EDITION_NAMES[edition]} Edition",
                focal_x=max(0.1, min(0.9, original.focal_x + (edition % 3 - 1) * 0.07)),
                focal_y=max(0.1, min(0.9, original.focal_y + ((edition + original_index) % 3 - 1) * 0.045)),
                crop_width=min(0.72, original.crop_width + (edition % 2) * 0.06),
                background=palette[0], foreground=palette[1], accent=palette[2],
            )
        cover = base.make_cover(volume, source_images).resize(COVER_SIZE, Image.Resampling.LANCZOS)
        cover_payload = jpeg_bytes(cover, quality=88)
        filename = f"little-nemo-{index + 1:02d}-{volume.slug}.cbz"
        target = output / filename
        if edition == 0:
            offset = original.number % len(base.APPROVED_PAGES)
            page_order = base.APPROVED_PAGES[offset:] + base.APPROVED_PAGES[:offset]
            pages = reading_pages
        else:
            page_order = (volume.source,)
            pages = compact_pages
        with zipfile.ZipFile(target, "w") as archive:
            base.write_zip_member(archive, "000-cover.jpg", cover_payload)
            for page_number, source_name in enumerate(page_order, start=1):
                base.write_zip_member(archive, f"{page_number:03d}-{Path(source_name).stem}.jpg", pages[source_name])
        with zipfile.ZipFile(target) as archive:
            if archive.testzip() is not None or len(archive.namelist()) != len(page_order) + 1:
                raise RuntimeError(f"Invalid CBZ archive: {target}")
        thumb = cover.resize((160, 240), Image.Resampling.LANCZOS)
        x, y = 20 + (index % columns) * cell_width, 100 + (index // columns) * cell_height
        contact.paste(thumb, (x, y))
        draw.text((x, y + 246), f"{index + 1:02d} · {EDITION_NAMES[edition]}", font=base.load_font("body", 16), fill="#172B3A")
        books.append({
            "filename": filename, "number": index + 1, "title": volume.title,
            "demo_edition": EDITION_NAMES[edition], "reading_scan_files": list(page_order),
            "page_count_including_cover": len(page_order) + 1, "bytes": target.stat().st_size,
            "sha256": sha256(target.read_bytes()).hexdigest(),
        })

    contact.save(output / "contact-sheet.jpg", format="JPEG", quality=90, optimize=True)
    manifest = {
        "purpose": "Imported demo library for genuine ComicReader screenshots; never shipped in the app bundle.",
        "content_note": f"Editorial cover editions repeat three approved public-domain 1905 scans; these are not {count} distinct historical comic issues.",
        "count": count, "total_archive_bytes": sum(book["bytes"] for book in books),
        "approved_sources": [{"filename": name, "sha256": sha256((base.SOURCE_DIR / name).read_bytes()).hexdigest()}
                             for name in base.APPROVED_PAGES],
        "source_credits": str(base.SOURCE_DIR / "sources.json"), "books": books,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        help="default: /tmp/ComicReader-Screenshot-Library-<count>")
    parser.add_argument("--count", type=int, choices=(36, 54), default=54)
    args = parser.parse_args()
    output = (args.output or Path(f"/tmp/ComicReader-Screenshot-Library-{args.count}")).resolve()
    result = build(output, args.count)
    print(f"Created {result['count']} demo CBZs in {output}")
    print(f"Combined archive size: {result['total_archive_bytes'] / (1024 * 1024):.1f} MB")
    print(f"Contact sheet: {output / 'contact-sheet.jpg'}")


if __name__ == "__main__":
    main()
