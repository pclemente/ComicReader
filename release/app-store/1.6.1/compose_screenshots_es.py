#!/usr/bin/env python3
"""Compose and verify the Spanish App Store screenshot galleries.

This wrapper deliberately delegates all gallery rendering to the established
1.4.1 and 1.5 compositors. It changes presentation copy only: the genuine app
captures are loaded, oriented, fitted, and rendered by those existing modules.
"""

from __future__ import annotations

from argparse import ArgumentParser
from hashlib import sha256
import importlib.util
import json
from pathlib import Path
import sys
from types import ModuleType
from typing import Any

from PIL import Image, ImageDraw, ImageFont, ImageOps


SCRIPT_DIR = Path(__file__).resolve().parent
APP_STORE_DIR = SCRIPT_DIR.parent
REPOSITORY_ROOT = APP_STORE_DIR.parent.parent
BASE_COMPOSITOR_PATH = APP_STORE_DIR / "1.4.1" / "compose_screenshots.py"
DUO_COMPOSITOR_PATH = APP_STORE_DIR / "1.5" / "compose_duo_screenshots.py"
BASE_CAPTURE_ROOT = APP_STORE_DIR / "1.4.1" / "captures"
DUO_CAPTURE_ROOT = APP_STORE_DIR / "1.5" / "captures" / "duo"
DEFAULT_OUTPUT_ROOT = SCRIPT_DIR / "screenshots" / "es-ES"
EXPECTED_ORDER = (
    "01-library.png",
    "02-reader.png",
    "03-search.png",
    "04-lists.png",
    "05-icloud.png",
)
PLATFORM_LABELS = {
    "iphone": "iPhone",
    "ipad": "iPad",
    "macos": "macOS",
    "duo": "iPhone Duo",
}


