#!/usr/bin/env python3
"""Offline-Liste der HFS-komprimierten Dateien (UF_COMPRESSED) aus Katalog- und Attributsicherung (HFS+-B-Baeume), Phase 5b.
Liest NUR die uebergebenen Dateien bzw. das uebergebene Abbild; Geraete (/dev/...) werden abgelehnt.
Aufruf: decmpfs_liste.py --katalog catalog.bin --attribute attributes.bin --out liste.json [--typ8-gross 10 --typ8-zufall 20 --seed 20261014]
        decmpfs_liste.py --abbild test.img --out liste.json          (zieht Katalog/Attribute aus den Gabeln im Volume-Header, nur Testabbilder)
Ergebnis-JSON: {"quelle","gesamt","typen":{"7":n,"8":n,...},"auswahl":[{pfad,typ,groesse,fileid}],"alle":[...]}.
Auswahl: alle Typ 7 + die N groessten Typ 8 + M zufaellige weitere Typ 8 (fester Seed)."""
import argparse, json, mmap, os, random, struct, sys

def knoten(m):
    """(nodeSize, firstLeaf, totalNodes) aus dem Kopfknoten."""
    if m[8] != 1: raise SystemExit("kein B-Baum-Kopfknoten")
    _depth, _root, _leafrecs, first, _last, nsize = struct.unpack_from(">HIIIIH", m, 14)
    return nsize, first, struct.unpack_from(">I", m, 14 + 20)[0]

def leaves(m):
    """Liefert (knotenoffset, nsize, [recordoffsets]) fuer alle Blattknoten in Kettenreihenfolge."""
    nsize, n, total = knoten(m)
    seen = 0
    while n and seen <= total:
        o = n * nsize
        flink, _b, kind, _h, nrec = struct.unpack_from(">IIbBH", m, o)
        if kind != -1: raise SystemExit("Knoten %d ist kein Blattknoten (kind=%d)" % (n, kind))
        offs = [struct.unpack_from(">H", m, o + nsize - 2 * (i + 1))[0] for i in range(nrec)]
        yield o, offs
        n = flink; seen += 1

def katalog(m):
    """-> (dateien[(fileid, parent, name, ownerFlags)], threads{folderID: (parent, name)})"""
    files = []; threads = {}
    for o, offs in leaves(m):
        for r in offs:
            p = o + r
            klen = struct.unpack_from(">H", m, p)[0]
            parent, nlen = struct.unpack_from(">IH", m, p + 2)
            d = p + 2 + klen + ((klen + 2) & 1)
            rt = struct.unpack_from(">H", m, d)[0]
            if rt == 2:                                           # Datei
                fid = struct.unpack_from(">I", m, d + 8)[0]
                owner_flags = m[d + 32 + 9]                       # bsdInfo: ownerID 4, groupID 4, adminFlags 1, ownerFlags 1
                if owner_flags & 0x20:                            # UF_COMPRESSED
                    files.append((fid, parent, m[p + 8:p + 8 + 2 * nlen].decode("utf-16-be"), struct.unpack_from(">IH", m, d + 32)[0], struct.unpack_from(">H", m, d + 32 + 10)[0]))
            elif rt == 3:                                         # Ordner-Thread: Schluessel = Ordner-ID, Daten = (Eltern-ID, Name)
                par, tl = struct.unpack_from(">IH", m, d + 4)
                threads[parent] = (par, m[d + 10:d + 10 + 2 * tl].decode("utf-16-be"))
    return files, threads

def decmpfs(m, ids):
    """-> {fileid: (typ, groesse)}; typ -1 = Wert liegt in einer Fork-Attributsatz (nicht aus der Sicherung lesbar), -2 = kein/ungueltiger Header."""
    out = {}
    for o, offs in leaves(m):
        for r in offs:
            p = o + r
            klen = struct.unpack_from(">H", m, p)[0]
            fid, _start, nlen = struct.unpack_from(">IIH", m, p + 4)
            if fid not in ids: continue
            if m[p + 14:p + 14 + 2 * nlen].decode("utf-16-be") != "com.apple.decmpfs": continue
            d = p + 2 + klen + ((klen + 2) & 1)
            rt = struct.unpack_from(">I", m, d)[0]
            if rt != 0x10: out[fid] = (-1, 0); continue
            asz = struct.unpack_from(">I", m, d + 12)[0]
            h = bytes(m[d + 16:d + 16 + min(asz, 16)])
            out[fid] = struct.unpack_from("<IQ", h, 4)[0:2] if asz >= 16 and h[:4] == b"fpmc" else (-2, 0)
    return out

