#!/usr/bin/env python3
"""iSCSI-Pruefziel ueber Abbilddateien (nur Tests, nie ein Geraet). Bildet das gemessene Verhalten einer DroboPro nach:
Login braucht zwei Runden in der Sicherheitsphase (erste Antwort ohne T), MODE SENSE(10) 5A/3A mit Allokationslaenge > 512 wird nicht
beantwortet, Seiten 33/35 ebenfalls nicht, InitialR2T=Yes, ImmediateData=No, MaxBurstLength=524288.
Aufruf: python3 -I iscsi_ziel.py --image LUN0.img [--image LUN1.img] --log LOG.jsonl [Fehlerinjektion]
Gibt "PORT <n>" auf stdout aus, sobald es lauscht. Jeder Befehl landet als JSON-Zeile im Log (Pruefstand sieht, was das Ziel wirklich erreichte).
Fehlerinjektion: --drop-after N (Verbindung beim (N+1). SCSI-Befehl ohne Antwort schliessen), --swallow K (Befehl Nr. K nicht beantworten),
--r2t-chunk N (R2T in Stuecken von N Byte), --max-seg N (eigene MaxRecvDataSegmentLength, Data-Out darueber -> Verbindung zu).
DroboPro-Verhalten (gemessen 2026-10-16): ein WRITE ohne Daten im Command-PDU wird nicht beantwortet, kein R2T, Verbindung nach ~1 s zu (die echte DroboPro
startet dabei neu); hier Log "ABSTURZ write-ohne-immediate". Abschaltbar mit --tolerate-no-immediate."""
import argparse, json, os, socket, struct, sys, threading

MODESENSE = {  # gemessen an einer DroboPro (Seite 08 ist synthetisch: das Original enthaelt Firmwaredaten)
    0x01: "7a01001808021001000007ffffffff00000000000000000100000000",
    0x02: "7a02002000000f5e6813f000000000e7937c100000001045fb9000000000000000000000",
    0x06: "7a060002000b",
    0x08: "7a080004000056ff",
    0x09: "7a09000c000280000000000000000000",
    # nur mit genau passender Allokationslaenge (DroboPro: sonst keine Antwort): 03 = 8 Schaechte (gemessen, ohne Seriennummern), 05 Name, 30 Schwellen 85/95 Prozent
    0x03: "7a030241080046000000074702556000000000000000000003535438303030444d3030342d3243583138382020202020202020202020202020535438303030444d3030342d3243583100001e00004601000003a3817d6000000000000000000003535434303030444d3030302d3146323136382020202020202020202020202020535434303030444d3030302d3146323100001b00004602000003a3817d6000000000000000000003535434303030444d3030302d3146323136382020202020202020202020202020535434303030444d3030302d3146323100001b00004603000003a3817d6000000000000000000003535434303030444d3030302d3146323136382020202020202020202020202020535434303030444d3030302d3146323100001b00004604000002baa1476000000000000000000003535433303030444d3030312d3143483136362020202020202020202020202020535433303030444d3030312d3143483100001c00004605000003a3817d6000000000000000000003535434303030444d3030302d3146323136382020202020202020202020202020535434303030444d3030302d3146323100001b00004606000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004607000003a3817d6000000000000000000003535434303030444d3030302d3146323136382020202020202020202020202020535434303030444d3030302d3146323100001d00",
    0x04: "7a0400990200110000001045fb900000000000e7a3e2c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",   # gemessen (LUN 1 ist in Seite 04 leer, Seite 07 nennt beide)
    0x07: "7a04013102001100000010000000000003014003e803ea00001101000010000000000003014003e903ea000011020000100000000000000020000003ea000011030000100000000000000020000003ea000011040000100000000000000020000003ea000011050000100000000000000020000003ea000011060000100000000000000020000003ea000011070000100000000000000020000003ea00",   # Unterseite im Kopf ist 0x04 (DroboPro-Eigenheit)
    0x05: "7a0500266ad30546080044726f626f50726f000000000000000000000000000000000000000000000000",
    0x30: "7a300900555f00000000000000",
}
EXAKT = {0x03: 0x360, 0x04: 0x9D, 0x05: 0x2A, 0x07: 0x9D, 0x30: 0x0D}
a = argparse.ArgumentParser()
a.add_argument("--image", action="append", required=True)
a.add_argument("--log", required=True)
a.add_argument("--port", type=int, default=0)
a.add_argument("--iqn", default="iqn.2026-10.local.test:ziel")
a.add_argument("--drop-after", type=int)
a.add_argument("--swallow", type=int)
a.add_argument("--r2t-chunk", type=int)
a.add_argument("--max-seg", type=int, default=65536)
a.add_argument("--refuse-immediate", action="store_true", help="ImmediateData=No aushandeln (Test des Client-Schutzes)")
a.add_argument("--tolerate-no-immediate", action="store_true", help="WRITE ohne Immediate-Daten bedienen (Vorgabe: DroboPro-Verhalten, siehe unten)")
A = a.parse_args()
IQN = A.iqn
loglock = threading.Lock()

