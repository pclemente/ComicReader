#!/usr/bin/env python3
"""Compose the ComicReader 1.4 iPhone and macOS App Store screenshots.

The compositor requires real, full-screen PNG captures and always preserves the
entire capture at its original aspect ratio. It does not crop, stretch, or
replace application UI.

Expected capture tree (choose exactly one third image per platform):

    captures/
      iphone/01-library.png
      iphone/02-reader.png
      iphone/03-icloud.png  # or 03-plus.png
      macos/01-library.png
      macos/02-reader.png
      macos/03-icloud.png   # or 03-plus.png

Example:

    python3 release/app-store/1.4/compose_screenshots.py \
      --captures release/app-store/1.4/captures \
      --output release/app-store/1.4/screenshots/en-GB

Requires Pillow. Outputs are opaque RGB PNGs at exactly 1206 x 2622 for iPhone
and 1440 x 900 for macOS.
"""

from argparse import ArgumentParser
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


PAPER = "#fff6df"
INK = "#182b35"
RED = "#d83d28"
GOLD = "#e7b94d"
FONT_PATH = Path("/System/Library/Fonts/Avenir Next.ttc")

IPHONE_SIZE = (1206, 2622)
MACOS_SIZE = (1440, 900)
SAMPLE_NOTE = "Sample comics shown. Bring your own PDF, CBZ and CBR files."


@dataclass(frozen=True)
class Panel:
    filename: str
    label: str
    title: str
    subtitle: str
    footnote: str
    background: str
    foreground: str
    accent: str


PANELS = {
    "01-library.png": Panel(
        "01-library.png",
        "COMICREADER",
        "Your comics.\nYour library.",
        "Browse and organise your own collection.",
        SAMPLE_NOTE,
        PAPER,
        INK,
        RED,
    ),
    "02-reader.png": Panel(
        "02-reader.png",
        "COMICREADER",
        "Every panel.\nEvery detail.",
        "Read full screen and pick up where you left off.",
        SAMPLE_NOTE,
        RED,
        PAPER,
        GOLD,
    ),
    "03-icloud.png": Panel(
        "03-icloud.png",
        "FREE ICLOUD SYNC",
        "Free iCloud\nsync.",
        "Comic files, read status and current page sync for free.",
        "Free for everyone. Opt in with your personal iCloud storage.",
        INK,
        PAPER,
        GOLD,
    ),
    "03-plus.png": Panel(
        "03-plus.png",
        "COMICREADER PLUS",
        "Find it.\nSave it.",
        "Search, quotes, lists, bookmarks and filters.",
        (
            "One purchase. No subscription. Indexes, quotes, lists and bookmarks "
            "stay on this device."
        ),
        GOLD,
        INK,
        RED,
    ),
}


def font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    if not FONT_PATH.is_file():
        raise RuntimeError(f"Required font is missing: {FONT_PATH}")
    return ImageFont.truetype(str(FONT_PATH), size, index=0 if bold else 5)


def wrap_text(draw: ImageDraw.ImageDraw, text: str, selected_font, width: int) -> str:
    lines = []
    for paragraph in text.splitlines() or [""]:
        words = paragraph.split()
        current = ""
        for word in words:
            candidate = word if not current else f"{current} {word}"
            if not current or draw.textlength(candidate, font=selected_font) <= width:
                current = candidate
            else:
                lines.append(current)
                current = word
        lines.append(current)
    return "\n".join(lines)


def fit_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    box: tuple[int, int, int, int],
    start_size: int,
    min_size: int,
    *,
    bold: bool,
    spacing: int,
    wrap: bool,
) -> tuple[str, ImageFont.FreeTypeFont, tuple[int, int]]:
    max_width = box[2] - box[0]
    max_height = box[3] - box[1]
    for size in range(start_size, min_size - 1, -2):
        selected_font = font(size, bold)
        fitted = wrap_text(draw, text, selected_font, max_width) if wrap else text
        bounds = draw.multiline_textbbox((0, 0), fitted, font=selected_font, spacing=spacing)
        if bounds[2] - bounds[0] <= max_width and bounds[3] - bounds[1] <= max_height:
            return fitted, selected_font, (-bounds[0], -bounds[1])
    raise ValueError(f"Caption does not fit its reserved area: {text!r}")


def draw_fitted_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    box: tuple[int, int, int, int],
    start_size: int,
    min_size: int,
    colour: str,
    *,
    bold: bool = True,
    spacing: int = 4,
    wrap: bool = True,
) -> None:
    fitted, selected_font, offset = fit_text(
        draw,
        text,
        box,
        start_size,
        min_size,
        bold=bold,
        spacing=spacing,
        wrap=wrap,
    )
    draw.multiline_text(
        (box[0] + offset[0], box[1] + offset[1]),
        fitted,
        font=selected_font,
        fill=colour,
        spacing=spacing,
    )


