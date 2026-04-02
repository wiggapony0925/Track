"""Fix lines over 100 characters in HomeViewModel.swift."""

import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else 'Track/ViewModels/HomeViewModel.swift'
lines = open(path, 'r').readlines()
fixed = 0

for i, line in enumerate(lines):
    rline = line.rstrip('\n')
    if len(rline) <= 100:
        continue

    stripped = rline.lstrip()
    indent = len(rline) - len(stripped)

    # Fix box-drawing lines
    box_chars = set('═╔╠╚╗╣╝║')
    if stripped and stripped[0] in box_chars:
        parts = []
        j = 0
        while j < len(stripped):
            if stripped[j] == '═':
                k = j
                while k < len(stripped) and stripped[k] == '═':
                    k += 1
                total_other = len(stripped) - (k - j)
                available = 100 - indent - total_other
                parts.append('═' * max(10, available))
                j = k
            else:
                parts.append(stripped[j])
                j += 1
        new_line = ' ' * indent + ''.join(parts)
        if len(new_line) <= 100:
            lines[i] = new_line + '\n'
            fixed += 1

print(f'Fixed {fixed} box-drawing lines')
open(path, 'w').writelines(lines)
