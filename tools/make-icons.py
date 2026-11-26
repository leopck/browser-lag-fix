"""Renders the extension icons (a shield over a disk platter) at 16/32/48/128 px.

Usage: python tools/make-icons.py   (requires Pillow)
Drawn at 8x and downsampled for clean anti-aliasing.
"""
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "extension" / "icons"
BLUE = (47, 91, 211, 255)
DARK = (22, 44, 110, 255)
WHITE = (255, 255, 255, 255)


def render(size: int) -> Image.Image:
    s = size * 8
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Shield outline: flat top with rounded shoulders, tapering to a point.
    w, h = s * 0.86, s * 0.94
    x0, y0 = (s - w) / 2, (s - h) / 2
    top = y0 + h * 0.08
    pts = [
        (x0 + w * 0.5, y0),
        (x0 + w, top + h * 0.06),
        (x0 + w, y0 + h * 0.48),
        (x0 + w * 0.5, y0 + h),
        (x0, y0 + h * 0.48),
        (x0, top + h * 0.06),
    ]
    d.polygon(pts, fill=BLUE)
    # Disk platter (concentric rings) inside the shield.
    cx, cy, r = s / 2, y0 + h * 0.46, w * 0.27
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=WHITE)
    r2 = r * 0.62
    d.ellipse([cx - r2, cy - r2, cx + r2, cy + r2], fill=BLUE)
    r3 = r * 0.22
    d.ellipse([cx - r3, cy - r3, cx + r3, cy + r3], fill=WHITE)
    # Read arm.
    d.line([(cx + r * 0.15, cy + r * 0.15), (cx + r * 0.95, cy + r * 1.05)], fill=DARK, width=max(1, int(s * 0.05)))
    return img.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for px in (16, 32, 48, 128):
        render(px).save(OUT / f"icon-{px}.png", optimize=True)
        print(f"wrote extension/icons/icon-{px}.png")
