#!/usr/bin/env python3
"""Fixtures fuer die decmpfs-Eichung (Phase 5a): erzeugt unter MNT (vom KERNEL rw gemountetes HFS+) komprimierte Dateien Typ 7/8 (LZVN) und fehlerhafte.
Aufruf: python3 -I decmpfs_fixtures.py MNT MANIFEST.tsv GOODDIR
GOODDIR/<name> = Bytes, die von einer N-Datei hoechstens (als Praefix) gelesen werden duerfen: die vor dem Fehlerblock liegenden, gueltigen Bloecke.
Manifest (TAB): kind(P positiv|N negativ) name size md5(Quelle, bei N leer) typ(Header) beschreibung.
Positive Dateien prueft das Werkzeug selbst gegen den Kernel (md5 der vom Kernel entpackten Datei == md5 der Quelle) - der Kernel ist das Orakel.
Hand-gebaute Dateien: leere Datei, Ressourcengabel (..namedfork/rsrc), xattr com.apple.decmpfs, chflags UF_COMPRESSED (so macht es auch afsctool).
LZVN-Kodierer: libcompression COMPRESSION_LZVN (0x900) - rohe LZVN-Stroeme wie sie in Typ-7/8-Bloecken liegen."""
import ctypes, ctypes.util, hashlib, os, random, stat, struct, subprocess, sys

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
cmpl = ctypes.CDLL("/usr/lib/libcompression.dylib")
for f in (cmpl.compression_encode_buffer, cmpl.compression_decode_buffer):
    f.restype = ctypes.c_size_t
BLK = 65536
rnd = random.Random(20261014)

def lzvn(b):
    out = ctypes.create_string_buffer(len(b) + 4096)
    n = cmpl.compression_encode_buffer(out, len(out), b, len(b), None, 0x900)
    assert n > 0
    return out.raw[:n]

