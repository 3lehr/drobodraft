#!/usr/bin/env python3
"""Decodiert das Dext-Log (MaxWriteProbe: 3b ERGEBNIS / HEX) nach docs/DROBO_PROTOKOLL_RECON_2026-10-14.md.
Aufruf: /usr/bin/log show --start "<Zeit>" --info --debug --predicate 'process == "kernel" AND eventMessage CONTAINS "MaxWriteProbe"' | tools/drobo_decode.py
Unbelegte Felder werden roh (hex) ausgegeben, nichts wird gedeutet. Selbsttest: tools/drobo_decode.py --selftest"""
import re, struct, sys

def u(b, o, n): return int.from_bytes(b[o:o+n], "big")
def s(b, o, n): return b[o:o+n].split(b"\0")[0].decode("ascii", "replace")

def d_protocol(b): return f"Major={b[4]} Minor={b[5]}" if len(b) >= 6 else "zu kurz"
def d_config(b):
    return f"Slots={b[4]} maxLUNs={b[6]} maxLUNGroesse={u(b,7,8)} Demo={u(b,0x10,4)} Scale={u(b,0x14,4)} readonly={u(b,0x18,4)}"
def d_capacity(b):
    return f"frei={u(b,4,8)} benutzt={u(b,0xC,8)} gesamt_geschuetzt={u(b,0x14,8)} gesamt_ungeschuetzt={u(b,0x1C,8)} (Einheit unbelegt, roh)"
def d_status(b):
    r = f"StatusBits=0x{u(b,4,4):08x} relayoutCnt={u(b,8,4)} diskPackStatus=0x{u(b,0xC,4):08x}"
    if len(b) >= 0x14: r += f" doubleDegradedCnt={u(b,0x10,4)}"
    if len(b) >= 0x18: r += f" unbenannt+0x14=0x{u(b,0x14,4):08x}"
    return r
def d_fw(b): return f"+4=0x{b[4]:02x} +5=0x{b[5]:02x} Build={u(b,6,2)} +8=0x{b[8]:02x} +9=0x{b[9]:02x} Version='{s(b,0xA,32)}'"
def d_sys(b): return f"UpTime={u(b,8,4)} Temperatur={u(b,0xC,4)} (Einheiten unbelegt) +0x10=0x{u(b,0x10,4):08x}" if len(b) >= 0x14 else "zu kurz"
def d_slot(b):
    n = b[8]; out = [f"Slotanzahl={n} Satzgroesse(+9)={b[9]}"]
    for i in range(n):
        o = 0xC + i*0x6C
        if o + 0x6C > len(b): out.append(f"  Satz {i}: abgeschnitten"); break
        r = b[o:o+0x6C]
        out.append(f"  Slot-Id={r[0]} Status=0x{r[1]:02x} Fehlerzaehler={u(r,2,2)} DiskZustand=0x{u(r,4,4):08x} Typ={r[8]} Temp={r[9]} Restleben={r[0xA]} Drehzahl={r[0xB]} "
                   f"str1='{s(r,0xC,44)}' str2='{s(r,0x38,12)}' str3='{s(r,0x44,24)}' Kap={u(r,0x5C,8)} verwaltet={u(r,0x64,8)}")
    return "\n".join(out)

PAGES = {0x06: d_protocol, 0x01: d_config, 0x02: d_capacity, 0x09: d_status, 0x08: d_fw, 0x33: d_sys, 0x35: d_slot}

def main(text):
    res, hexl = {}, {}
    for l in text.splitlines():
        m = re.search(r"3b ERGEBNIS shot=(\d+) (.*)", l)
        if m: res[int(m[1])] = m[2]
        m = re.search(r"3b HEX shot=(\d+) off=(\d+) ([0-9a-f]*)", l)
        if m: hexl.setdefault(int(m[1]), {})[int(m[2])] = m[3]
    for n in sorted(res):
        print(f"[{n}] {res[n]}")
        data = b"".join(bytes.fromhex(hexl[n][o]) for o in sorted(hexl.get(n, {})))
        m = re.search(r"bytes=(\d+)", res[n]); 
        if not data: continue
        if data[0] == 0x7A and len(data) >= 2 and data[1] in PAGES:
            print("    " + PAGES[data[1]](data).replace("\n", "\n    "))
        elif "VPD" in res[n]: print(f"    VPD: seite=0x{data[1]:02x} seriennummer='{s(data,4,data[3])}'" if len(data) > 4 else "    zu kurz")
        elif "INQUIRY" in res[n]: print(f"    PDT=0x{data[0]:02x} Vendor='{data[8:16].decode('ascii','replace').strip()}' Product='{data[16:32].decode('ascii','replace').strip()}' Rev='{data[32:36].decode('ascii','replace').strip()}'")
        else: print("    roh: " + data.hex())

def selftest():
    sl = bytearray(0xC + 0x6C*2); sl[0]=0x7A; sl[1]=0x35; sl[8]=2; sl[9]=0x6C
    for i in range(2):
        o = 0xC+i*0x6C; sl[o]=i; sl[o+1]=1; sl[o+2:o+4]=(3).to_bytes(2,"big"); sl[o+9]=35+i; sl[o+0x5C:o+0x64]=(1000*(i+1)).to_bytes(8,"big"); sl[o+0xC:o+0xC+4]=b"ACME"
    cap = bytearray(0x24); cap[0]=0x7A; cap[1]=2; cap[4:12]=(111).to_bytes(8,"big"); cap[0xC:0x14]=(222).to_bytes(8,"big")
    fw = bytearray(0x2A); fw[0]=0x7A; fw[1]=8; fw[6:8]=(1234).to_bytes(2,"big"); fw[0xA:0xA+5]=b"4.1.0"
    log = ""
    for n, d in ((9, sl), (5, cap), (7, fw)):
        log += f"x MaxWriteProbe: 3b ERGEBNIS shot={n} test ret=0x0 bytes={len(d)}\n"
        for off in range(0, len(d), 64): log += f"x MaxWriteProbe: 3b HEX shot={n} off={off} {bytes(d[off:off+64]).hex()}\n"
    import io, contextlib
    b = io.StringIO()
    with contextlib.redirect_stdout(b): main(log)
    o = b.getvalue()
    assert "frei=111 benutzt=222" in o and "Version='4.1.0'" in o and "Build=1234" in o
    assert "Slot-Id=1 Status=0x01 Fehlerzaehler=3" in o and "Temp=36" in o and "Kap=2000" in o and "str1='ACME'" in o
    print("selftest ok")

if __name__ == "__main__":
    selftest() if "--selftest" in sys.argv else main(sys.stdin.read())
