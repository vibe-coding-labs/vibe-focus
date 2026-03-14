from math import cos, sin, radians
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"


def lerp(a, b, t):
    return int(round(a + (b - a) * t))


def gradient_image(size, start, end, horizontal=False):
    width, height = size
    image = Image.new("RGBA", size)
    pixels = image.load()
    span = max(1, (width - 1) if horizontal else (height - 1))
    for y in range(height):
        for x in range(width):
            t = (x if horizontal else y) / span
            pixels[x, y] = tuple(lerp(start[i], end[i], t) for i in range(4))
    return image


def rounded_mask(size, inset, radius, width=0):
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    left = inset
    top = inset
    right = size[0] - inset
    bottom = size[1] - inset
    draw.rounded_rectangle((left, top, right, bottom), radius=radius, fill=255 if width == 0 else 0, outline=255 if width else None, width=width)
    return mask


def line_mask(size, points, width):
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.line(points, fill=255, width=width, joint="curve")
    radius = width // 2
    for x, y in (points[0], points[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=255)
    return mask


def arc_mask(size, bbox, start, end, width):
    left, top, right, bottom = bbox
    cx = (left + right) / 2
    cy = (top + bottom) / 2
    rx = (right - left) / 2
    ry = (bottom - top) / 2
    points = []
    steps = max(32, int(abs(end - start) * 2.2))
    for step in range(steps + 1):
        angle = radians(start + (end - start) * step / steps)
        points.append((cx + rx * cos(angle), cy + ry * sin(angle)))
    return line_mask(size, points, width)


def composite_with_mask(base, overlay, mask):
    base.alpha_composite(Image.composite(overlay, Image.new("RGBA", base.size, (0, 0, 0, 0)), mask))


def render_app_icon():
    scale = 4
    final_size = 1024
    work_size = final_size * scale
    image = Image.new("RGBA", (work_size, work_size), (0, 0, 0, 0))

    bg_gradient = gradient_image((work_size, work_size), (16, 26, 54, 255), (55, 138, 142, 255))
    bg_mask = rounded_mask((work_size, work_size), 0, 184 * scale)
    composite_with_mask(image, bg_gradient, bg_mask)

    frame = gradient_image((work_size, work_size), (255, 255, 255, 36), (201, 248, 255, 51))
    frame_mask = rounded_mask((work_size, work_size), 124 * scale, 244 * scale, width=28 * scale)
    composite_with_mask(image, frame, frame_mask)

    glow = Image.new("RGBA", (work_size, work_size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse(
        (
            (512 - 84) * scale,
            (512 - 84) * scale,
            (512 + 84) * scale,
            (512 + 84) * scale,
        ),
        fill=(255, 255, 255, 105),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=30 * scale))
    image.alpha_composite(glow)

    main_gradient = gradient_image((work_size, work_size), (255, 255, 255, 255), (157, 239, 255, 255))
    secondary_gradient = gradient_image((work_size, work_size), (207, 249, 255, 255), (255, 255, 255, 255))

    top_left = line_mask(
        (work_size, work_size),
        [(300 * scale, 300 * scale), (364 * scale, 320 * scale), (418 * scale, 366 * scale), (468 * scale, 452 * scale)],
        98 * scale,
    )
    composite_with_mask(image, main_gradient, top_left)

    top_right = line_mask(
        (work_size, work_size),
        [(724 * scale, 300 * scale), (660 * scale, 320 * scale), (606 * scale, 366 * scale), (556 * scale, 452 * scale)],
        98 * scale,
    )
    composite_with_mask(image, main_gradient, top_right)

    bottom_outer = arc_mask(
        (work_size, work_size),
        (336 * scale, 524 * scale, 688 * scale, 876 * scale),
        148,
        32,
        92 * scale,
    )
    composite_with_mask(image, main_gradient, bottom_outer)

    bottom_inner = arc_mask(
        (work_size, work_size),
        (430 * scale, 514 * scale, 594 * scale, 678 * scale),
        150,
        30,
        46 * scale,
    )
    composite_with_mask(image, secondary_gradient, bottom_inner)

    core = Image.new("RGBA", (work_size, work_size), (0, 0, 0, 0))
    core_draw = ImageDraw.Draw(core)
    core_draw.ellipse(
        (
            (512 - 22) * scale,
            (512 - 22) * scale,
            (512 + 22) * scale,
            (512 + 22) * scale,
        ),
        fill=(255, 255, 255, 255),
    )
    image.alpha_composite(core)

    image = image.resize((final_size, final_size), Image.Resampling.LANCZOS)
    image.save(ASSETS / "AppIcon.png")


def render_status_icon():
    size = 256
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    color = (17, 17, 17, 255)

    draw.line([(56, 52), (96, 72), (128, 116)], fill=color, width=18, joint="curve")
    draw.line([(200, 52), (160, 72), (128, 116)], fill=color, width=18, joint="curve")

    arc = arc_mask((size, size), (66, 118, 190, 214), 28, 152, 18)
    composite_with_mask(image, Image.new("RGBA", (size, size), color), arc)

    draw.ellipse((118, 118, 138, 138), fill=color)
    image = image.filter(ImageFilter.GaussianBlur(radius=0.35))

    pixels = image.load()
    for y in range(size):
        for x in range(size):
            r, g, b, a = pixels[x, y]
            if a < 10:
                pixels[x, y] = (0, 0, 0, 0)
            else:
                pixels[x, y] = (17, 17, 17, min(255, int(a * 1.15)))

    image.save(ASSETS / "StatusBarIcon.png")


def main():
    render_app_icon()
    render_status_icon()


if __name__ == "__main__":
    main()
