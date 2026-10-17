#!/usr/bin/env python3
"""Lokalisierung zur Laufzeit: die gestartete App (Debug, Demo, eigene Instanz, unsichtbar) findet JEDEN Schluessel des Katalogs und liefert in Englisch den englischen Text
(GET /text?k=). Faengt Schluessel, die im Katalog und im Quelltext auseinanderlaufen (z. B. nach dem Wechsel von Sie auf du). Kein Kontakt zu einer echten Drobo.
Aufruf: lokalisierung_test.py [Pfad zur DroboFSProbe-Binary]"""
import json, os, re, pathlib, signal, subprocess, sys, tempfile, time, urllib.parse, urllib.request
sys.argv = [sys.argv[0]] + sys.argv[1:]
APP = sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/drobo_dd/Build/Products/Debug/DroboFSProbe.app/Contents/MacOS/DroboFSProbe"
katalog = json.load(open(pathlib.Path(__file__).resolve().parent.parent / "App" / "Localizable.xcstrings", encoding="utf-8"))["strings"]

def lauf(sprache):
    import socket
    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    daten = tempfile.mkdtemp(prefix="drobo_lok_", dir=os.environ.get("TMPDIR", "/private/tmp"))
    env = dict(os.environ, DROBO_DEMO_HINTEN="1", DROBO_DEMO="5c", DROBO_DATEN=daten, DROBO_STEUERUNG=str(port))
    p = subprocess.Popen([APP, "-AppleLanguages", f"({sprache})"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try: urllib.request.urlopen(f"http://127.0.0.1:{port}/aktionen", timeout=2); break
        except Exception: time.sleep(0.5)
    else: p.kill(); raise SystemExit("Steuerung antwortet nicht")
    return p, port

def text(port, k): return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/text?k=" + urllib.parse.quote(k, safe=""), timeout=5))["text"]

fehler = []
for sprache in ("en", "de"):
    p, port = lauf(sprache)
    try:
        n = 0
        for k, v in katalog.items():
            soll = v.get("localizations", {}).get(sprache, {}).get("stringUnit", {}).get("value")
            if soll is None: continue
            n += 1; ist = text(port, k)
            # Quellsprache: fehlt der Eintrag im uebersetzten Katalog, gilt der Schluessel selbst (gleicher Text bis auf Positionsangaben %1$@)
            if sprache == "de" and ist == "«fehlt»" and re.sub(r"%\d+\$", "%", soll) == k: continue
            if ist != soll: fehler.append((sprache, k[:70], ist[:70], soll[:70]))
        print(f"{sprache}: {n} Schluessel geprueft")
    finally:
        p.send_signal(signal.SIGTERM); time.sleep(0.5)
        if p.poll() is None: p.kill()
for f in fehler[:20]: print("FAIL ", f)
print("ALLES GRUEN" if not fehler else f"{len(fehler)} FEHLER")
sys.exit(1 if fehler else 0)
