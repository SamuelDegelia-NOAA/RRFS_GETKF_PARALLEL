#!/usr/bin/env python3
import re
import sys
from pathlib import Path

USAGE = "usage: fix_satwnd_satellite_identifier.py INPUT.yaml OUTPUT.yaml [--rewrite-not-in]"

def leading_ws(s: str) -> str:
    m = re.match(r'^(\s*)', s)
    return m.group(1) if m else ""

def convert(lines, rewrite_not_in=False):
    out = []
    i = 0

    while i < len(lines):
        line = lines[i]

        if re.match(r'^\s*-\s*variable:\s*MetaData/satelliteIdentifier\s*$', line):
            out.append(line)

            if i + 1 < len(lines):
                nextline = lines[i + 1]
                indent = leading_ws(nextline)
                itemindent = leading_ws(line)

                if re.match(r'^\s*is_in:\s*272\s*$', nextline):
                    out.append(f"{indent}minvalue: 271.5\n")
                    out.append(f"{indent}maxvalue: 272.5\n")
                    i += 2
                    continue

                if re.match(r'^\s*is_in:\s*273\s*$', nextline):
                    out.append(f"{indent}minvalue: 272.5\n")
                    out.append(f"{indent}maxvalue: 273.5\n")
                    i += 2
                    continue

                if re.match(r'^\s*is_not_in:\s*272\s*$', nextline):
                    if rewrite_not_in:
                        out.pop()  # replace the just-appended variable line
                        out.append(f"{itemindent}- variable: MetaData/satelliteIdentifier\n")
                        out.append(f"{indent}maxvalue: 271.5\n")
                        out.append(f"{itemindent}- variable: MetaData/satelliteIdentifier\n")
                        out.append(f"{indent}minvalue: 272.5\n")
                    else:
                        out.append(nextline)
                    i += 2
                    continue

                if re.match(r'^\s*is_not_in:\s*273\s*$', nextline):
                    if rewrite_not_in:
                        out.pop()
                        out.append(f"{itemindent}- variable: MetaData/satelliteIdentifier\n")
                        out.append(f"{indent}maxvalue: 272.5\n")
                        out.append(f"{itemindent}- variable: MetaData/satelliteIdentifier\n")
                        out.append(f"{indent}minvalue: 273.5\n")
                    else:
                        out.append(nextline)
                    i += 2
                    continue

        out.append(line)
        i += 1

    return out

def main():
    if len(sys.argv) < 3:
        print(USAGE, file=sys.stderr)
        sys.exit(2)

    infile = Path(sys.argv[1])
    outfile = Path(sys.argv[2])
    rewrite_not_in = "--rewrite-not-in" in sys.argv[3:]

    lines = infile.read_text().splitlines(keepends=True)
    new_lines = convert(lines, rewrite_not_in=rewrite_not_in)
    outfile.write_text("".join(new_lines))

if __name__ == "__main__":
    main()
