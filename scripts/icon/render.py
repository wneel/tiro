"""Draws Tiro's icon: the Tironian et (U+204A), the shorthand sign Tiro invented, with a glowing red
recording dot, on a dark macOS squircle. Usage: render.py <NotoSerif.ttf> <out.png> (1024 x 1024)."""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT, OUT = sys.argv[1], sys.argv[2]
S, BOX = 1024, 824  # macOS icon grid: an 824 px body centred on a 1024 px canvas
OFF = (S - BOX) // 2


def squircle_mask(size, n=5.0):
	m = Image.new("L", (size * 4, size * 4), 0)
	r = size * 2
	pts = []
	for i in range(720):
		t = 2 * math.pi * i / 720
		c, s = math.cos(t), math.sin(t)
		pts.append((r + r * math.copysign(abs(c) ** (2 / n), c), r + r * math.copysign(abs(s) ** (2 / n), s)))
	ImageDraw.Draw(m).polygon(pts, fill=255)
	return m.resize((size, size), Image.LANCZOS)


def gradient(top, bottom):
	g = Image.new("RGB", (1, BOX))
	for y in range(BOX):
		k = y / (BOX - 1)
		g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * k) for i in range(3)))
	return g.resize((BOX, BOX))


body = gradient((40, 40, 46), (14, 14, 18)).convert("RGBA")
font = ImageFont.truetype(FONT, 620)
font.set_variation_by_axes([800, 100])  # weight, width
draw = ImageDraw.Draw(body)
l, t, r, b = draw.textbbox((0, 0), "⁊", font=font)
draw.text(((BOX - (r - l)) / 2 - l - 20, (BOX - (b - t)) / 2 - t + 30), "⁊", font=font, fill=(255, 255, 255))

red, (cx, cy), radius = (255, 69, 58), (650, 170), 42
halo = Image.new("RGBA", (BOX, BOX), (0, 0, 0, 0))
ImageDraw.Draw(halo).ellipse((cx - radius * 2.2, cy - radius * 2.2, cx + radius * 2.2, cy + radius * 2.2), fill=red + (110,))
body = Image.alpha_composite(body, halo.filter(ImageFilter.GaussianBlur(40)))
ImageDraw.Draw(body).ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=red)

mask = squircle_mask(BOX)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.paste(Image.new("RGBA", (BOX, BOX), (0, 0, 0, 90)), (OFF, OFF + 12), mask)
icon = Image.alpha_composite(Image.new("RGBA", (S, S), (0, 0, 0, 0)), shadow.filter(ImageFilter.GaussianBlur(14)))
layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
layer.paste(body, (OFF, OFF), mask)
Image.alpha_composite(icon, layer).save(OUT)
