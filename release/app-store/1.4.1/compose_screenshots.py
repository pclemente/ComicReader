#!/usr/bin/env python3
"""Compose five App Store screenshots for iPhone, iPad and Mac.

Every panel uses one complete, genuine app capture. The compositor only adds
typography, a background and a fine presentation border; it never crops,
stretches, retouches, or fabricates the app interface.

Mac inputs may omit OS titlebars or unused outer padding when the original
capture and exact crop bounds are retained. This preprocessing must preserve
every app control and all displayed content. The compositor does not crop any
part of its supplied input; its "cropped" manifest field describes that step.

Expected files in each captures/{iphone,ipad,macos} directory:
    01-library.png  02-reader.png  03-search.png  04-lists.png  05-icloud.png

Example:
    python3 release/app-store/1.4.1/compose_screenshots.py \
      --captures release/app-store/1.4.1/captures \
      --output release/app-store/1.4.1/screenshots/en-GB

Requires Pillow and the system Avenir Next font. Outputs are opaque RGB PNGs:
iPhone 1206 x 2622, iPad 2064 x 2752, Mac 2880 x 1800. All five source images
are required for each requested platform, so an incomplete set cannot silently
replace a complete store gallery. Existing unrelated output files are retained.
"""

from argparse import ArgumentParser
from dataclasses import dataclass
from hashlib import sha256
import json
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

PAPER = "#F4F0E7"
INK = "#171B20"
RED = "#DE5849"
FONT_PATH = Path("/System/Library/Fonts/Avenir Next.ttc")
IPHONE_SIZE = (1206, 2622)
IPAD_SIZE = (2064, 2752)
MACOS_SIZE = (2880, 1800)
PLATFORM_SIZES = {"iphone": IPHONE_SIZE, "ipad": IPAD_SIZE, "macos": MACOS_SIZE}
PLATFORM_NAMES = {"iphone": "iPhone", "ipad": "iPad", "macos": "Mac"}


@dataclass(frozen=True)
class Panel:
    filename: str
    title: str
    mac_title: str
    subtitle: str
    footnote: str
    category: str
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


PANELS = {
    "01-library.png": Panel(
        "01-library.png", "A home for every comic.", "A home for\nevery comic.",
        "Bring your PDF, CBZ and CBR collection.", "Your files. Your collection.",
        "YOUR LIBRARY", True,
    ),
    "02-reader.png": Panel(
        "02-reader.png", "Get lost in the story.", "Get lost in\nthe story.",
        "Every panel. Every detail. Right where you left off.", "Made for iPhone, iPad and Mac.",
        "THE READING EXPERIENCE", False,
    ),
    "03-search.png": Panel(
        "03-search.png", "Find that unforgettable line.", "Find that\nunforgettable\nline.",
        "Search the comic you’re reading. Save your favourite quotes.",
        "ComicReader Plus · One purchase. No subscription.", "COMICREADER PLUS", True,
    ),
    "04-lists.png": Panel(
        "04-lists.png", "Your next great read, lined up.", "Your next\ngreat read,\nlined up.",
        "Curate reading lists. Let Smart Queues keep you going.",
        "ComicReader Plus · One purchase. No subscription.", "COMICREADER PLUS", False,
    ),
    "05-icloud.png": Panel(
        "05-icloud.png", "Your stories go with you.", "Your stories\ngo with you.",
        "Free iCloud sync for comics, read status and your current page.",
        "iPhone, iPad and Mac · Uses your iCloud storage.", "FREE ICLOUD SYNC", True,
    ),
}


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
    draw: ImageDraw.ImageDraw, text: str, box: tuple[int, int, int, int],
    size: int, minimum: int, colour: str, *, weight: str = "regular",
    wrap: bool = True, spacing: int = 6,
) -> tuple[int, int, int, int]:
    """Fit text to an explicit reservation; fail rather than clip a caption."""
    for candidate in range(size, minimum - 1, -1):
        selected_font = font(candidate, weight)
        fitted = wrap_text(draw, text, selected_font, box[2] - box[0]) if wrap else text
        bounds = draw.multiline_textbbox((0, 0), fitted, font=selected_font, spacing=spacing)
        width, height = bounds[2] - bounds[0], bounds[3] - bounds[1]
        if width <= box[2] - box[0] and height <= box[3] - box[1]:
            draw.multiline_text(
                (box[0] - bounds[0], box[1] - bounds[1]), fitted,
                font=selected_font, fill=colour, spacing=spacing,
            )
            return (box[0], box[1], box[0] + width, box[1] + height)
    raise ValueError(f"Caption does not fit its reserved area: {text!r}")


def draw_tracked(draw: ImageDraw.ImageDraw, text: str, position: tuple[int, int],
                 size: int, colour: str, tracking: float) -> None:
    selected_font = font(size, "demi")
    x, y = position
    for char in text:
        draw.text((round(x), y), char, font=selected_font, fill=colour, anchor="lt")
        x += draw.textlength(char, font=selected_font) + tracking