def draw_label(
    draw: ImageDraw.ImageDraw,
    text: str,
    xy: tuple[int, int],
    accent: str,
    max_width: int,
    font_size: int,
) -> None:
    selected_font = font(font_size)
    text_width = int(draw.textlength(text, font=selected_font))
    horizontal_padding = font_size
    width = text_width + 2 * horizontal_padding
    height = int(font_size * 1.8)
    if width > max_width:
        raise ValueError(f"Label does not fit its reserved area: {text!r}")
    x, y = xy
    draw.rounded_rectangle((x, y, x + width, y + height), radius=height // 2, fill=accent)
    label_colour = INK if accent == GOLD else PAPER
    draw.text(
        (x + horizontal_padding, y + font_size // 4),
        text,
        font=selected_font,
        fill=label_colour,
    )


def add_pattern(canvas: Image.Image, panel: Panel, platform: str) -> None:
    draw = ImageDraw.Draw(canvas)
    muted = {
        PAPER: "#efdfbc",
        RED: "#c73324",
        GOLD: "#d6a83d",
        INK: "#233e49",
    }[panel.background]
    if platform == "iphone":
        for y in range(1220, canvas.height, 38):
            for x in range(-10, canvas.width + 10, 38):
                if x < 150 or x > canvas.width - 150:
                    draw.ellipse((x - 4, y - 4, x + 4, y + 4), fill=muted)
    else:
        for y in range(-10, canvas.height + 10, 32):
            for x in range(1060, canvas.width + 10, 32):
                draw.ellipse((x - 3, y - 3, x + 3, y + 3), fill=muted)


def add_capture(
    canvas: Image.Image,
    capture: Image.Image,
    area: tuple[int, int, int, int],
    bezel: int,
) -> Image.Image:
    area_width = area[2] - area[0]
    area_height = area[3] - area[1]
    screen = ImageOps.contain(
        capture,
        (area_width - 2 * bezel, area_height - 2 * bezel),
        method=Image.Resampling.LANCZOS,
    )
    frame_width = screen.width + 2 * bezel
    frame_height = screen.height + 2 * bezel
    left = area[0] + (area_width - frame_width) // 2
    top = area[1] + (area_height - frame_height) // 2

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (left - 8, top + 16, left + frame_width + 8, top + frame_height + 28),
        radius=max(20, bezel * 2),
        fill=(0, 0, 0, 72),
    )
    canvas = Image.alpha_composite(
        canvas.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(max(16, bezel)))
    )
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        (left, top, left + frame_width, top + frame_height),
        radius=max(18, bezel * 2),
        fill="#151719",
        outline="#5e6264",
        width=3,
    )
    # Paste the complete rectangular capture. Keeping every source pixel visible
    # is more important than simulating rounded screen corners or a device notch.
    screen_left = left + bezel
    screen_top = top + bezel
    canvas.paste(screen, (screen_left, screen_top))
    draw.rectangle(
        (screen_left, screen_top, screen_left + screen.width, screen_top + screen.height),
        outline="#34383a",
        width=2,
    )
    return canvas


def compose_iphone(capture: Image.Image, panel: Panel, number: int) -> Image.Image:
    canvas = Image.new("RGB", IPHONE_SIZE, panel.background)
    add_pattern(canvas, panel, "iphone")
    canvas = add_capture(canvas, capture, (70, 590, 1136, 2488), bezel=22)
    draw = ImageDraw.Draw(canvas)
    draw_label(draw, panel.label, (72, 72), panel.accent, 650, 27)
    draw.text((1072, 84), f"0{number}", font=font(31), fill=panel.foreground)
    draw_fitted_text(
        draw,
        panel.title,
        (72, 178, 1134, 410),
        104,
        62,
        panel.foreground,
        wrap=False,
        spacing=1,
    )
    draw_fitted_text(
        draw,
        panel.subtitle,
        (76, 430, 1130, 555),
        39,
        26,
        panel.foreground,
        bold=False,
        spacing=5,
    )
    draw_fitted_text(
        draw,
        panel.footnote,
        (78, 2510, 1128, 2595),
        27,
        19,
        panel.foreground,
        bold=False,
        spacing=3,
    )
    return canvas.convert("RGB")


def compose_macos(capture: Image.Image, panel: Panel, number: int) -> Image.Image:
    canvas = Image.new("RGB", MACOS_SIZE, panel.background)
    add_pattern(canvas, panel, "macos")
    canvas = add_capture(canvas, capture, (392, 82, 1388, 818), bezel=16)
    draw = ImageDraw.Draw(canvas)
    draw_label(draw, panel.label, (58, 52), panel.accent, 305, 18)
    draw.text((60, 117), f"0{number}", font=font(24), fill=panel.foreground)
    draw_fitted_text(
        draw,
        panel.title,
        (58, 155, 355, 335),
        64,
        42,
        panel.foreground,
        wrap=False,
        spacing=0,
    )
    draw_fitted_text(
        draw,
        panel.subtitle,
        (60, 365, 350, 510),
        30,
        20,
        panel.foreground,
        bold=False,
        spacing=4,
    )
    draw_fitted_text(
        draw,
        panel.footnote,
        (60, 585, 350, 790),
        23,
        17,
        panel.foreground,
        bold=False,
        spacing=4,
    )
    return canvas.convert("RGB")