def text(n, seed=0):
    s = b"".join(b"zeile %d Drobo LZVN Fixture %d\n" % (i, seed) for i in range(n // 20 + 8))
    return s[:n]

def rand(n): return bytes(rnd.getrandbits(8) for _ in range(n))

def md5(b): return hashlib.md5(b).hexdigest()

def finish(path, typ, size, xattr_payload, fork=None, magic=b"fpmc"):
    open(path, "wb").close()
    if fork is not None:
        with open(path + "/..namedfork/rsrc", "wb") as f: f.write(fork)
    hdr = struct.pack("<4sIQ", magic, typ, size) + xattr_payload
    assert libc.setxattr(path.encode(), b"com.apple.decmpfs", hdr, len(hdr), 0, 0) == 0, ctypes.get_errno()
    os.chflags(path, stat.UF_COMPRESSED)

def table_fork(blocks):  # blocks = [bytes]; Tabelle (n+1) LE u32 Offsets ab Gabelanfang
    off = (len(blocks) + 1) * 4; tab = []
    for b in blocks: tab.append(off); off += len(b)
    tab.append(off)
    return struct.pack("<%dI" % len(tab), *tab) + b"".join(blocks)

def mk8(path, content, kinds):
    nb = (len(content) + BLK - 1) // BLK; assert len(kinds) == nb
    blocks = []
    for i, k in enumerate(kinds):
        raw = content[i * BLK:(i + 1) * BLK]
        blocks.append(lzvn(raw) if k == "z" else b"\x06" + raw)
    finish(path, 8, len(content), b"", table_fork(blocks))
    return blocks

def mk7(path, content, kind):
    finish(path, 7, len(content), lzvn(content) if kind == "z" else b"\x06" + content)

def main(mnt, manifest, gooddir):
    os.makedirs(gooddir, exist_ok=True)
    rows = []; pos = []
    def P(name, content, typ, desc): pos.append((name, content)); rows.append(("P", name, len(content), md5(content), typ, desc))
    def N(name, size, typ, desc, good=b""): rows.append(("N", name, size, "-", typ, desc)); open(os.path.join(gooddir, name), "wb").write(good)
    j = lambda n: os.path.join(mnt, n)
    # --- positive, vom Kernel selbst komprimiert (ditto --hfsCompression) ---
    for name, content, desc in (("t7_ditto.txt", text(6000), "Kernel-ditto klein (Typ 7, falls der Kernel komprimiert)"), ("t8_ditto_300k.txt", text(300000, 1), "Kernel-ditto 300000 B"),
                                ("t8_ditto_5m.txt", text(5 * 1048576 + 777, 2), "Kernel-ditto 5 MiB + 777"),
                                ("t8_ditto_mix.bin", text(70000, 3) + rand(70000) + text(100000, 4), "Kernel-ditto Text/Zufall/Text")):
        src = "/tmp/dc_src_" + name
        open(src, "wb").write(content)
        subprocess.run(["ditto", "--hfsCompression", src, j(name)], check=True); os.unlink(src)
        buf = ctypes.create_string_buffer(64); n = libc.getxattr(j(name).encode(), b"com.apple.decmpfs", buf, 64, 0, 0x20)
        typ = struct.unpack("<I", buf.raw[4:8])[0] if n >= 16 else 0
        if not os.stat(j(name)).st_flags & stat.UF_COMPRESSED:
            os.unlink(j(name)); print("Hinweis: Kernel hat %s nicht komprimiert, Fixture entfaellt" % name); continue
        P(name, content, typ, desc)
    c = rand(5 * 1048576 + 4097); open(j("plain_rand.bin"), "wb").write(c); P("plain_rand.bin", c, 0, "unkomprimiert 5 MiB + 4097 (Direktweg)")
    # --- positive, hand gebaut ---
    c = text(3400, 5);  mk7(j("t7_lzvn.txt"), c, "z"); P("t7_lzvn.txt", c, 7, "Typ 7 echter LZVN-Strom 3400 B")
    c = rand(1000);     mk7(j("t7_raw.bin"), c, "r");  P("t7_raw.bin", c, 7, "Typ 7 Rohdaten (0x06) 1000 B")
    c = b"ABCDEFGH" * 2500; mk7(j("t7_lzvn20k.bin"), c, "z"); P("t7_lzvn20k.bin", c, 7, "Typ 7 echter LZVN-Strom, 20000 B entpackt")
    c = b"";            mk7(j("t7_empty"), c, "r");    P("t7_empty", c, 7, "Typ 7, 0 Byte")
    c = text(3 * BLK + 12345, 6); mk8(j("t8_mixed.bin"), c, "zrzz"); P("t8_mixed.bin", c, 8, "Typ 8 LZVN/roh/LZVN/LZVN, Tail 12345 B")
    c = text(2 * BLK, 7);         mk8(j("t8_exact.txt"), c, "zz");   P("t8_exact.txt", c, 8, "Typ 8 genau 2 Bloecke")
    c = rand(BLK) + text(40000, 8); mk8(j("t8_rawfirst.bin"), c, "rz"); P("t8_rawfirst.bin", c, 8, "Typ 8 erster Block roh, Tail 40000 B")
    # --- negative ---
    c = text(200000, 9)
    blocks = [lzvn(c[i * BLK:(i + 1) * BLK]) for i in range(4)]
    finish(j("n_type4"), 4, len(c), b"", table_fork(blocks));  N("n_type4", len(c), 4, "unbekannter Typ 4 (zlib-Gabel)")
    finish(j("n_type12"), 12, len(c), b"", table_fork(blocks)); N("n_type12", len(c), 12, "unbekannter Typ 12 (LZFSE-Gabel)")
    t = bytearray(table_fork(blocks)); struct.pack_into("<I", t, 8, struct.unpack_from("<I", t, 4)[0] - 5)
    finish(j("n_offtab_nonmono"), 8, len(c), b"", bytes(t)); N("n_offtab_nonmono", len(c), 8, "Offsettabelle nicht monoton")
    t = bytearray(table_fork(blocks)); struct.pack_into("<I", t, 12, 0x7fffffff)
    finish(j("n_offtab_far"), 8, len(c), b"", bytes(t)); N("n_offtab_far", len(c), 8, "Offset weit hinter der Gabel")
    t = table_fork(blocks); finish(j("n_trunc"), 8, len(c), b"", t[:-100]); N("n_trunc", len(c), 8, "Gabel im letzten Block abgeschnitten", c[:3 * BLK])
    bad = list(blocks); bad[1] = b"\xff" * 200
    finish(j("n_lzvn_bad"), 8, len(c), b"", table_fork(bad)); N("n_lzvn_bad", len(c), 8, "Block 1 kein gueltiger LZVN-Strom", c[:BLK])
    short = list(blocks); short[2] = lzvn(c[2 * BLK:2 * BLK + 1000])
    finish(j("n_decode_short"), 8, len(c), b"", table_fork(short)); N("n_decode_short", len(c), 8, "Block 2 entpackt kuerzer als erwartet", c[:2 * BLK])
    lng = list(blocks); lng[1] = lzvn(text(70000, 10))
    finish(j("n_decode_long"), 8, len(c), b"", table_fork(lng)); N("n_decode_long", len(c), 8, "Block 1 entpackt laenger als 64 KiB", c[:BLK])
    t = bytearray(table_fork(blocks)); struct.pack_into("<I", t, 0, 4)
    finish(j("n_offtab_start"), 8, len(c), b"", bytes(t)); N("n_offtab_start", len(c), 8, "Tabelle beginnt vor ihrem Ende (t[0] < Tabellengroesse)")
    big = list(blocks); big[1] = b"\x06" + rand(70000)
    finish(j("n_offtab_delta"), 8, len(c), b"", table_fork(big)); N("n_offtab_delta", len(c), 8, "Blocklaenge > 64 KiB + 1", c[:BLK])
    finish(j("n_t8_huge"), 8, 2 ** 40, b"", table_fork(blocks)); N("n_t8_huge", 2 ** 40, 8, "Typ 8 mit 2^24 Bloecken (> tableMaxBlocks)")
    open(j("n_noxattr"), "wb").write(b"x" * 100)
    try: os.chflags(j("n_noxattr"), stat.UF_COMPRESSED)
    except OSError: pass
    if os.stat(j("n_noxattr")).st_flags & stat.UF_COMPRESSED: N("n_noxattr", 100, 0, "UF_COMPRESSED ohne xattr com.apple.decmpfs (100 B in der Datengabel)")
    else: os.unlink(j("n_noxattr")); print("Hinweis: Kernel entfernt UF_COMPRESSED ohne xattr, Fixture n_noxattr entfaellt")
    finish(j("n_t7_bad"), 7, 3400, b"\xff" * 50); N("n_t7_bad", 3400, 7, "Typ 7 ungueltiger LZVN-Strom")
    finish(j("n_t7_short"), 7, 5000, lzvn(text(3400, 5))); N("n_t7_short", 5000, 7, "Typ 7 entpackt kuerzer als Header-Groesse")
    finish(j("n_t7_size5g"), 7, 5 * 2**30, b"\x06" + b"x" * 10); N("n_t7_size5g", 5 * 2**30, 7, "Header meldet 5 GiB (getattr-Groesse 64 Bit), Lesen -> EIO")
    os.sync()
    # --- Kernel-Orakel: entpackte Quelle == md5 der Quelle ---
    for name, content in pos:
        got = md5(open(j(name), "rb").read())
        assert got == md5(content), "Kernel liest %s anders als die Quelle (%s != %s)" % (name, got, md5(content))
    with open(manifest, "w") as f:
        for r in rows: f.write("\t".join(str(x) for x in r) + "\n")
    print("Fixtures: %d positiv, %d negativ" % (len(pos), len(rows) - len(pos)))

if __name__ == "__main__": main(sys.argv[1], sys.argv[2], sys.argv[3])
