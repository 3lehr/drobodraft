#!/usr/bin/env python3
"""Mini-Leser fuer HFS+ (nur lesen): Volume-Header, JIB und Katalogeintraege unter einem Elternknoten (Vergleich enable-journal vs. diskutil)."""
import struct, sys

def be(fmt, b, o=0): return struct.unpack_from('>' + fmt, b, o)

class Vol:
    def __init__(s, path):
        s.f = open(path, 'rb'); s.f.seek(1024); s.vh = s.f.read(512)
        s.bs = be('I', s.vh, 40)[0]
    def rd(s, off, n): s.f.seek(off); return s.f.read(n)
    def fork(s, o):  # HFSPlusForkData bei VH-Offset o
        size, clump, blocks = be('QII', s.vh, o)
        ext = [be('II', s.vh, o + 16 + 8 * i) for i in range(8)]
        return size, blocks, [e for e in ext if e[1]]
    def read_fork(s, size, ext):
        out = b''
        for st, n in ext: out += s.rd(st * s.bs, n * s.bs)
        return out[:size]
    def catalog(s):
        size, blocks, ext = s.fork(288 + 80 * 0 + 0 if False else 288)   # catalogFile = VH+288? (allocation 112, extents 192, catalog 272)
        return size, ext

def vh_info(v):
    a = be('I', v.vh, 4)[0]
    print("VH: sig=%s attr=%#x lmv=%s jib=%d bs=%d total=%d free=%d files=%d dirs=%d" % (v.vh[:2], a, v.vh[8:12], be('I', v.vh, 12)[0], v.bs,
          be('I', v.vh, 44)[0], be('I', v.vh, 48)[0], be('I', v.vh, 32)[0], be('I', v.vh, 36)[0]))
    jib = be('I', v.vh, 12)[0]
    if jib:
        j = v.rd(jib * v.bs, 512); print("JIB: flags=%#x offset=%d (block %d) size=%d" % (be('I', j)[0], be('Q', j, 36)[0], be('Q', j, 36)[0] // v.bs, be('Q', j, 44)[0]))

def cat_records(v):
    # catalogFile-Fork liegt bei VH+272 (allocationFile 112, extentsFile 192, catalogFile 272, attributesFile 352)
    size, blocks, ext = v.fork(272)
    data = v.read_fork(size, ext)
    nodesz = be('H', data, 32)[0]; first = be('I', data, 24)[0]
    node = first
    while node:
        nd = data[node * nodesz:(node + 1) * nodesz]
        flink, blink, kind, height, nrec = be('IIbbH', nd, 0)
        offs = [be('H', nd, nodesz - 2 * (i + 1))[0] for i in range(nrec)]
        for o in offs:
            klen = be('H', nd, o)[0]; parent = be('I', nd, o + 2)[0]; nlen = be('H', nd, o + 6)[0]
            name = nd[o + 8:o + 8 + 2 * nlen].decode('utf-16-be', 'replace')
            d = o + 2 + klen; d += d % 2
            yield parent, name, nd[d:d + 248]
        node = flink

def show(v, parent=2):
    for p, name, rec in cat_records(v):
        if p != parent: continue
        t = be('H', rec)[0]
        if t == 2:
            flags, _, fid, cdate = be('HIII', rec, 2)
            owner, group, adm, own, mode = be('IIBBH', rec, 32)[0:5] if False else (be('I', rec, 32)[0], be('I', rec, 36)[0], rec[40], rec[41], be('H', rec, 42)[0])
            ftype, fcreator, fflags = rec[48:52], rec[52:56], be('H', rec, 56)[0]
            dsize, dclump, dblocks = be('QII', rec, 88)
            dext = [be('II', rec, 104 + 8 * i) for i in range(8) if be('II', rec, 104 + 8 * i)[1]]
            print("FILE %-22r id=%d flags=%#x mode=%o owner=%d/%d adm=%#x ownf=%#x finderFlags=%#x type=%s creator=%s size=%d blocks=%d ext=%s" %
                  (name, fid, flags, mode, owner, group, adm, own, fflags, ftype, fcreator, dsize, dblocks, dext))
        elif t == 1:
            flags, val, fid = be('HII', rec, 2)
            print("DIR  %-22r id=%d valence=%d" % (name, fid, val))

def extent_stats(v):
    """Extents-Ueberlaufdatei (VH+192): Zahl der Satzgruppen und Extents je fileID (nur Datenfork 0x00/0xFF)."""
    size, blocks, ext = v.fork(192)
    data = v.read_fork(size, ext)
    nodesz = be('H', data, 32)[0]; node = be('I', data, 24)[0]
    per = {}
    recs = 0
    while node:
        nd = data[node * nodesz:(node + 1) * nodesz]
        flink, blink, kind, height, nrec = be('IIbbH', nd, 0)
        for i in range(nrec):
            o = be('H', nd, nodesz - 2 * (i + 1))[0]
            fid = be('I', nd, o + 4)[0]
            n = sum(1 for j in range(8) if be('II', nd, o + 12 + 8 * j)[1])
            per[fid] = per.get(fid, 0) + n; recs += 1
        node = flink
    return recs, per

if __name__ == '__main__':
    v = Vol(sys.argv[1]); vh_info(v)
    if len(sys.argv) > 2 and sys.argv[2] == 'root': show(v, 2)
    if len(sys.argv) > 2 and sys.argv[2] == 'extents':
        r, per = extent_stats(v); print('Extents-Ueberlauf: %d Saetze; Extents je fileID (ohne die 8 im Katalog): %s' % (r, dict(sorted(per.items(), key=lambda kv: -kv[1])[:5])))
