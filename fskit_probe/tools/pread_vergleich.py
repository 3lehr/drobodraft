#!/usr/bin/env python3
"""Lesungen mitten im Block/Extent: pread an krummen Offsets und Laengen aus dem Modul-Mount gegen die Referenzkopie (Kernel-Lesung).
Aufruf: pread_vergleich.py REFDIR MODULMNT MANIFEST.tsv [ANZAHL]   (nur Zeilen kind P mit Groesse > 0; Exit 0 = alle gleich)"""
import os, random, sys
ref, mnt, tsv = sys.argv[1:4]; n = int(sys.argv[4]) if len(sys.argv) > 4 else 150
bad = 0; total = 0
for line in open(tsv):
    f = line.rstrip("\n").split("\t")
    if f[0] != "P" or int(f[2]) == 0: continue
    name, size = f[1], int(f[2]); rnd = random.Random(name)
    want = [(1, 1), (65535, 2), (65536, 1), (65537, 4096), (size - 1, 1), (max(size - 70001, 0), 70001), (3, min(size, 1 << 20) - 3 if size > 3 else 1)]
    want += [(rnd.randrange(size), rnd.choice([1, 7, 511, 4097, 16384, 65537, 131072, 1048577, 1500000])) for _ in range(n)]
    a = os.open(os.path.join(ref, name), os.O_RDONLY); b = os.open(os.path.join(mnt, name), os.O_RDONLY)
    for off, ln in want:
        if off >= size: continue
        total += 1
        try: got = os.pread(b, ln, off)
        except OSError as e: got = ("ERR", e.errno)
        if got != os.pread(a, ln, off):
            bad += 1; print("ABWEICHUNG %s off=%d len=%d" % (name, off, ln))
    os.close(a); os.close(b)
print("%d Lesungen an krummen Offsets, %d abweichend" % (total, bad))
sys.exit(1 if bad or total == 0 else 0)
