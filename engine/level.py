"""Estimate the roll of a Quest 3 eye frame from its dominant straight edges.

The panel image is full of horizontal and vertical edges (window frames, dock
bar, monitor bezels, ceiling grid). A weighted histogram of gradient directions
around the two axes gives the roll directly, without needing to find a horizon.

Usage: level.py <gray_raw_file> <width> <height> [--max-frames N]
Prints one line: "roll=<deg> confidence=<0..1> frames=<n>"
"""
import sys

import numpy as np

W = int(sys.argv[2])
H = int(sys.argv[3])
max_frames = 12
if '--max-frames' in sys.argv:
    max_frames = int(sys.argv[sys.argv.index('--max-frames') + 1])
# the headset lens warps straight world lines into curves, and the further from
# the centre the stronger that is: measuring only the middle of the frame keeps
# the estimate close to the real panel roll
crop = 0.0
if '--crop' in sys.argv:
    crop = float(sys.argv[sys.argv.index('--crop') + 1])

raw = np.fromfile(sys.argv[1], dtype=np.uint8)
frame_size = W * H
total = len(raw) // frame_size
if total == 0:
    print('roll=0.00 confidence=0.00 frames=0')
    sys.exit(0)

count = min(total, max_frames)
picks = [int(i * total / count) for i in range(count)]

# ignore a thin border: rotated footage carries black wedges there, and the
# headset panel has a vignette right at the edge
mx, my = int(W * 0.03), int(H * 0.03)

angles = []
weights = []

for p in picks:
    frame = raw[p * frame_size:(p + 1) * frame_size].reshape(H, W).astype(np.float32)
    if crop:
        cy0, cy1 = int(H * crop), int(H * (1 - crop))
        cx0, cx1 = int(W * crop), int(W * (1 - crop))
        frame = frame[cy0:cy1, cx0:cx1]
    frame = frame[my:frame.shape[0] - my, mx:frame.shape[1] - mx]
    frame -= frame.mean()
    gy, gx = np.gradient(frame)
    mag = np.hypot(gx, gy)
    # hard threshold relative to the strongest edges: a plain percentile is a
    # trap, on synthetic or high-contrast content 85% of pixels can sit exactly
    # at the edge value and the mask ends up empty
    strong = float(np.percentile(mag, 99.5))
    thr = max(4.0, 0.30 * strong)
    mask = mag >= thr
    if mask.sum() < 0.002 * mag.size:
        continue
    ang = np.degrees(np.arctan2(gy[mask], gx[mask])) % 90.0
    delta = ang.copy()
    delta[delta > 45] -= 90.0          # fold to (-45, 45]
    angles.append(delta)
    weights.append(mag[mask])

if not angles:
    print('roll=0.00 confidence=0.00 frames=0')
    sys.exit(0)

all_delta = np.concatenate(angles)
all_w = np.concatenate(weights)

bins = np.arange(-45, 45.25, 0.25)
hist, edges = np.histogram(all_delta, bins=bins, weights=all_w)
smoothed = np.convolve(hist, np.ones(9) / 9.0, mode='same')   # ~2 deg window
peak = int(np.argmax(smoothed))
roll = float((edges[peak] + edges[peak + 1]) / 2.0)
if 0 < peak < len(smoothed) - 1:
    y0, y1, y2 = smoothed[peak - 1], smoothed[peak], smoothed[peak + 1]
    denom = (y0 - 2 * y1 + y2)
    if denom != 0:
        roll += 0.125 * (y0 - y2) / denom
# share of the weight within +-3 deg of the peak: flat histograms mean the
# scene has no straight lines and the number cannot be trusted
lo, hi = max(0, peak - 12), min(len(smoothed), peak + 13)
confidence = float(smoothed[lo:hi].sum() / (smoothed.sum() + 1e-9))
print('roll=%.2f confidence=%.2f frames=%d' % (roll, confidence, len(picks)))
