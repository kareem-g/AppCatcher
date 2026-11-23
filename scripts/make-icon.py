#!/usr/bin/env python3
"""Generate the AppCatcher app icon: 1024x1024, opaque, full-bleed.

Flat mark: black canvas, one white container outline, a flat mint fill
level inside it. No gradients, no glow, no sparkle. iOS masks the shape;
we ship an opaque square. Supersampled for crisp edges.
"""
from PIL import Image, ImageDraw

S = 2048  # supersample
OUT = 1024

BLACK = (0, 0, 0)
WHITE = (255, 255, 255)
MINT = (90, 242, 192)  # #5AF2C0, the app's single accent

img = Image.new("RGB", (S, S), BLACK)

# Container: one rounded-rect outline, centred, generous margins.
margin = int(S * 0.22)
box = (margin, margin, S - margin, S - margin)
radius = S * 0.09
stroke = S * 0.045

# Fill level: flat mint, bottom 55% of the container's inner area,
# clipped to the container's inner rounded rect.
inner = (box[0] + stroke * 1.6, box[1] + stroke * 1.6,
         box[2] - stroke * 1.6, box[3] - stroke * 1.6)
fill_top = inner[1] + (inner[3] - inner[1]) * 0.45
inner_radius = max(radius - stroke * 1.2, 0)

# Clip: mint only where below fill_top AND inside the inner rounded rect.
inside = Image.new("L", (S, S), 0)
ImageDraw.Draw(inside).rounded_rectangle(inner, radius=inner_radius, fill=255)
below = Image.new("L", (S, S), 0)
ImageDraw.Draw(below).rectangle((0, fill_top, S, S), fill=255)

mint = Image.new("RGB", (S, S), MINT)
img.paste(mint, (0, 0), Image.composite(inside, Image.new("L", (S, S), 0), below))

# Outline on top so the fill sits clean under it.
ImageDraw.Draw(img).rounded_rectangle(box, radius=radius, outline=WHITE,
                                      width=int(stroke))

img = img.resize((OUT, OUT), Image.LANCZOS)
img.save("Resources/AppIcon.png", "PNG")
print("wrote Resources/AppIcon.png", img.size)