def draw_brand(draw: ImageDraw.ImageDraw, panel: Panel, x: int, y: int, size: int) -> None:
    # The red rule is presentation decoration, not a recreated app icon.
    draw.rectangle((x, y, x + round(size * 0.14), y + size), fill=RED)
    draw_tracked(draw, "COMICREADER", (x + round(size * 0.64), y), size, panel.foreground, size * 0.14)


def add_capture(canvas: Image.Image, capture: Image.Image, area: tuple[int, int, int, int],
                *, panel: Panel, border: int) -> tuple[Image.Image, dict]:
    """Place every source pixel, at its original aspect, inside a fine frame."""
    screen = ImageOps.contain(capture, (area[2] - area[0] - border * 2, area[3] - area[1] - border * 2),
                             method=Image.Resampling.LANCZOS)
    frame_width, frame_height = screen.width + border * 2, screen.height + border * 2
    left = area[0] + (area[2] - area[0] - frame_width) // 2
    top = area[1] + (area[3] - area[1] - frame_height) // 2
    scale = canvas.width / 1206
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (left, top + round(15 * scale), left + frame_width, top + frame_height + round(15 * scale)),
        radius=max(4, border), fill=(0, 0, 0, 98 if panel.dark else 52),
    )
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(round(22 * scale))))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        (left, top, left + frame_width - 1, top + frame_height - 1), radius=max(5, border),
        fill="#272C32" if panel.dark else "#E0DCD4", outline="#555A5E" if panel.dark else "#C9C5BD",
        width=max(1, round(scale)),
    )
    # No rounded mask: even the source screen's outermost pixels remain visible.
    screen_left, screen_top = left + border, top + border
    canvas.paste(screen, (screen_left, screen_top))
    return canvas.convert("RGB"), {
        "source_size": list(capture.size), "rendered_size": list(screen.size),
        "capture_bounds": [screen_left, screen_top, screen_left + screen.width, screen_top + screen.height],
        "cropped": False,
    }


def compose_portrait(capture: Image.Image, panel: Panel, number: int, platform: str) -> tuple[Image.Image, dict]:
    size = PLATFORM_SIZES[platform]
    canvas = Image.new("RGB", size, panel.background)
    draw = ImageDraw.Draw(canvas)
    if platform == "iphone":
        margin, brand_y, brand_size = 62, 60, 25
        title_box, title_size = (62, 118, 1144, 208), 76
        subtitle_box, subtitle_size = (65, 224, 1135, 306), 35
        image_area, border = (48, 340, 1158, 2516), 7
        footer_box, footer_size = (62, 2560, 1144, 2594), 25
    else:
        margin, brand_y, brand_size = 96, 72, 35
        title_box, title_size = (96, 155, 1968, 293), 122
        subtitle_box, subtitle_size = (101, 318, 1958, 431), 49
        image_area, border = (75, 475, 1989, 2605), 10
        footer_box, footer_size = (96, 2670, 1968, 2713), 35
    draw_brand(draw, panel, margin, brand_y, brand_size)
    category_width = draw.textlength(panel.category, font=font(brand_size - 2, "demi"))
    draw.text((size[0] - margin - category_width, brand_y + 1), panel.category,
              font=font(brand_size - 2, "demi"), fill=panel.secondary, anchor="lt")
    draw_text(draw, panel.title, title_box, title_size, round(title_size * 0.7), panel.foreground, weight="demi", wrap=False)
    draw_text(draw, panel.subtitle, subtitle_box, subtitle_size, subtitle_size - 3, panel.secondary, spacing=8)
    canvas, placement = add_capture(canvas, capture, image_area, panel=panel, border=border)
    draw = ImageDraw.Draw(canvas)
    draw.line((margin, footer_box[1] - 19, size[0] - margin, footer_box[1] - 19), fill=panel.rule, width=1)
    draw_text(draw, panel.footnote, footer_box, footer_size, footer_size - 2, panel.secondary, wrap=False)
    placement["layout"] = "portrait"
    return canvas, placement


def compose_macos(capture: Image.Image, panel: Panel, number: int) -> tuple[Image.Image, dict]:
    canvas = Image.new("RGB", MACOS_SIZE, panel.background)
    draw = ImageDraw.Draw(canvas)
    draw_brand(draw, panel, 105, 91, 37)
    # A compact caption column gives normal Mac windows much more screen area
    # than a tall title block. Very wide captures use a shallow header instead.
    if capture.width / capture.height < 1.60:
        draw_tracked(draw, panel.category, (108, 282), 28, panel.secondary, 1.7)
        draw_text(draw, panel.mac_title, (105, 379, 710, 821), 100, 78, panel.foreground, weight="demi", wrap=False, spacing=4)
        draw_text(draw, panel.subtitle, (110, 942, 665, 1195), 46, 42, panel.secondary, spacing=14)
        draw.line((110, 1390, 625, 1390), fill=panel.rule, width=2)
        draw_text(draw, panel.footnote, (110, 1435, 645, 1595), 34, 30, panel.secondary, spacing=11)
        area = (770, 140, 2790, 1660)
        layout = "mac-side-caption"
    else:
        draw_text(draw, panel.title, (105, 170, 2775, 279), 108, 89, panel.foreground, weight="demi", wrap=False)
        draw_text(draw, panel.subtitle, (110, 303, 2770, 370), 45, 41, panel.secondary, wrap=False)
        draw.text((2250, 94), panel.category, font=font(29, "demi"), fill=panel.secondary, anchor="lt")
        area = (86, 412, 2794, 1681)
        draw_text(draw, panel.footnote, (108, 1730, 2772, 1775), 31, 28, panel.secondary, wrap=False)
        layout = "mac-wide-caption"
    canvas, placement = add_capture(canvas, capture, area, panel=panel, border=10)
    placement["layout"] = layout
    return canvas, placement


