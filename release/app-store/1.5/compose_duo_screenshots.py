#!/usr/bin/env python3
"""Compose five genuine iPhone Duo App Store screenshots.

The compositor adds only typography, a background, a fine frame, and a shadow.
It preserves every pixel of each supplied app capture at its original aspect
ratio: no cropping, stretching, UI reconstruction, or device mockup is used.

Expected captures (native iPhone Duo inner-display PNGs):

    captures/duo/01-library.png
    captures/duo/02-reader.png
    captures/duo/03-search.png
    captures/duo/04-lists.png
    captures/duo/05-icloud.png

Example:

    python3 release/app-store/1.5/compose_duo_screenshots.py \
      --captures release/app-store/1.5/captures/duo \
      --output release/app-store/1.5/screenshots/en-GB/duo

Requires Pillow and the system Avenir Next font. Outputs are opaque RGB PNGs
at 2853 x 2007. Inputs must be complete inner-display captures at either
2853 x 2007 or 2007 x 2853, including the 2852 x 2006 dimensions returned
by XCUIScreen after fractional display-scale rounding. All five are validated and composed in memory
before any output is written. Existing unrelated output files are retained.
"""

from argparse import ArgumentParser
from dataclasses import dataclass
from hashlib import sha256
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


OUTPUT_SIZE = (2853, 2007)
# XCUIScreen rounds the 27.1 simulator capture by one pixel on each axis.
INNER_CAPTURE_SIZES = {(2853, 2007), (2007, 2853), (2852, 2006), (2006, 2852)}
FONT_PATH = Path("/System/Library/Fonts/Avenir Next.ttc")

PAPER = "#F4F0E7"
INK = "#171B20"
RED = "#DE5849"


@dataclass(frozen=True)
class Panel:
    filename: str
    category: str
    title: str
    subtitle: str
    footnote: str
    dark: bool

    @property
    def background(self) -> str:
        return INK if self.dark else PAPER

    @property
    def foreground(self) -> str:
        return PAPER if self.dark else INK

    @property
    def secondary(self) -> str:
        return "#C8C5BE" if self.dark else "#51585E"

    @property
    def rule(self) -> str:
        return "#3C4044" if self.dark else "#D2CDC3"


PANELS = (
    Panel(
        "01-library.png",
        "IPHONE DUO · YOUR LIBRARY",
        "A library made for iPhone Duo.",
        "Covers reflow around the active fold while keeping your place.",
        "iPhone Duo support is free for everyone.",
        True,
    ),
    Panel(
        "02-reader.png",
        "IPHONE DUO · THE READER",
        "Open every page on iPhone Duo.",
        "Keep your comic, current page and relative zoom as the display changes.",
        "Pages and controls stay clear of the active fold.",
        False,
    ),
    Panel(
        "03-search.png",
        "ONE-TIME PLUS · SEARCH & QUOTES",
        "Find the line with one-time Plus.",
        "Search the comic you’re reading and save editable quotes.",
        "ComicReader Plus · One purchase. No subscription.",
        True,
    ),
    Panel(
        "04-lists.png",
        "ONE-TIME PLUS · READING LISTS",
        "Line up your next read with one-time Plus.",
        "Build custom lists. Let Smart Queues gather what’s next.",
        "ComicReader Plus · One purchase. No subscription.",
        False,
    ),
    Panel(
        "05-icloud.png",
        "FREE ICLOUD SYNC",
        "Free iCloud sync across your devices.",
        "Sync comics, read status and your current page across iPhone, iPad and Mac.",
        "Free for everyone · Opt in with your personal iCloud storage.",
        True,
    ),
)


def font(size: int, weight: str = "regular") -> ImageFont.FreeTypeFont:
    if not FONT_PATH.is_file():
        raise RuntimeError(f"Required font is missing: {FONT_PATH}")
    indices = {"bold": 0, "demi": 2, "medium": 5, "regular": 7}
    return ImageFont.truetype(str(FONT_PATH), size, index=indices[weight])


def wrap_text(draw: ImageDraw.ImageDraw, text: str, selected_font, width: int) -> str:
    lines = []
    for paragraph in text.splitlines() or [""]:
        current = ""
        for word in paragraph.split():
            candidate = word if not current else f"{current} {word}"
            if draw.textlength(candidate, font=selected_font) <= width:
                current = candidate
            elif current:
                lines.append(current)
                current = word
            else:
                current = word
        lines.append(current)
    return "\n".join(lines)


