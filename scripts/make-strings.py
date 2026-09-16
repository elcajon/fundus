#!/usr/bin/env python3
"""Erzeugt Resources/en.lproj/Localizable.strings und prüft, dass jeder Text übersetzt ist."""
import subprocess, sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from translations_en import EN

keys = subprocess.run([sys.executable, str(pathlib.Path(__file__).parent / 'extract-strings.py')],
                      capture_output=True, text=True, check=True).stdout.splitlines()
missing = [k for k in keys if k not in EN]
if missing:
    print("Ohne Übersetzung:", *missing, sep="\n  ")
    sys.exit(1)

def esc(s): return s.replace('\\', '\\\\').replace('"', '\\"')
lines = ['/* Automatisch erzeugt von scripts/make-strings.py */']
lines += [f'"{esc(k)}" = "{esc(EN[k])}";' for k in keys]
out = pathlib.Path('Resources/en.lproj/Localizable.strings')
out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
print(f"{len(keys)} Texte nach {out}")
