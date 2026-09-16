#!/usr/bin/env python3
"""Sammelt übersetzbare Texte aus den Swift-Quellen und gibt die Schlüssel so aus,
wie SwiftUI/Foundation sie nachschlagen (Interpolationen als %@ bzw. %lld)."""
import re, sys, pathlib

CONTEXTS = r'(?:Text|Button|Label|Toggle|Section|Picker|TextField|SecureField|Menu|LabeledContent|' \
           r'ContentUnavailableView|Link|DatePicker|CommandMenu|localized:|\.help|prompt: Text|' \
           r'navigationTitle|LocalizedStringKey|panel\.prompt =)\s*\(?\s*'
INT_HINTS = ('count', 'Count', 'code', 'failed', '.id', 'id)')

def interpolations(literal):
    out, i = [], 0
    while True:
        j = literal.find('\\(', i)
        if j < 0: break
        depth, k = 1, j + 2
        while depth and k < len(literal):
            depth += {'(': 1, ')': -1}.get(literal[k], 0); k += 1
        out.append((j, k, literal[j+2:k-1])); i = k
    return out

def to_key(literal):
    parts, last = [], 0
    for start, end, expr in interpolations(literal):
        parts.append(literal[last:start])
        is_int = ('name' not in expr and 'title' not in expr) and (
            any(h in expr for h in INT_HINTS) or expr in ('id', 'code', 'failed'))
        parts.append('%lld' if is_int else '%@')
        last = end
    parts.append(literal[last:])
    return ''.join(parts)

keys = {}
pattern = re.compile(CONTEXTS + r'"((?:[^"\\]|\\.)*)"')
for path in sorted(pathlib.Path('Sources/Ablage').glob('*.swift')):
    for m in pattern.finditer(path.read_text()):
        lit = m.group(1)
        if not lit.strip() or not re.search(r'[A-Za-zÄÖÜäöü]', lit): continue
        keys.setdefault(to_key(lit).replace('\\"', '"'), path.name)
for k in sorted(keys):
    print(k)