def draw_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    box: tuple[int, int, int, int],
    size: int,
    minimum: int,
    colour: str,
    *,
    weight: str = "regular",
    wrap: bool = True,
    spacing: int = 10,
) -> tuple[int, int, int, int]:
    """Fit text to a reserved area, failing instead of clipping copy."""
    for candidate in range(size, minimum - 1, -1):
        selected_font = font(candidate, weight)
        fitted = wrap_text(draw, text, selected_font, box[2] - box[0]) if wrap else text
        bounds = draw.multiline_textbbox((0, 0), fitted, font=selected_font, spacing=spacing)
        width, height = bounds[2] - bounds[0], bounds[3] - bounds[1]
        if width <= box[2] - box[0] and height <= box[3] - box[1]:
            draw.multiline_text(
                (box[0] - bounds[0], box[1] - bounds[1]),
                fitted,
                font=selected_font,
                fill=colour,
                spacing=spacing,
            )
            return (box[0], box[1], box[0] + width, box[1] + height)
    raise ValueError(f"Caption does not fit its reserved area: {text!r}")


def draw_tracked(
    draw: ImageDraw.ImageDraw,
    text: str,
    position: tuple[int, int],
    size: int,
    colour: str,
    tracking: float,
) -> None:
    selected_font = font(size, "demi")
    x, y = position
    for character in text:
        draw.text((round(x), y), character, font=selected_font, fill=colour, anchor="lt")
        x += draw.textlength(character, font=selected_font) + tracking


def draw_brand(draw: ImageDraw.ImageDraw, panel: Panel) -> None:
    # The red rule is presentation decoration, not a recreated app icon.
    draw.rectangle((90, 78, 95, 112), fill=RED)
    draw_tracked(draw, "COMICREADER", (112, 78), 31, panel.foreground, 4.2)


def load_capture(path: Path) -> Image.Image:
    try:
        with Image.open(path) as opened:
            if opened.format != "PNG":
                raise ValueError(f"{path}: expected PNG, found {opened.format}")
            if getattr(opened, "n_frames", 1) != 1:
                raise ValueError(f"{path}: animated images are not supported")
            image = ImageOps.exif_transpose(opened)
            if image.size not in INNER_CAPTURE_SIZES:
                expected = " or ".join(f"{w} x {h}" for w, h in sorted(INNER_CAPTURE_SIZES))
                raise ValueError(
                    f"{path}: expected a full-resolution iPhone Duo inner capture at "
                    f"{expected}, found {image.width} x {image.height}"
                )
            rgba = image.convert("RGBA")
            flattened = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
            flattened.alpha_composite(rgba)
            result = flattened.convert("RGB")
            result.load()
            return result
    except OSError as exc:
        raise ValueError(f"{path}: cannot read image: {exc}") from exc


def add_capture(
    canvas: Image.Image,
    capture: Image.Image,
    panel: Panel,
) -> tuple[Image.Image, dict]:
    """Fit every source pixel into the right-hand presentation area."""
    area = (610, 64, 2783, 1943)
    border = 10
    available = (area[2] - area[0] - border * 2, area[3] - area[1] - border * 2)
    screen = ImageOps.contain(capture, available, method=Image.Resampling.LANCZOS)
    frame_width, frame_height = screen.width + border * 2, screen.height + border * 2
    left = area[2] - frame_width
    top = area[1] + (area[3] - area[1] - frame_height) // 2

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (left, top + 18, left + frame_width, top + frame_height + 18),
        radius=14,
        fill=(0, 0, 0, 96 if panel.dark else 55),
    )
    canvas = Image.alpha_composite(
        canvas.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(26))
    )
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        (left, top, left + frame_width - 1, top + frame_height - 1),
        radius=12,
        fill="#272C32" if panel.dark else "#E0DCD4",
        outline="#555A5E" if panel.dark else "#C9C5BD",
        width=2,
    )
    # A rectangular paste deliberately preserves the capture's outermost pixels.
    screen_left, screen_top = left + border, top + border
    canvas.paste(screen, (screen_left, screen_top))
    return canvas.convert("RGB"), {
        "source_size": list(capture.size),
        "rendered_size": list(screen.size),
        "capture_bounds": [
            screen_left,
            screen_top,
            screen_left + screen.width,
            screen_top + screen.height,
        ],
        "scale": screen.width / capture.width,
        "cropped": False,
        "aspect_preserved": True,
        "layout": "duo-side-caption",
    }


