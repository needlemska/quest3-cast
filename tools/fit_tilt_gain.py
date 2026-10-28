#!/usr/bin/env python3
"""Fit the auto-level gain from a recorded session log.

The engine writes `tiltlog.csv` (iso,imu_roll,tilt_deg) every time it moves the
picture. The relation it tries to follow is

    tilt_deg = base + sign * gain * (imu_roll - base_roll)

so a straight line through the log gives the gain that actually matches what the
operator saw on the screen, and the spread around that line tells whether the
picture was jumping instead of tracking.

Usage:
    python tiltlog-fit.py [path-to-tiltlog.csv] [--current 1.0]

Default path is %LOCALAPPDATA%\\quest3-control\\state\\tiltlog.csv (the state folder
the control app hands to the engine).
"""

import math
import os
import sys

# the messages are Russian; a default Windows console is cp866 and would print
# mojibake, while Windows Terminal and VS Code handle utf-8 correctly
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def default_path():
    # the engine's state folder, in the order the app resolves it: the explicit
    # override first, then the app's own state dir, then the service one
    env = os.environ.get("QUEST3CAST_STATE")
    if env:
        candidate = os.path.join(env, "tiltlog.csv")
        if os.path.exists(candidate):
            return candidate
    roaming = os.environ.get("APPDATA")
    if roaming:
        candidate = os.path.join(roaming, "QuestCast", "state", "tiltlog.csv")
        if os.path.exists(candidate):
            return candidate
    local = os.environ.get("LOCALAPPDATA")
    if local:
        candidate = os.path.join(local, "quest3-cast", "tiltlog.csv")
        if os.path.exists(candidate):
            return candidate
    here = os.path.dirname(os.path.abspath(__file__))
    for rel in ("state/tiltlog.csv", "../state/tiltlog.csv"):
        candidate = os.path.normpath(os.path.join(here, rel))
        if os.path.exists(candidate):
            return candidate
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "tiltlog.csv")


def load(path):
    rows = []
    with open(path, "r", encoding="utf-8-sig") as fh:
        for line in fh:
            parts = line.strip().split(",")
            if len(parts) != 3:
                continue
            try:
                rows.append((float(parts[1]), float(parts[2])))
            except ValueError:
                continue  # header
    return rows


def fit(rows):
    """Least squares y = a*x + b, plus the residual spread in degrees."""
    n = len(rows)
    sx = sum(x for x, _ in rows)
    sy = sum(y for _, y in rows)
    sxx = sum(x * x for x, _ in rows)
    sxy = sum(x * y for x, y in rows)
    den = n * sxx - sx * sx
    if abs(den) < 1e-9:
        return None
    a = (n * sxy - sx * sy) / den
    b = (sy - a * sx) / n
    resid = [y - (a * x + b) for x, y in rows]
    rms = math.sqrt(sum(r * r for r in resid) / n)
    return a, b, rms


def main(argv):
    # `--current 1.2` used to leak its value into the positional path, so the tool
    # looked for a file named "1.2" and always answered "нет файла"
    path = None
    current = 1.0
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--current" and i + 1 < len(argv):
            try:
                current = float(argv[i + 1])
            except ValueError:
                print(f"--current: не число: {argv[i + 1]}")
                return 2
            i += 2
            continue
        if not a.startswith("--") and path is None:
            path = a
        i += 1
    if path is None:
        path = default_path()
    if not os.path.exists(path):
        print(f"нет файла {path}")
        print("включите АВТО-ГОРИЗОНТ, покрутите головой на 20-30 градусов и повторите")
        return 2

    rows = load(path)
    if len(rows) < 20:
        print(f"в журнале всего {len(rows)} строк - мало для подбора")
        return 2

    xs = [x for x, _ in rows]
    print(f"файл: {path}")
    print(f"строк: {len(rows)}, крен IMU: {min(xs):+.1f}..{max(xs):+.1f} град")
    if max(xs) - min(xs) < 5:
        print("размах крена меньше 5 град - наклоните голову сильнее, иначе наклон прямой не измерить")

    res = fit(rows)
    if res is None:
        print("крен не менялся - подбирать нечего")
        return 2
    a, b, rms = res
    print()
    print(f"наклон прямой: {a:+.3f} град картинки на градус крена (сейчас в настройках {current:.2f})")
    print(f"смещение: {b:+.2f} град")
    print(f"разброс вокруг прямой: {rms:.2f} град " + ("(рывками - виноват не гейн, а сглаживание/сеть)" if rms > 1.5 else "(гладко)"))
    print()
    guess = abs(a) if abs(a) > 0.05 else current
    print(f"рекомендация: ГЕЙН {guess:.2f}")
    if a < 0:
        print("наклон отрицательный - сначала нажмите ЗНАК КРЕНА, потом подбирайте гейн заново")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
