#!/usr/bin/env python3
"""Render Cinespice's vector icon with FFmpeg's librsvg decoder (development only)."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
catalog = root / 'Resources/Assets.xcassets'
icons = catalog / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
images = []
for points, scales, idiom in [
    (20, [2, 3], 'iphone'), (29, [2, 3], 'iphone'),
    (40, [2, 3], 'iphone'), (60, [2, 3], 'iphone'),
    (20, [1, 2], 'ipad'), (29, [1, 2], 'ipad'),
    (40, [1, 2], 'ipad'), (76, [1, 2], 'ipad'), (83.5, [2], 'ipad'),
    (1024, [1], 'ios-marketing'),
]:
    for scale in scales:
        pixels = int(points * scale)
        filename = f'Icon-{points}@{scale}x.png'
        subprocess.run([
            'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
            '-i', str(root / 'Design/AppIcon.svg'), '-vf', f'scale={pixels}:{pixels}:flags=lanczos',
            '-pix_fmt', 'rgb24', '-frames:v', '1', str(icons / filename),
        ], check=True)
        images.append({'filename': filename, 'idiom': idiom, 'scale': f'{scale}x', 'size': f'{points}x{points}'})
info = {'author': 'xcode', 'version': 1}
(catalog / 'Contents.json').write_text(json.dumps({'info': info}, indent=2) + '\n')
(icons / 'Contents.json').write_text(json.dumps({'images': images, 'info': info}, indent=2) + '\n')
print(f'Rendered {len(images)} opaque app icons from Design/AppIcon.svg')