def select_panels(platform_dir: Path) -> list[Panel]:
    required = [platform_dir / "01-library.png", platform_dir / "02-reader.png"]
    missing = [path.name for path in required if not path.is_file()]
    if missing:
        raise ValueError(f"{platform_dir}: missing real app captures: {', '.join(missing)}")

    third = [
        name
        for name in ("03-icloud.png", "03-plus.png")
        if (platform_dir / name).is_file()
    ]
    if len(third) != 1:
        raise ValueError(
            f"{platform_dir}: provide exactly one of 03-icloud.png or 03-plus.png"
        )
    return [PANELS["01-library.png"], PANELS["02-reader.png"], PANELS[third[0]]]


def load_capture(path: Path, platform: str) -> Image.Image:
    try:
        with Image.open(path) as opened:
            if opened.format != "PNG":
                raise ValueError(f"{path}: expected a PNG capture, found {opened.format}")
            if getattr(opened, "n_frames", 1) != 1:
                raise ValueError(f"{path}: animated or multi-frame images are not supported")
            image = ImageOps.exif_transpose(opened).convert("RGB")
            image.load()
    except OSError as exc:
        raise ValueError(f"{path}: cannot read image: {exc}") from exc

    width, height = image.size
    if platform == "iphone":
        if height <= width or width < 750 or height < 1600:
            raise ValueError(
                f"{path}: expected a full-resolution portrait iPhone capture; "
                f"got {width} x {height}"
            )
        ratio = width / height
        if not 0.40 <= ratio <= 0.55:
            raise ValueError(f"{path}: unexpected iPhone aspect ratio ({width} x {height})")
    else:
        if width < 800 or height < 700:
            raise ValueError(
                f"{path}: expected a full-resolution Mac window or sheet capture; "
                f"got {width} x {height}"
            )
        ratio = width / height
        if not 0.75 <= ratio <= 2.20:
            raise ValueError(f"{path}: unexpected Mac aspect ratio ({width} x {height})")
    return image


def verify_output(path: Path, expected_size: tuple[int, int]) -> None:
    with Image.open(path) as image:
        image.load()
        if image.format != "PNG" or image.mode != "RGB" or image.size != expected_size:
            raise RuntimeError(
                f"Invalid output {path}: {image.format}, {image.mode}, {image.size}; "
                f"expected PNG, RGB, {expected_size}"
            )


def platform_jobs(
    captures: Path, selected_platform: str
) -> Iterable[tuple[str, tuple[int, int], list[Panel]]]:
    platforms = (("iphone", IPHONE_SIZE), ("macos", MACOS_SIZE))
    for platform, size in platforms:
        if selected_platform not in ("all", platform):
            continue
        yield platform, size, select_panels(captures / platform)


def main() -> None:
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--captures", type=Path, required=True, help="capture-tree root")
    parser.add_argument("--output", type=Path, required=True, help="output-tree root")
    parser.add_argument(
        "--platform",
        choices=("all", "iphone", "macos"),
        default="all",
        help="compose both platforms or only the selected platform (default: all)",
    )
    args = parser.parse_args()

    if args.captures.resolve() == args.output.resolve():
        parser.error("--output must not overwrite the source capture tree")

    try:
        jobs = list(platform_jobs(args.captures, args.platform))
        loaded = {
            (platform, panel.filename): load_capture(
                args.captures / platform / panel.filename, platform
            )
            for platform, _size, panels in jobs
            for panel in panels
        }
    except ValueError as exc:
        parser.error(str(exc))

    rendered = []
    for platform, size, panels in jobs:
        for number, panel in enumerate(panels, start=1):
            capture = loaded[(platform, panel.filename)]
            image = (
                compose_iphone(capture, panel, number)
                if platform == "iphone"
                else compose_macos(capture, panel, number)
            )
            if image.size != size or image.mode != "RGB":
                raise RuntimeError(f"Internal output error for {platform}/{panel.filename}")
            rendered.append((platform, panel.filename, size, image))

    for platform, filename, _size, image in rendered:
        destination = args.output / platform / filename
        destination.parent.mkdir(parents=True, exist_ok=True)
        image.save(destination, format="PNG", optimize=True)

    for platform, filename, size, _image in rendered:
        verify_output(args.output / platform / filename, size)

    for platform, size, _panels in jobs:
        display_name = "iPhone" if platform == "iphone" else "macOS"
        print(f"Wrote 3 {display_name} screenshots at {size[0]} x {size[1]}")
    print(f"Output: {args.output}")


if __name__ == "__main__":
    main()
