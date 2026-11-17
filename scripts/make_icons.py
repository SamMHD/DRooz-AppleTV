#!/usr/bin/env python3
"""Generates the tvOS brand assets (layered app icons, top shelf images) and the launch colour.

Run from the repo root:  python3 scripts/make_icons.py
The mark is the DL Rooz emblem (red play disc over three fading lines), as in the Android TV banner.
"""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
XC = ROOT / "App/Resources/Assets.xcassets"
LOGO = ROOT / "scripts/logo.png"
FONT = ROOT / "App/Resources/Fonts/vazirmatn_extrabold.ttf"
BG = (0x0B, 0x0B, 0x0F)
RED = (0xE5, 0x09, 0x14)
WHITE = (0xF5, 0xF5, 0xF7)


def write_json(path: Path, data: dict) -> None:
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps(data, indent=2))


INFO = {"author": "xcode", "version": 1}


def back(w: int, h: int) -> Image.Image:
    img = Image.new("RGB", (w, h), BG)
    glow = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(glow)
    r = int(min(w, h) * 0.75)
    d.ellipse((w / 2 - r, h * 0.45 - r, w / 2 + r, h * 0.45 + r), fill=(0x3A, 0x06, 0x0A))
    return Image.blend(img, glow.filter(ImageFilter.GaussianBlur(min(w, h) * 0.25)), 0.9)


def emblem(w: int, h: int, scale: float) -> Image.Image:
    """Transparent front layer: the emblem centred, `scale` = emblem height / layer height."""
    ss = 4
    W, H = w * ss, h * ss
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    unit = H * scale / 90.0  # emblem design box is 100 x 90
    ox, oy = W / 2 - 50 * unit, H / 2 - 45 * unit
    def p(x, y):
        return (ox + x * unit, oy + y * unit)
    # Disc clipped at y=58.
    disc = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    dd = ImageDraw.Draw(disc)
    dd.ellipse((*p(20, 20), *p(80, 80)), fill=RED + (255,))
    clip = Image.new("L", (W, H), 0)
    ImageDraw.Draw(clip).rectangle((*p(0, 0), *p(100, 58)), fill=255)
    img.paste(disc, (0, 0), Image.composite(disc.split()[3], Image.new("L", (W, H), 0), clip))
    d.polygon([p(44, 39), p(44, 61), p(63, 50)], fill=WHITE + (255,))
    for (x1, x2, y, wd, a) in [(12, 88, 64, 5, 255), (28, 72, 75, 4, 115), (40, 60, 85, 4, 51)]:
        d.line([p(x1, y), p(x2, y)], fill=WHITE + (a,), width=max(1, int(wd * unit)))
        for x in (x1, x2):
            cx, cy = p(x, y)
            rr = wd * unit / 2
            d.ellipse((cx - rr, cy - rr, cx + rr, cy + rr), fill=WHITE + (a,))
    return img.resize((w, h), Image.LANCZOS)


def stack(name: str, sizes: list) -> None:
    """An imagestack with Back (opaque) and Front (emblem) layers at each (scale, w, h)."""
    base = XC / "App Icon & Top Shelf Image.brandassets" / f"{name}.imagestack"
    write_json(base, {"info": INFO, "layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}]})
    for layer in ("Front", "Back"):
        L = base / f"{layer}.imagestacklayer"
        write_json(L, {"info": INFO})
        images = []
        for scale, w, h in sizes:
            fn = f"{layer.lower()}{'' if scale == '1x' else '@' + scale}.png"
            img = back(w, h) if layer == "Back" else emblem(w, h, 0.62)
            (L / "Content.imageset").mkdir(parents=True, exist_ok=True)
            img.save(L / "Content.imageset" / fn)
            images.append({"idiom": "tv", "filename": fn, "scale": scale})
        write_json(L / "Content.imageset", {"images": images, "info": INFO})


def top_shelf(name: str, sizes: list) -> None:
    S = XC / "App Icon & Top Shelf Image.brandassets" / f"{name}.imageset"
    S.mkdir(parents=True, exist_ok=True)
    logo = Image.open(LOGO).convert("RGB")
    images = []
    for scale, w, h in sizes:
        img = back(w, h)
        lw = int(h * 0.55 * logo.width / logo.height)
        lh = int(h * 0.55)
        if lw > w * 0.8:
            lw, lh = int(w * 0.8), int(w * 0.8 * logo.height / logo.width)
        img.paste(logo.resize((lw, lh), Image.LANCZOS), ((w - lw) // 2, (h - lh) // 2))
        fn = f"shelf{'' if scale == '1x' else '@' + scale}.png"
        img.save(S / fn)
        images.append({"idiom": "tv", "filename": fn, "scale": scale})
    write_json(S, {"images": images, "info": INFO})


def main() -> None:
    write_json(XC, {"info": INFO})
    brand = XC / "App Icon & Top Shelf Image.brandassets"
    write_json(brand, {"info": INFO, "assets": [
        {"size": "1280x768", "idiom": "tv", "filename": "App Icon - App Store.imagestack", "role": "primary-app-icon"},
        {"size": "400x240", "idiom": "tv", "filename": "App Icon.imagestack", "role": "primary-app-icon"},
        {"size": "2320x720", "idiom": "tv", "filename": "Top Shelf Image Wide.imageset", "role": "top-shelf-image-wide"},
        {"size": "1920x720", "idiom": "tv", "filename": "Top Shelf Image.imageset", "role": "top-shelf-image"},
    ]})
    stack("App Icon", [("1x", 400, 240), ("2x", 800, 480)])
    stack("App Icon - App Store", [("1x", 1280, 768)])
    top_shelf("Top Shelf Image", [("1x", 1920, 720), ("2x", 3840, 1440)])
    top_shelf("Top Shelf Image Wide", [("1x", 2320, 720), ("2x", 4640, 1440)])
    mark = XC / "LogoMark.imageset"
    mark.mkdir(parents=True, exist_ok=True)
    Image.open(LOGO).convert("RGB").save(mark / "logo.png")
    write_json(mark, {"info": INFO, "images": [{"idiom": "universal", "filename": "logo.png"}]})
    write_json(XC / "LaunchBackground.colorset", {"info": INFO, "colors": [{"idiom": "universal", "color": {
        "color-space": "srgb", "components": {"red": "0.043", "green": "0.043", "blue": "0.059", "alpha": "1.000"}}}]})
    write_json(XC / "AccentColor.colorset", {"info": INFO, "colors": [{"idiom": "universal", "color": {
        "color-space": "srgb", "components": {"red": "0.898", "green": "0.035", "blue": "0.078", "alpha": "1.000"}}}]})


if __name__ == "__main__":
    main()
