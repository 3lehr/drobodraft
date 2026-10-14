#!/bin/bash
# Selbsttest des Drobo-Geraetemodells (Module/DroboModell.swift) gegen die Rohmessungen: Swift-Original und Python-Spiegel derselben Formel.
# 1 MiB lueckenlos seriell ~ 224 MB/s (Messung 214-224), 128 KiB lueckenlos seriell ~ 123 MB/s (Messung 123), 8 KiB zufaellig ~ 35 ms je Befehl.
set -eu
cd "$(dirname "${BASH_SOURCE[0]}")/.."; T=$(mktemp -d "${TMPDIR:-/tmp}/drobo_modell.XXXXXX")
cp Module/DroboModell.swift "$T/DroboModell.swift"
cat > "$T/main.swift" <<'SW'
import Darwin
func mbs(_ n: Int, _ b: Int) -> Double { var t = 0.0, e: Int64 = 0, s: Int64 = 0
  for _ in 0..<n { t += DroboModell.dauer(start: s, bytes: b, vorigesEnde: e); e = s + Int64(b); s = e }; return Double(n * b) / 1e6 / t }
let a = mbs(1000, 1 << 20), b = mbs(1000, 131072)
let ms8 = DroboModell.dauer(start: 1 << 40, bytes: 8192, vorigesEnde: 0) * 1000
print("swift: 1MiB \(Double(Int(a * 10)) / 10) MB/s, 128KiB \(Double(Int(b * 10)) / 10) MB/s, 8KiB zufaellig \(Double(Int(ms8 * 10)) / 10) ms")
exit(a > 219 && a < 229 && b > 118 && b < 128 && ms8 > 34 && ms8 < 37 ? 0 : 1)
SW
xcrun --sdk macosx swiftc -O "$T/DroboModell.swift" "$T/main.swift" -o "$T/t" > "$T/build.log" 2>&1 || { tail -5 "$T/build.log"; exit 1; }
"$T/t"; rc=$?
python3 -I - <<'PY'
def d(s, b, e): return 0.00054 + b / 253e6 + (0.035 if abs(s - e) > (1 << 20) else 0)
def mbs(b, n=1000):
    t = 0.0; e = 0; s = 0
    for _ in range(n): t += d(s, b, e); e = s + b; s = e
    return n * b / 1e6 / t
print("python: 1MiB %.1f MB/s, 128KiB %.1f MB/s, 8KiB zufaellig %.1f ms" % (mbs(1 << 20), mbs(131072), d(1 << 40, 8192, 0) * 1000))
PY
rm -rf "$T"; [ $rc = 0 ] && echo "SELBSTTEST OK" || { echo "SELBSTTEST FEHLER"; exit 1; }