def compose(capture: Image.Image, panel: Panel, number: int) -> tuple[Image.Image, dict]:
    canvas = Image.new("RGB", OUTPUT_SIZE, panel.background)
    draw = ImageDraw.Draw(canvas)
    draw_brand(draw, panel)
    draw.text((528, 79), f"{number:02d}", font=font(30, "demi"), fill=panel.secondary, anchor="rt")
    draw_text(draw, panel.category, (90, 220, 540, 258), 25, 19, panel.secondary,
              weight="demi", wrap=False)
    draw.rectangle((90, 294, 178, 302), fill=RED)
    draw_text(draw, panel.title, (88, 344, 545, 960), 91, 63, panel.foreground,
              weight="demi", spacing=5)
    draw_text(draw, panel.subtitle, (92, 1020, 540, 1345), 39, 31, panel.secondary,
              spacing=12)
    draw.line((92, 1555, 520, 1555), fill=panel.rule, width=2)
    draw_text(draw, panel.footnote, (92, 1600, 540, 1850), 31, 25, panel.secondary,
              spacing=10)
    return add_capture(canvas, capture, panel)


def verify_output(path: Path) -> None:
    with Image.open(path) as image:
        image.load()
        if image.format != "PNG" or image.mode != "RGB" or image.size != OUTPUT_SIZE:
            raise RuntimeError(
                f"Invalid output {path}: {image.format}, {image.mode}, {image.size}; "
                f"expected PNG, RGB, {OUTPUT_SIZE}"
            )


def main() -> None:
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--captures", type=Path, required=True, help="directory containing the five raw captures")
    parser.add_argument("--output", type=Path, required=True, help="directory for the composed gallery")
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="validate and compose in memory without writing files",
    )
    args = parser.parse_args()

    capture_root = args.captures.resolve()
    output_root = args.output.resolve()
    if capture_root == output_root or capture_root in output_root.parents or output_root in capture_root.parents:
        parser.error("capture and output directories must be separate and non-nested")

    missing = [panel.filename for panel in PANELS if not (capture_root / panel.filename).is_file()]
    if missing:
        parser.error(f"{capture_root}: missing genuine app captures: {', '.join(missing)}")

    try:
        source_hashes = {
            panel.filename: sha256((capture_root / panel.filename).read_bytes()).hexdigest()
            for panel in PANELS
        }
        if len(set(source_hashes.values())) != len(PANELS):
            raise ValueError("the five source captures must be distinct images")
        loaded = {panel.filename: load_capture(capture_root / panel.filename) for panel in PANELS}
        rendered = []
        for number, panel in enumerate(PANELS, 1):
            result, placement = compose(loaded[panel.filename], panel, number)
            if result.mode != "RGB" or result.size != OUTPUT_SIZE:
                raise RuntimeError(f"Invalid composed image for {panel.filename}")
            rendered.append((panel, result, placement))
    except (RuntimeError, ValueError) as exc:
        parser.error(str(exc))

    if args.check_only:
        print(f"Validated 5 genuine iPhone Duo captures for {OUTPUT_SIZE[0]} x {OUTPUT_SIZE[1]} composition")
        return

    output_root.mkdir(parents=True, exist_ok=True)
    manifest = []
    for panel, result, placement in rendered:
        destination = output_root / panel.filename
        temporary = destination.with_name(f".{destination.name}.tmp")
        result.save(temporary, format="PNG", optimize=True)
        verify_output(temporary)
        temporary.replace(destination)
        manifest.append(
            {
                "filename": panel.filename,
                "size": list(OUTPUT_SIZE),
                "category": panel.category,
                "title": panel.title,
                "subtitle": panel.subtitle,
                "footnote": panel.footnote,
                "source": str(args.captures / panel.filename),
                "source_sha256": source_hashes[panel.filename],
                "output_sha256": sha256(destination.read_bytes()).hexdigest(),
                **placement,
            }
        )
    manifest_path = output_root / "composition-duo.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"Wrote 5 iPhone Duo screenshots at {OUTPUT_SIZE[0]} x {OUTPUT_SIZE[1]}")
    print(f"Output: {output_root}")


if __name__ == "__main__":
    main()