def load_module(name: str, path: Path) -> ModuleType:
    """Load a compositor from its versioned directory without copying it."""
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import compositor: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def sha256_file(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def relative(path: Path) -> str:
    return path.resolve().relative_to(REPOSITORY_ROOT).as_posix()


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def spanish_base_panels(base: ModuleType) -> dict[str, Any]:
    panel = base.Panel
    return {
        "01-library.png": panel(
            "01-library.png",
            "Un lugar para cada cómic.",
            "Un lugar para\ncada cómic.",
            "Tus PDF, CBZ y CBR, juntos.",
            "Tus archivos. Tu colección. · Interfaz en inglés.",
            "TU BIBLIOTECA",
            True,
        ),
        "02-reader.png": panel(
            "02-reader.png",
            "Sumérgete en la historia.",
            "Sumérgete en\nla historia.",
            "Cada viñeta, cada detalle, justo donde lo dejaste.",
            "Interfaz en inglés.",
            "LA EXPERIENCIA DE LECTURA",
            False,
        ),
        "03-search.png": panel(
            "03-search.png",
            "Encuentra esa frase.",
            "Encuentra\nesa frase.",
            "Busca en el cómic que lees y guarda tus citas favoritas.",
            "ComicReader Plus · Una compra. Sin suscripción.",
            "COMICREADER PLUS",
            True,
        ),
        "04-lists.png": panel(
            "04-lists.png",
            "Tu próxima lectura, en orden.",
            "Tu próxima\nlectura,\nen orden.",
            "Crea listas. Las colas inteligentes te ayudan a seguir.",
            "ComicReader Plus · Una compra. Sin suscripción.",
            "COMICREADER PLUS",
            False,
        ),
        "05-icloud.png": panel(
            "05-icloud.png",
            "Tus historias van contigo.",
            "Tus historias\nvan contigo.",
            "Sincroniza cómics, progreso y página actual con iCloud.",
            "Gratis y opcional · Usa tu almacenamiento de iCloud.",
            "ICLOUD GRATIS Y OPCIONAL",
            True,
        ),
    }


def spanish_duo_panels(duo: ModuleType) -> tuple[Any, ...]:
    panel = duo.Panel
    return (
        panel(
            "01-library.png",
            "IPHONE DUO · TU BIBLIOTECA",
            "Un lugar para cada cómic.",
            "Las portadas se adaptan al pliegue activo sin perder tu sitio.",
            "Interfaz en inglés.",
            True,
        ),
        panel(
            "02-reader.png",
            "IPHONE DUO · EL LECTOR",
            "Sumérgete en la historia.",
            "El cómic, la página y el zoom se conservan al cambiar la pantalla.",
            "Interfaz en inglés.",
            False,
        ),
        panel(
            "03-search.png",
            "PLUS · BÚSQUEDA Y CITAS",
            "Encuentra esa frase.",
            "Busca en el cómic que lees y guarda citas editables.",
            "ComicReader Plus · Una compra. Sin suscripción.",
            True,
        ),
        panel(
            "04-lists.png",
            "PLUS · LISTAS DE LECTURA",
            "Tu próxima lectura, en orden.",
            "Crea listas y deja que las colas inteligentes reúnan lo siguiente.",
            "ComicReader Plus · Una compra. Sin suscripción.",
            False,
        ),
        panel(
            "05-icloud.png",
            "ICLOUD GRATIS Y OPCIONAL",
            "Tus historias van contigo.",
            "Sincroniza cómics, progreso y página actual entre tus dispositivos.",
            "Gratis para todos · Opcional con tu almacenamiento de iCloud.",
            True,
        ),
    )


def image_metadata(path: Path, *, transpose: bool) -> dict[str, Any]:
    with Image.open(path) as opened:
        opened.load()
        orientation = opened.getexif().get(274, 1)
        normalized_size = ImageOps.exif_transpose(opened).size if transpose else opened.size
        return {
            "path": relative(path),
            "sha256": sha256_file(path),
            "format": opened.format,
            "mode": opened.mode,
            "stored_size": list(opened.size),
            "exif_orientation": orientation,
            "normalized_size": list(normalized_size),
        }


def panel_copy(panel: Any, *, mac_title: str | None = None) -> dict[str, str]:
    payload = {
        "category": panel.category,
        "title": panel.title,
        "subtitle": panel.subtitle,
        "footnote": panel.footnote,
    }
    if mac_title is not None:
        payload["mac_title"] = mac_title
    return payload


def save_png_atomic(image: Image.Image, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.tmp")
    image.save(temporary, format="PNG", optimize=True)
    temporary.replace(destination)


def compose_base_galleries(base: ModuleType, output_root: Path) -> dict[str, list[dict[str, Any]]]:
    records: dict[str, list[dict[str, Any]]] = {}
    for platform in ("iphone", "ipad", "macos"):
        platform_records: list[dict[str, Any]] = []
        expected_size = base.PLATFORM_SIZES[platform]
        for number, filename in enumerate(EXPECTED_ORDER, 1):
            panel = base.PANELS[filename]
            source = BASE_CAPTURE_ROOT / platform / filename
            capture = base.load_capture(source, platform)
            result, placement = base.compose(platform, capture, panel, number)
            destination = output_root / platform / filename
            save_png_atomic(result, destination)
            base.verify_output(destination, expected_size)
            platform_records.append(
                {
                    "order": number,
                    "platform": platform,
                    "filename": filename,
                    "size": list(expected_size),
                    **panel_copy(panel, mac_title=panel.mac_title),
                    "source": image_metadata(source, transpose=True),
                    "output": {
                        "path": relative(destination),
                        "sha256": sha256_file(destination),
                        "format": "PNG",
                        "mode": "RGB",
                        "size": list(result.size),
                    },
                    **placement,
                }
            )
        manifest_path = output_root / f"composition-{platform}.json"
        write_json(manifest_path, platform_records)
        records[platform] = platform_records
    return records


def compose_duo_gallery(duo: ModuleType, output_root: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for number, panel in enumerate(duo.PANELS, 1):
        source = DUO_CAPTURE_ROOT / panel.filename
        capture = duo.load_capture(source)
        result, placement = duo.compose(capture, panel, number)
        destination = output_root / "duo" / panel.filename
        save_png_atomic(result, destination)
        duo.verify_output(destination)
        records.append(
            {
                "order": number,
                "platform": "duo",
                "filename": panel.filename,
                "size": list(duo.OUTPUT_SIZE),
                **panel_copy(panel),
                "source": image_metadata(source, transpose=True),
                "output": {
                    "path": relative(destination),
                    "sha256": sha256_file(destination),
                    "format": "PNG",
                    "mode": "RGB",
                    "size": list(result.size),
                },
                **placement,
            }
        )
    write_json(output_root / "duo" / "composition-duo.json", records)
    return records


def contact_sheet_font(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(
        "/System/Library/Fonts/Avenir Next.ttc", size, index=2
    )


def create_contact_sheet(platform: str, output_root: Path) -> dict[str, Any]:
    portrait = platform in {"iphone", "ipad"}
    columns = 3 if portrait else 2
    cell_width = 600 if portrait else 900
    label_height = 64
    gap = 28
    margin = 36
    images: list[tuple[str, Image.Image]] = []
    for filename in EXPECTED_ORDER:
        path = output_root / platform / filename
        with Image.open(path) as opened:
            opened.load()
            scale = cell_width / opened.width
            thumb = opened.resize(
                (cell_width, round(opened.height * scale)), Image.Resampling.LANCZOS
            ).convert("RGB")
            images.append((filename, thumb))

    cell_height = max(image.height for _filename, image in images) + label_height
    rows = (len(images) + columns - 1) // columns
    width = margin * 2 + columns * cell_width + (columns - 1) * gap
    height = margin * 2 + rows * cell_height + (rows - 1) * gap
    sheet = Image.new("RGB", (width, height), "#C9C9C7")
    draw = ImageDraw.Draw(sheet)
    label_font = contact_sheet_font(30)
    for index, (filename, image) in enumerate(images):
        column = index % columns
        row = index // columns
        left = margin + column * (cell_width + gap)
        top = margin + row * (cell_height + gap)
        label = f"{index + 1:02d} · {filename.removesuffix('.png')}"
        bounds = draw.textbbox((0, 0), label, font=label_font)
        draw.text(
            (left + (cell_width - (bounds[2] - bounds[0])) // 2, top - bounds[1]),
            label,
            font=label_font,
            fill="#171B20",
        )
        image_top = top + label_height
        sheet.paste(image, (left, image_top))

    destination = output_root / "contact-sheets" / f"{platform}-contact-sheet.png"
    save_png_atomic(sheet, destination)
    return {
        "path": relative(destination),
        "sha256": sha256_file(destination),
        "format": "PNG",
        "mode": "RGB",
        "size": list(sheet.size),
        "gallery_images_scaled_for_qa_only": True,
    }


def aspect_error(record: dict[str, Any]) -> float:
    source_width, source_height = record["source"]["normalized_size"]
    rendered_width, rendered_height = record["rendered_size"]
    return abs(rendered_width / rendered_height - source_width / source_height)


def capture_bounds_are_valid(record: dict[str, Any]) -> bool:
    left, top, right, bottom = record["capture_bounds"]
    output_width, output_height = record["output"]["size"]
    rendered_width, rendered_height = record["rendered_size"]
    return (
        0 <= left < right <= output_width
        and 0 <= top < bottom <= output_height
        and right - left == rendered_width
        and bottom - top == rendered_height
    )


def validate(
    records: dict[str, list[dict[str, Any]]], output_root: Path
) -> dict[str, Any]:
    expected_sizes = {
        "iphone": [1206, 2622],
        "ipad": [2064, 2752],
        "macos": [2880, 1800],
        "duo": [2853, 2007],
    }
    checks: list[dict[str, Any]] = []

    for platform, platform_records in records.items():
        filenames = [record["filename"] for record in platform_records]
        source_hashes = [record["source"]["sha256"] for record in platform_records]
        output_hashes = [record["output"]["sha256"] for record in platform_records]
        gallery_pngs = sorted(path.name for path in (output_root / platform).glob("*.png"))
        platform_checks = {
            "five_records": len(platform_records) == 5,
            "baseline_order": filenames == list(EXPECTED_ORDER),
            "five_gallery_pngs": gallery_pngs == sorted(EXPECTED_ORDER),
            "distinct_sources": len(set(source_hashes)) == 5,
            "distinct_outputs": len(set(output_hashes)) == 5,
            "expected_dimensions": all(
                record["output"]["size"] == expected_sizes[platform]
                for record in platform_records
            ),
            "png_rgb": all(
                record["output"]["format"] == "PNG"
                and record["output"]["mode"] == "RGB"
                for record in platform_records
            ),
            "uncropped": all(record["cropped"] is False for record in platform_records),
            "aspect_preserved": all(aspect_error(record) < 0.001 for record in platform_records),
            "capture_bounds_inside_canvas": all(
                capture_bounds_are_valid(record) for record in platform_records
            ),
            "manifest_filename_correspondence": all(
                Path(record["source"]["path"]).name == record["filename"]
                and Path(record["output"]["path"]).name == record["filename"]
                for record in platform_records
            ),
            "source_hashes_current": all(
                sha256_file(REPOSITORY_ROOT / record["source"]["path"])
                == record["source"]["sha256"]
                for record in platform_records
            ),
            "output_hashes_current": all(
                sha256_file(REPOSITORY_ROOT / record["output"]["path"])
                == record["output"]["sha256"]
                for record in platform_records
            ),
            "english_ui_disclosed": any(
                "Interfaz en inglés" in record["footnote"] for record in platform_records
            ),
            "purchase_copy_on_search_and_lists": all(
                "Una compra. Sin suscripción." in platform_records[index]["footnote"]
                for index in (2, 3)
            ),
            "icloud_free_and_optional": all(
                word in (
                    platform_records[4]["category"]
                    + " "
                    + platform_records[4]["footnote"]
                ).casefold()
                for word in ("gratis", "opcional")
            ),
            "duo_orientation_preserved": platform != "duo"
            or all(
                record["source"]["stored_size"] == [2006, 2852]
                and record["source"]["exif_orientation"] == 6
                and record["source"]["normalized_size"] == [2852, 2006]
                for record in platform_records
            ),
        }
        checks.append(
            {
                "platform": platform,
                "passed": all(platform_checks.values()),
                "checks": platform_checks,
                "maximum_aspect_ratio_error": max(
                    aspect_error(record) for record in platform_records
                ),
            }
        )

    total = sum(len(platform_records) for platform_records in records.values())
    report = {
        "schema_version": 1,
        "locale": "es-ES",
        "passed": total == 20 and all(check["passed"] for check in checks),
        "screenshot_count": total,
        "platform_count": len(records),
        "platforms": checks,
    }
    if not report["passed"]:
        failed = [check["platform"] for check in checks if not check["passed"]]
        raise RuntimeError(f"Screenshot QA failed for: {', '.join(failed)}")
    return report


def build_manifest(
    records: dict[str, list[dict[str, Any]]],
    contact_sheets: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "locale": "es-ES",
        "generation": {
            "wrapper": {
                "path": relative(Path(__file__)),
                "sha256": sha256_file(Path(__file__)),
            },
            "source_compositors": [
                {
                    "path": relative(BASE_COMPOSITOR_PATH),
                    "sha256": sha256_file(BASE_COMPOSITOR_PATH),
                    "platforms": ["iphone", "ipad", "macos"],
                },
                {
                    "path": relative(DUO_COMPOSITOR_PATH),
                    "sha256": sha256_file(DUO_COMPOSITOR_PATH),
                    "platforms": ["duo"],
                },
            ],
            "capture_policy": "Complete genuine captures; EXIF transpose; contain only; no crop or retouching.",
        },
        "expected_order": list(EXPECTED_ORDER),
        "platforms": {
            platform: {
                "label": PLATFORM_LABELS[platform],
                "composition_manifest": {
                    "path": relative(
                        composition_path := DEFAULT_OUTPUT_ROOT
                        / (
                            "duo/composition-duo.json"
                            if platform == "duo"
                            else f"composition-{platform}.json"
                        )
                    ),
                    "sha256": sha256_file(composition_path),
                },
                "screenshots": platform_records,
                "contact_sheet": contact_sheets[platform],
            }
            for platform, platform_records in records.items()
        },
    }


def main() -> None:
    parser = ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT_ROOT,
        help="output root (defaults to release/app-store/1.6.1/screenshots/es-ES)",
    )
    args = parser.parse_args()
    output_root = args.output.resolve()
    if output_root != DEFAULT_OUTPUT_ROOT.resolve():
        parser.error("this release wrapper writes only to its canonical es-ES output root")

    base = load_module("comicreader_base_screenshot_compositor", BASE_COMPOSITOR_PATH)
    duo = load_module("comicreader_duo_screenshot_compositor", DUO_COMPOSITOR_PATH)
    base.PANELS = spanish_base_panels(base)
    duo.PANELS = spanish_duo_panels(duo)

    records = compose_base_galleries(base, output_root)
    records["duo"] = compose_duo_gallery(duo, output_root)
    contact_sheets = {
        platform: create_contact_sheet(platform, output_root) for platform in records
    }
    qa_report = validate(records, output_root)
    write_json(output_root / "screenshot-qa.json", qa_report)
    manifest = build_manifest(records, contact_sheets)
    write_json(output_root / "asset-manifest.json", manifest)

    for platform, platform_records in records.items():
        width, height = platform_records[0]["output"]["size"]
        print(f"Wrote 5 {PLATFORM_LABELS[platform]} screenshots at {width} x {height}")
    print(f"QA passed for 20 screenshots: {relative(output_root / 'screenshot-qa.json')}")
    print(f"Manifest: {relative(output_root / 'asset-manifest.json')}")


if __name__ == "__main__":
    main()