def compose(platform: str, capture: Image.Image, panel: Panel, number: int) -> tuple[Image.Image, dict]:
    return compose_macos(capture, panel, number) if platform == "macos" else compose_portrait(capture, panel, number, platform)


def select_panels(platform_dir: Path) -> list[Panel]:
    missing = [name for name in PANELS if not (platform_dir / name).is_file()]
    if missing:
        raise ValueError(f"{platform_dir}: missing real app captures: {', '.join(missing)}")
    return list(PANELS.values())


def load_capture(path: Path, platform: str) -> Image.Image:
    try:
        with Image.open(path) as opened:
            if opened.format != "PNG":
                raise ValueError(f"{path}: expected PNG, found {opened.format}")
            if getattr(opened, "n_frames", 1) != 1:
                raise ValueError(f"{path}: animated images are not supported")
            rgba = ImageOps.exif_transpose(opened).convert("RGBA")
            image = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
            image.alpha_composite(rgba)
            image = image.convert("RGB")
            image.load()
    except OSError as exc:
        raise ValueError(f"{path}: cannot read image: {exc}") from exc
    width, height = image.size
    ratio = width / height
    if platform == "iphone":
        valid = width >= 750 and height >= 1600 and 0.40 <= ratio <= 0.55
    elif platform == "ipad":
        valid = width >= 1536 and height >= 2048 and 0.68 <= ratio <= 0.80
    else:
        valid = width >= 800 and height >= 700 and 0.75 <= ratio <= 2.50
    if not valid:
        raise ValueError(f"{path}: unexpected full-resolution {platform} capture size {width} x {height}")
    return image


def verify_output(path: Path, expected_size: tuple[int, int]) -> None:
    with Image.open(path) as image:
        image.load()
        if image.format != "PNG" or image.mode != "RGB" or image.size != expected_size:
            raise RuntimeError(f"Invalid output {path}: {image.format}, {image.mode}, {image.size}; expected PNG, RGB, {expected_size}")


def platform_jobs(captures: Path, selected_platform: str) -> Iterable[tuple[str, tuple[int, int], list[Panel]]]:
    for platform, size in PLATFORM_SIZES.items():
        if selected_platform in ("all", platform):
            yield platform, size, select_panels(captures / platform)


def main() -> None:
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--captures", type=Path, required=True, help="capture-tree root")
    parser.add_argument("--output", type=Path, required=True, help="output-tree root")
    parser.add_argument("--platform", choices=("all", *PLATFORM_SIZES), default="all")
    args = parser.parse_args()
    capture_root, output_root = args.captures.resolve(), args.output.resolve()
    if capture_root == output_root or capture_root in output_root.parents or output_root in capture_root.parents:
        parser.error("capture and output trees must be separate, non-nested directories")
    try:
        jobs = list(platform_jobs(args.captures, args.platform))
        loaded = {(platform, panel.filename): load_capture(args.captures / platform / panel.filename, platform)
                  for platform, _size, panels in jobs for panel in panels}
        rendered = []
        for platform, size, panels in jobs:
            for number, panel in enumerate(panels, 1):
                result, placement = compose(platform, loaded[(platform, panel.filename)], panel, number)
                if result.size != size or result.mode != "RGB":
                    raise RuntimeError(f"Invalid composed image for {platform}/{panel.filename}")
                rendered.append((platform, panel.filename, size, result, placement))
    except ValueError as exc:
        parser.error(str(exc))
    manifest = []
    for platform, filename, size, result, placement in rendered:
        destination = args.output / platform / filename
        destination.parent.mkdir(parents=True, exist_ok=True)
        result.save(destination, format="PNG", optimize=True)
        verify_output(destination, size)
        source = args.captures / platform / filename
        manifest.append({"platform": platform, "filename": filename, "size": list(size),
                         "source": str(source), "source_sha256": sha256(source.read_bytes()).hexdigest(),
                         "output_sha256": sha256(destination.read_bytes()).hexdigest(), **placement})
    (args.output / f"composition-{args.platform}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for platform, size, _panels in jobs:
        print(f"Wrote 5 {PLATFORM_NAMES[platform]} screenshots at {size[0]} x {size[1]}")
    print(f"Output: {args.output}")


if __name__ == "__main__":
    main()
