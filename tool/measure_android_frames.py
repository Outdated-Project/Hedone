"""Measure a foreground Flutter SurfaceView during controlled ADB swipes.

Uses SurfaceFlinger presentation timestamps, not Android View/gfxinfo timings.
Does not change display settings. Output includes raw samples for auditing.
"""

import argparse
import concurrent.futures
import json
import re
import shlex
import statistics
import subprocess
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--package', default='com.hghub.huangguo')
    parser.add_argument('--swipe', type=int, nargs=4, required=True,
                        metavar=('X1', 'Y1', 'X2', 'Y2'))
    parser.add_argument('--duration-ms', type=int, default=2000)
    parser.add_argument('--rounds', type=int, default=4)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 1000 <= args.duration_ms <= 10000 or not 1 <= args.rounds <= 20:
        parser.error('duration must be 1000..10000 ms; rounds must be 1..20')

    def adb(*command):
        return subprocess.run(['adb', '-s', args.serial, *command],
                              check=True, capture_output=True,
                              encoding='utf-8', errors='replace', timeout=30).stdout

    def shell(*command):
        return adb('shell', shlex.join(map(str, command)))

    layers = shell('dumpsys', 'SurfaceFlinger', '--list').splitlines()
    candidates = [s for s in layers if args.package in s and
                  'SurfaceView' in s and '(BLAST)' in s]
    if len(candidates) != 1:
        raise RuntimeError(f'Expected one Flutter BLAST surface, got {candidates}')
    layer = candidates[0]
    result = {'package': args.package, 'layer': layer,
              'method': 'SurfaceFlinger actualPresentTime; continuous swipes; '
                        'discard first/last 150 ms; no video FPS claim',
              'rounds': []}
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        for number in range(args.rounds):
            focus = shell('dumpsys', 'window')
            if not re.search(r'mCurrentFocus=.*' + re.escape(args.package) + r'/', focus):
                raise RuntimeError('Target app is not focused; refusing to inject a swipe')
            samples = {}
            periods = set()
            shell('dumpsys', 'SurfaceFlinger', '--latency-clear', layer)
            coords = args.swipe if number % 2 == 0 else args.swipe[2:] + args.swipe[:2]
            gesture = pool.submit(shell, 'input', 'swipe', *coords, args.duration_ms)
            while True:
                lines = shell('dumpsys', 'SurfaceFlinger', '--latency', layer).splitlines()
                if lines and lines[0].isdigit():
                    periods.add(int(lines[0]))
                for line in lines[1:]:
                    fields = line.split()
                    if len(fields) != 3 or not all(f.isdigit() for f in fields):
                        continue
                    row = list(map(int, fields))
                    if all(0 < value < 2**63 - 1 for value in row):
                        samples[row[1]] = row
                if gesture.done():
                    gesture.result()
                    break
                time.sleep(.15)
            rows = [samples[key] for key in sorted(samples)]
            if len(rows) < 3:
                raise RuntimeError('No usable presentation samples; device may deny latency queries')
            low, high = rows[0][1] + 150_000_000, rows[-1][1] - 150_000_000
            presents = [row[1] for row in rows if low <= row[1] <= high]
            intervals = [b - a for a, b in zip(presents, presents[1:])]
            if len(intervals) < 2:
                raise RuntimeError('Too few frames in the active swipe window')
            ordered = sorted(intervals)
            period = statistics.median(periods) if periods else 0
            summary = {
                'round': number + 1, 'swipe': coords,
                'display_periods_ns': sorted(periods),
                'sampled_frames': len(presents),
                'presentation_fps': len(intervals) * 1e9 / sum(intervals),
                'interval_ms_p50': statistics.median(intervals) / 1e6,
                'interval_ms_p95': ordered[round((len(ordered) - 1) * .95)] / 1e6,
                'interval_ms_max': max(intervals) / 1e6,
                'intervals_over_1_5_vsync': sum(i > period * 1.5 for i in intervals),
                'raw_desired_present_ready_ns': rows,
            }
            result['rounds'].append(summary)
            print(json.dumps({k: v for k, v in summary.items()
                              if not k.startswith('raw_')}, ensure_ascii=False), flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