def pfad(fid_parent, name, threads):
    parts = [name]; p = fid_parent; n = 0
    while p != 2 and n < 200:                                     # 2 = Wurzelordner
        if p not in threads: parts.append("?%d" % p); break
        p, nm = threads[p]; parts.append(nm); n += 1
    return "/" + "/".join(reversed(parts))

def abbild_forks(img, tmp):
    f = open(img, "rb"); f.seek(1024); vh = f.read(512)
    if vh[:2] not in (b"H+", b"HX"): raise SystemExit("kein HFS+")
    bs = struct.unpack_from(">I", vh, 40)[0]; res = []
    for name, off in (("catalog.bin", 272), ("attributes.bin", 352)):
        size = struct.unpack_from(">Q", vh, off)[0]; ext = [struct.unpack_from(">II", vh, off + 16 + 8 * i) for i in range(8)]
        if sum(c for _, c in ext) * bs < size: raise SystemExit("%s: Extents im Volume-Header reichen nicht (Ueberlaufbaum)" % name)
        data = b""
        for st, c in ext:
            if c: f.seek(st * bs); data += f.read(c * bs)
        open(os.path.join(tmp, name), "wb").write(data[:size]); res.append(os.path.join(tmp, name))
    return res

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--katalog"); ap.add_argument("--attribute"); ap.add_argument("--abbild"); ap.add_argument("--out", required=True)
    ap.add_argument("--typ8-gross", type=int, default=10); ap.add_argument("--typ8-zufall", type=int, default=20); ap.add_argument("--seed", type=int, default=20261014)
    a = ap.parse_args()
    if a.abbild:
        import tempfile; tmp = tempfile.mkdtemp(prefix="decmpfs_liste_"); a.katalog, a.attribute = abbild_forks(a.abbild, tmp); quelle = a.abbild
    else: quelle = a.katalog + " + " + str(a.attribute)
    for p in (a.katalog, a.attribute):
        if not p or os.path.realpath(p).startswith("/dev/"): raise SystemExit("nur Dateien, keine Geraete: %s" % p)
    with open(a.katalog, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m: files, threads = katalog(m)
    with open(a.attribute, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m: dm = decmpfs(m, {x[0] for x in files})
    alle = []
    for fid, parent, name, uid, mode in files:
        typ, size = dm.get(fid, (-3, 0))                          # -3 = decmpfs-Attribut nicht gefunden
        alle.append({"pfad": pfad(parent, name, threads), "typ": typ, "groesse": size, "fileid": fid, "uid": uid, "modus": oct(mode & 0o7777)})
    alle.sort(key=lambda e: e["pfad"])
    typen = {}
    for e in alle: typen[str(e["typ"])] = typen.get(str(e["typ"]), 0) + 1
    t7 = [e for e in alle if e["typ"] == 7]; t8 = [e for e in alle if e["typ"] == 8]
    gross = sorted(t8, key=lambda e: (-e["groesse"], e["pfad"]))[:a.typ8_gross]
    rest = [e for e in t8 if e not in gross]; rnd = random.Random(a.seed)
    zuf = rnd.sample(rest, min(a.typ8_zufall, len(rest)))
    auswahl = t7 + gross + sorted(zuf, key=lambda e: e["pfad"])
    json.dump({"quelle": quelle, "gesamt": len(alle), "typen": typen, "seed": a.seed, "auswahl": auswahl, "alle": alle}, open(a.out, "w"), indent=1, ensure_ascii=False)
    print("UF_COMPRESSED gesamt %d, Typen %s, Auswahl %d (Typ7 %d + gross %d + zufall %d) -> %s" % (len(alle), typen, len(auswahl), len(t7), len(gross), len(zuf), a.out))

if __name__ == "__main__": main()