def log(**k):
    with loglock, open(A.log, "a") as f: f.write(json.dumps(k) + "\n")

class Zu(Exception): pass

def recv_n(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise Zu()
        b += c
    return b

def recv_pdu(s):
    h = recv_n(s, 48)
    ahs = h[4] * 4; n = int.from_bytes(h[5:8], "big")
    d = recv_n(s, ahs + n + (-n % 4))
    return h, d[ahs:ahs + n]

def kv(d): return dict(x.decode().split("=", 1) for x in d.split(b"\0") if b"=" in x)

class Verbindung:
    def __init__(s, sock):
        s.sock = sock; s.statsn = 0; s.cmdsn = 1; s.mrdsl = 8192; s.nbefehle = 0; s.tsih = 1; s.immediate = False

    def senden(s, op, flags, data=b"", fields=None, itt=0, lun=bytes(8), statsn=True):
        h = bytearray(48); h[0] = op; h[1] = flags; h[5:8] = len(data).to_bytes(3, "big"); h[8:16] = lun
        h[16:20] = struct.pack(">I", itt)
        if statsn:
            h[24:28] = struct.pack(">I", s.statsn); s.statsn += 1
        h[28:32] = struct.pack(">I", s.cmdsn); h[32:36] = struct.pack(">I", s.cmdsn + 32)
        for off, val in (fields or {}).items(): h[off:off + len(val)] = val
        s.sock.sendall(bytes(h) + data + b"\0" * (-len(data) % 4))

    def antwort(s, itt, status=0, sense=b"", lun=bytes(8)):
        d = (struct.pack(">H", len(sense)) + sense) if sense else b""
        s.senden(0x21, 0x80, data=d, itt=itt, fields={2: bytes([0, status])}, lun=lun)

    def check(s, itt, key, asc, ascq):
        sense = bytes([0x70, 0, key, 0, 0, 0, 0, 10, 0, 0, 0, 0, asc, ascq, 0, 0, 0, 0])
        s.antwort(itt, 2, sense)

    def datain(s, itt, lun, data, expected):
        data = data[:expected]
        parts = [data[i:i + s.mrdsl] for i in range(0, len(data), s.mrdsl)] or [b""]
        for i, p in enumerate(parts):
            last = i == len(parts) - 1
            flags = 0x80 | (0x01 if last else 0) | (0x02 if last and len(data) < expected else 0)
            f = {36: struct.pack(">I", i), 40: struct.pack(">I", i * s.mrdsl)}
            if last: f[44] = struct.pack(">I", expected - len(data))
            s.senden(0x25, flags, data=p, itt=itt, lun=lun, fields=f, statsn=last)

def serve(sock):
    v = Verbindung(sock); sess = None
    try:
        login(v)
        sess = v.sessiontype
        while True:
            h, d = recv_pdu(sock); op = h[0] & 0x3F
            v.cmdsn = struct.unpack(">I", h[24:28])[0] + (0 if h[0] & 0x40 else 1)
            if op == 0x04 and sess == "Discovery":
                body = f"TargetName={IQN}\0TargetAddress=127.0.0.1:{sock.getsockname()[1]},1\0".encode()
                v.senden(0x24, 0x80, data=body, itt=struct.unpack(">I", h[16:20])[0], fields={20: b"\xff\xff\xff\xff"})
            elif op == 0x06:
                v.senden(0x26, 0x80, itt=struct.unpack(">I", h[16:20])[0]); return
            elif op == 0x01 and sess == "Normal": scsi(v, h, d)
            elif op == 0x00: v.senden(0x20, 0x80, itt=struct.unpack(">I", h[16:20])[0], fields={20: b"\xff\xff\xff\xff"})
            else: log(ereignis="unerwartet", op=op); return
    except Zu: pass
    except (OSError, struct.error) as e: log(ereignis="fehler", text=str(e))
    finally: sock.close()

def login(v):
    runde = 0
    while True:
        h, d = recv_pdu(v.sock); assert h[0] & 0x3F == 0x03
        k = kv(d); itt = struct.unpack(">I", h[16:20])[0]; csg = (h[1] >> 2) & 3
        if "SessionType" in k: v.sessiontype = k["SessionType"]
        if csg == 0:
            runde += 1
            if runde == 1: v.senden(0x23, 0x01, data=b"AuthMethod=None\0", itt=itt, fields={8: h[8:14], 14: bytes([0, v.tsih])})   # T=0, DroboPro-Eigenheit
            else: v.senden(0x23, 0x81, itt=itt, fields={8: h[8:14], 14: bytes([0, v.tsih])})
        else:
            if "MaxRecvDataSegmentLength" in k: v.mrdsl = int(k["MaxRecvDataSegmentLength"])
            v.immediate = k.get("ImmediateData") == "Yes" and not A.refuse_immediate
            first = min(int(k.get("FirstBurstLength", 65536)), 524288)
            body = (f"HeaderDigest=None\0DataDigest=None\0MaxRecvDataSegmentLength={A.max_seg}\0InitialR2T=Yes\0ImmediateData={'Yes' if v.immediate else 'No'}\0"
                    f"MaxBurstLength=524288\0FirstBurstLength={first}\0MaxOutstandingR2T=8\0ErrorRecoveryLevel=0\0TargetPortalGroupTag=1\0").encode()
            v.senden(0x23, 0x87, data=body, itt=itt, fields={8: h[8:14], 14: bytes([0, v.tsih])})
            return

def lun_nr(l): return ((l[0] & 0x3F) << 8) | l[1]

def scsi(v, h, imm):
    itt = struct.unpack(">I", h[16:20])[0]; exp = struct.unpack(">I", h[20:24])[0]; cdb = bytes(h[32:48]); lun = bytes(h[8:16]); n = lun_nr(lun)
    v.nbefehle += 1
    log(ereignis="befehl", nr=v.nbefehle, op=cdb[0], cdb=cdb.hex(), lun=n, erwartet=exp, flags=h[1])
    if A.drop_after is not None and v.nbefehle > A.drop_after: raise Zu()
    if A.swallow == v.nbefehle: return
    op = cdb[0]
    img = A.image[n] if n < len(A.image) else None
    if op == 0xA0:
        al = struct.unpack(">I", cdb[6:10])[0]
        body = struct.pack(">I", 8 * len(A.image)) + bytes(4) + b"".join(bytes([0, i]) + bytes(6) for i in range(len(A.image)))
        return v.datain(itt, lun, body[:al], exp)
    if img is None: return v.check(itt, 5, 0x25, 0)
    size = os.path.getsize(img) // 512
    if op == 0x12:
        body = bytes([0, 0, 5, 2, 31, 0, 0, 0]) + b"DROBO   " + b"DroboPro        " + b"1.00"
        v.datain(itt, lun, body[:cdb[4]], exp)
    elif op == 0x00: v.antwort(itt, 0)
    elif op == 0xEA and cdb[1] == 0x10 and cdb[3] == 0x0F:     # LUN-Groesse setzen (Nachbildung): Daten MUESSEN im Command-PDU stehen, sonst startet die DroboPro neu
        if len(imm) != 4:
            import time; time.sleep(1); log(ereignis="ABSTURZ ea-ohne-immediate", daten=len(imm)); raise Zu()
        log(ereignis="lunsize", tib=int.from_bytes(imm, "big"), cdb=cdb.hex()); v.antwort(itt, 0)
    elif op == 0x9E and cdb[1] & 0x1F == 0x10:
        v.datain(itt, lun, struct.pack(">QI", size - 1, 512) + bytes(20), exp)
    elif op == 0x5A and cdb[2] == 0x3A:
        al = (cdb[7] << 8) | cdb[8]
        if cdb[3] in EXAKT and al != EXAKT[cdb[3]]: return log(ereignis="verschluckt", grund="modesense-laenge", alloc=al, sub=cdb[3])
        if (al > 512 and cdb[3] not in EXAKT) or cdb[3] not in MODESENSE: return log(ereignis="verschluckt", grund="modesense", alloc=al, sub=cdb[3])
        v.datain(itt, lun, bytes.fromhex(MODESENSE[cdb[3]])[:al], exp)
    elif op == 0x88:
        lba, cnt = struct.unpack(">QI", cdb[2:14])
        if lba + cnt > size: return v.check(itt, 5, 0x21, 0)
        with open(img, "rb") as f: f.seek(lba * 512); v.datain(itt, lun, f.read(cnt * 512), exp)
    elif op == 0x8A: schreiben(v, h, cdb, itt, img, size, exp, imm)
    else:
        log(ereignis="unbekannt", op=op); v.check(itt, 5, 0x20, 0)

def schreiben(v, h, cdb, itt, img, size, exp, imm):
    lba, cnt = struct.unpack(">QI", cdb[2:14]); total = cnt * 512
    log(ereignis="write", lba=lba, bytes=total, erwartet=exp, sofort=len(imm))
    if not imm and not A.tolerate_no_immediate:
        import time; time.sleep(1); log(ereignis="ABSTURZ write-ohne-immediate"); raise Zu()
    if len(imm) > A.max_seg or len(imm) > total: log(ereignis="verletzung", grund="immediate", laenge=len(imm)); raise Zu()
    if total != exp or total > 524288 or lba + cnt > size:
        return v.check(itt, 5, 0x24, 0)   # MaxBurstLength-Verletzung oder falsche Laenge: abgelehnt
    buf = bytearray(total); buf[0:len(imm)] = imm; gotten = len(imm); r2tsn = 0; ttt = 0x1000
    while gotten < total:
        piece = min(A.r2t_chunk or total, total - gotten); ttt += 1
        v.senden(0x31, 0x80, itt=itt, lun=bytes(h[8:16]), statsn=False,
                 fields={20: struct.pack(">I", ttt), 24: struct.pack(">I", v.statsn), 36: struct.pack(">I", r2tsn), 40: struct.pack(">I", gotten), 44: struct.pack(">I", piece)})
        r2tsn += 1; got = 0
        while got < piece:
            dh, dd = recv_pdu(v.sock)
            if dh[0] & 0x3F != 0x05 or struct.unpack(">I", dh[20:24])[0] != ttt or len(dd) > A.max_seg:
                log(ereignis="verletzung", op=dh[0] & 0x3F, laenge=len(dd)); raise Zu()
            off = struct.unpack(">I", dh[40:44])[0]
            if off != gotten + got or off + len(dd) > gotten + piece: log(ereignis="verletzung", grund="offset", off=off); raise Zu()
            buf[off:off + len(dd)] = dd; got += len(dd)
            log(ereignis="dataout", offset=off, laenge=len(dd))
        gotten += piece
    with open(img, "r+b") as f: f.seek(lba * 512); f.write(buf)
    v.antwort(itt, 0)

srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", A.port)); srv.listen(8)
print("PORT", srv.getsockname()[1], flush=True)
while True:
    c, _ = srv.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
