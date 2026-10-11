#!/usr/bin/env python3
"""Compose App Store images from unmodified, real iPad app captures.

Usage: python3 compose_screenshots.py --captures ./captures --output ./screenshots/en-GB
Requires Pillow. It never substitutes artwork for missing application captures.
"""
from argparse import ArgumentParser
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

WIDTH, HEIGHT = 2064, 2752  # Apple's accepted 13-inch iPad portrait dimensions.
FONT = "/System/Library/Fonts/Avenir Next.ttc"
INK, PAPER, RED, GOLD = "#182b35", "#fff6df", "#d83d28", "#e7b94d"
PANELS = [
    ("01-library.png", "Big stories.\nYour library.", "Bring your favourite comics together.", PAPER, INK),
    ("02-reader.png", "Let the story\nfill your screen.", "Full-screen reading. A closer look at every panel.", RED, PAPER),
    ("03-progress.png", "Pick up where\nyou left off.", "Keep your place. Keep the story moving.", PAPER, INK),
    ("04-files.png", "Your next read,\none tap away.", "Import your comics directly from Files.", GOLD, INK),
    ("05-transfers.png", "Your collection.\nMore ways to add it.", "Wi-Fi uploads and WebDAV. Free and unlimited.", INK, PAPER),
]


def font(size, bold=True):
    return ImageFont.truetype(FONT, size, index=0 if bold else 5)


def fit_font(draw, lines, limit, size=126):
    while size > 50:
        selected = font(size)
        if max(draw.textlength(line, font=selected) for line in lines) <= limit:
            return selected
        size -= 2
    return font(size)


def compose(source, target, title, subtitle, background, foreground, number):
    capture = Image.open(source).convert("RGB")
    if capture.width >= capture.height or capture.width < 1400:
        raise ValueError(f"Expected a full-resolution portrait iPad capture: {source}")
    canvas = Image.new("RGB", (WIDTH, HEIGHT), background)
    draw = ImageDraw.Draw(canvas)
    accent = RED if background == PAPER else GOLD if background == INK else INK
    dot_colour = "#efdfbc" if background == PAPER else "#c73324" if background == RED else "#d6a83d" if background == GOLD else "#233e49"
    for y in range(1500, HEIGHT, 34):
        for x in range(-20, WIDTH + 20, 34):
            if x < 280 or x > WIDTH - 280:
                radius = 3 + min(4, max(0, y - 1500) // 220)
                draw.ellipse((x-radius, y-radius, x+radius, y+radius), fill=dot_colour)

    draw.rounded_rectangle((124, 98, 472, 161), radius=30, fill=accent)
    draw.text((151, 109), "COMICREADER", font=font(33), fill=PAPER)
    draw.text((WIDTH-172, 108), f"0{number}", font=font(34), fill=foreground)
    selected = fit_font(draw, title.splitlines(), WIDTH-248)
    draw.multiline_text((124, 203), title, font=selected, fill=foreground, spacing=3, stroke_width=0)
    text_bottom = draw.multiline_textbbox((124, 203), title, font=selected, spacing=3)[3]
    subfont = fit_font(draw, [subtitle], WIDTH-248, size=43)
    draw.text((128, text_bottom+32), subtitle, font=subfont, fill=foreground)

    # Preserve the capture's aspect ratio and all its UI; only the exterior frame is added.
    screen = ImageOps.contain(capture, (1710, 1964), method=Image.Resampling.LANCZOS)
    bezel = 30
    frame_width, frame_height = screen.width+2*bezel, screen.height+2*bezel
    left, top = (WIDTH-frame_width)//2, 625
    shadow = Image.new("RGBA", canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((left-8, top+28, left+frame_width+8, top+frame_height+42), radius=72, fill=(0, 0, 0, 68))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(28)))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((left, top, left+frame_width, top+frame_height), radius=62, fill="#151719", outline="#5e6264", width=4)
    mask = Image.new("L", screen.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen.width, screen.height), radius=32, fill=255)
    canvas.paste(screen, (left+bezel, top+bezel), mask)
    draw = ImageDraw.Draw(canvas)
    footer = "Sample comics shown. Bring your own PDF, CBZ and CBR files."
    footer_font = font(29, False)
    draw.text(((WIDTH-draw.textlength(footer, font=footer_font))/2, HEIGHT-75), footer, font=footer_font, fill=foreground)
    canvas.convert("RGB").save(target, optimize=True)


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--captures", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    missing = [name for name, *_ in PANELS if not (args.captures/name).is_file()]
    if missing:
        parser.error("Missing real app captures: " + ", ".join(missing))
    args.output.mkdir(parents=True, exist_ok=True)
    for index, (name, title, subtitle, background, foreground) in enumerate(PANELS, start=1):
        compose(args.captures/name, args.output/name, title, subtitle, background, foreground, index)
    previews = [ImageOps.contain(Image.open(args.output/name), (413, 551)) for name, *_ in PANELS]
    sheet = Image.new("RGB", (413*len(previews), 551), PAPER)
    for index, preview in enumerate(previews):
        sheet.paste(preview, (index*413, 0))
    sheet.save(args.output/"contact-sheet.jpg", quality=92)
    print(f"Wrote {len(PANELS)} screenshots at {WIDTH} × {HEIGHT} to {args.output}")


if __name__ == "__main__":
    main()
