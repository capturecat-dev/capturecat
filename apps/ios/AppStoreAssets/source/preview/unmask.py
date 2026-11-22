#!/usr/bin/env python3
"""Paints the Simulator's screen mask out of the extracted frames.

The takes were recorded with `simctl io recordVideo --mask=black`, which
blacks out the rounded screen corners and the Dynamic Island. Full frame,
those black shapes read as a phone, so every masked pixel takes the
colour beside it: a corner repeats the nearest pixel in its row, and the
island blends across from its two sides. The frames then look like a
recording from a real iPhone, which has neither.

    python3 unmask.py REFERENCE FRAMES_DIR

REFERENCE is a frame of the same size in which the mask is the only
black near the corners and the island (the home screen), to find its
shape. FRAMES_DIR holds the JPEGs, rewritten in place.
"""
import os
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image


def find_mask(reference):
    """Per row: how far the mask runs in from the left and right edges
    (corners), and the island's span [a, b) where a row has one."""
    img = np.asarray(Image.open(reference).convert("RGB")).astype(np.int16)
    h, w, _ = img.shape
    dark = img.max(axis=2) < 24
    # Grow by 3 px so the soft edge of the mask goes too.
    grown = dark.copy()
    for dy in range(-3, 4):
        for dx in range(-3, 4):
            grown |= np.roll(np.roll(dark, dy, axis=0), dx, axis=1)
    corner = int(w * 0.2)
    left, right = np.zeros(h, int), np.zeros(h, int)
    for y in list(range(corner)) + list(range(h - corner, h)):
        row = grown[y]
        left[y] = np.argmin(row[:corner]) if not row[:corner].all() else corner
        right[y] = np.argmin(row[::-1][:corner]) if not row[::-1][:corner].all() else corner
    island = {}
    lo, hi = int(w * 0.28), int(w * 0.72)
    for y in range(int(h * 0.1)):
        xs = np.nonzero(grown[y, lo:hi])[0]
        if len(xs):
            island[y] = (lo + xs[0], lo + xs[-1] + 1)
    return h, w, left, right, island


def unmask(args):
    path, (h, w, left, right, island) = args
    img = np.asarray(Image.open(path).convert("RGB")).copy()
    if img.shape[:2] != (h, w):
        raise SystemExit(f"{path}: {img.shape[1]}x{img.shape[0]}, reference is {w}x{h}")
    for y in np.nonzero(left)[0]:
        img[y, : left[y]] = img[y, left[y]]
    for y in np.nonzero(right)[0]:
        img[y, w - right[y] :] = img[y, w - right[y] - 1]
    for y, (a, b) in island.items():
        t = np.linspace(0, 1, b - a + 2)[1:-1, None]
        img[y, a:b] = ((1 - t) * img[y, a - 1] + t * img[y, b]).astype(np.uint8)
    Image.fromarray(img).save(path, quality=95)


def main(reference, frames):
    mask = find_mask(reference)
    paths = sorted(os.path.join(frames, f) for f in os.listdir(frames) if f.endswith(".jpg"))
    with Pool() as pool:
        pool.map(unmask, [(p, mask) for p in paths], chunksize=16)
    print(f"unmasked {len(paths)} frames")


if __name__ == "__main__":
    main(*sys.argv[1:3])
