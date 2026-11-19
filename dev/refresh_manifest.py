"""Regenerate the tracked source manifest before publishing a reviewed snapshot."""
import hashlib
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
names = subprocess.check_output(
    ['git', '-c', 'core.autocrlf=false', 'ls-files', '--cached', '--others', '--exclude-standard'], cwd=root, text=True).splitlines()
paths = sorted(set(n for n in names if n != 'SHA256SUMS' and (root / n).is_file()))
(root / 'SHA256SUMS').write_text(''.join(
    f'{hashlib.sha256((root / n).read_bytes()).hexdigest()}  {n}\n' for n in paths), encoding='utf-8', newline='\n')
