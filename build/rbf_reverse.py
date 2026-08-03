#!/usr/bin/env python3
"""Convert a Quartus .rbf into the bit-reversed .rbf_r that openFPGA expects."""
import sys

REV = bytes(int(format(b, '08b')[::-1], 2) for b in range(256))

def main(src, dst):
    with open(src, 'rb') as f:
        data = f.read()
    with open(dst, 'wb') as f:
        f.write(data.translate(REV))
    print(f"{dst}: {len(data)} bytes")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
