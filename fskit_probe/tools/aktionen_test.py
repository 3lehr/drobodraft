#!/usr/bin/env python3
"""Test der Steuerung per Text (Debug-Bau, Demo): Aktionskatalog gegen die ECHTE Menueleiste.
Prueft: (1) jede Aktion steht im Menue (Pfad), (2) kein Kuerzel doppelt (Katalog und Menue), (3) jede datenaendernde Aktion hat Undo,
(4) Ausfuehren + Rueckgaengig = unveraendert (Zustand UND Datei einstellungen.json), (5) Schreib-/Format-/Zurueckspiel-Aktionen haben kein Kuerzel.
Eigene Instanz: DROBO_DEMO, eigener DROBO_DATEN, eigener Port, Beenden per eigener PID. Kein Kontakt zu einer echten Drobo.
Aufruf: aktionen_test.py [Pfad zur DroboFSProbe-Binary]  (Vorgabe /private/tmp/drobo_dd/Build/Products/Debug/DroboFSProbe.app/Contents/MacOS/DroboFSProbe)"""
import json, os, signal, socket, subprocess, sys, tempfile, time, urllib.request

APP = sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/drobo_dd/Build/Products/Debug/DroboFSProbe.app/Contents/MacOS/DroboFSProbe"
OHNE_KUERZEL = ["einhaengenSchreiben", "neuSchreiben", "formatieren", "zurueckspielen"]
fehler = []

def pruefe(ok, text):
    print(("PASS  " if ok else "FAIL  ") + text)
    if not ok: fehler.append(text)

def norm(s): return s.replace(" …", "…").replace("...", "…")

def frei_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def start(demo="beide", daten=None, extra=None):
    daten = daten or tempfile.mkdtemp(prefix="drobo_aktionen_", dir=os.environ.get("TMPDIR", "/private/tmp"))
    port = frei_port()
    env = dict(os.environ, DROBO_DEMO_HINTEN="1", DROBO_DEMO=demo, DROBO_DATEN=daten, DROBO_STEUERUNG=str(port), **(extra or {}))
    p = subprocess.Popen([APP], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try:
            holen(port, "/aktionen"); return p, port, daten
        except Exception: time.sleep(0.5)
    p.kill(); raise SystemExit("Steuerung antwortet nicht")

def holen(port, pfad, post=False):
    r = urllib.request.Request(f"http://127.0.0.1:{port}{pfad}", method="POST" if post else "GET", data=b"" if post else None)
    return json.loads(urllib.request.urlopen(r, timeout=10).read())

def beenden(p):
    p.send_signal(signal.SIGTERM); time.sleep(0.5)
    if p.poll() is None: p.kill()

def blatt_test():
    """Schreib- und Formatblatt: Blattart je Ausloeser, 15-s-Sperre (nicht umgehbar, nur die Uhr verstellbar), Bestaetigung wird gemerkt."""
    p, port, daten = start("pro", extra={"DROBO_DEMO_ANSCHLUSS": "wlan"})
    try:
        get = lambda x: holen(port, x); post = lambda x: holen(port, x, True)
        post("/aktion?id=sicherungsortWaehlen&arg=/private/tmp/drobo_aktionen_ziel")
        post("/aktion?id=einhaengenSchreiben"); z = get("/zustand")
        pruefe(z["blatt_art"] == "voll:erstmals", f"erstes Mal: volles Blatt ({z['blatt_art']})")
        pruefe(13 <= z["sperre_rest"] <= 15, f"Sperre laeuft: noch {z['sperre_rest']} s")
        r = post("/bestaetigen"); pruefe(not r["ok"] and "noch" in (r["fehler"] or ""), f"Bestaetigen waehrend der Sperre abgelehnt: {r['fehler']}")
        post("/uhr?versatz=14"); pruefe(get("/zustand")["sperre_rest"] == 1, "bei 14 s noch 1 s gesperrt"); pruefe(not post("/bestaetigen")["ok"], "bei 14 s weiter gesperrt")
        post("/uhr?versatz=15"); pruefe(get("/zustand")["sperre_rest"] == 0, "bei 15 s frei")
        r = post("/bestaetigen"); pruefe(r["ok"], f"nach der Sperre bestaetigt ({r['fehler']})")
        z = get("/zustand"); pruefe(z["blatt"] is None and len(z["bestaetigt"]) == 1, "Blatt zu, Kombination gemerkt")
        post("/uhr?versatz=0"); post("/aktion?id=einhaengenSchreiben"); z = get("/zustand")
        pruefe(z["blatt_art"] == "kurz" and z["sperre_rest"] == 0, f"Wiederholung gleiche Kombination: kurzes Blatt ohne Sperre ({z['blatt_art']}, {z['sperre_rest']})")
        pruefe(post("/bestaetigen")["ok"], "kurzes Blatt sofort bestaetigt")
        post("/aktion?id=formatieren"); z = get("/zustand")
        pruefe(z["blatt_art"] == "voll:formatieren" and z["sperre_rest"] >= 13, "Formatieren: immer volles Blatt mit Sperre")
        pruefe(not post("/bestaetigen")["ok"], "Formatieren waehrend der Sperre abgelehnt")
        post("/uhr?versatz=16"); pruefe(not post("/bestaetigen?name=a:b")["ok"], "ungueltiger Name abgelehnt (Doppelpunkt)")
        pruefe(post("/bestaetigen?name=NEU")["ok"], "Formatieren nach Sperre mit gueltigem Namen")
        post("/uhr?versatz=0")
    finally: beenden(p)
    # Neustart mit gleichem Datenordner und anderem Anschluss: Kabel ist nicht erprobt -> volles Blatt, Kaestchen noetig
    p, port, daten = start("pro", daten, {"DROBO_DEMO_ANSCHLUSS": "kabel"})
    try:
        get = lambda x: holen(port, x); post = lambda x: holen(port, x, True)
        post("/aktion?id=sicherungsortWaehlen&arg=/private/tmp/drobo_aktionen_ziel")
        post("/aktion?id=einhaengenSchreiben"); z = get("/zustand")
        pruefe(z["blatt_art"] == "voll:nichtErprobt" and len(z["bestaetigt"]) == 1, f"Kabel: nicht erprobt = volles Blatt trotz frueherer Bestaetigung ({z['blatt_art']})")
        post("/uhr?versatz=16"); z2 = get("/zustand"); r = post("/bestaetigen"); pruefe(not r["ok"], f"ohne Sicherungs-Kaestchen abgelehnt: {r['fehler']} (vorher: art={z2['blatt_art']} gesichert={z2['gesichert']} blatt={z2['blatt']} auswahl={z2['auswahl']})")
        post("/gesichert?an=1"); pruefe(post("/bestaetigen")["ok"], "mit Kaestchen nach der Sperre bestaetigt")
    finally: beenden(p)

def main():
    p, port, daten = start()
    try:
        get = lambda x: holen(port, x); post = lambda x: holen(port, x, True)
        aktionen = get("/aktionen"); menue = get("/menue")
        pruefe(len(aktionen) > 20, f"Katalog hat {len(aktionen)} Aktionen")
        for a in aktionen: pruefe(set(["id", "titel", "menue", "kuerzel", "aendert_daten", "undo"]) <= set(a), f"Zeile vollstaendig: {a['id']}")
        echte = {norm(m["pfad"]) for m in menue}
        for a in aktionen: pruefe(norm(a["menue"]) in echte, f"Menue enthaelt: {a['menue']}")
        ks = [a["kuerzel"] for a in aktionen if a["kuerzel"]]
        pruefe(len(ks) == len(set(ks)), "kein Kuerzel doppelt im Katalog: " + str([k for k in set(ks) if ks.count(k) > 1]))
        mk = [m["kuerzel"] for m in menue if m["kuerzel"]]
        pruefe(len(mk) == len(set(mk)), "kein Kuerzel doppelt in der echten Menueleiste: " + str([k for k in set(mk) if mk.count(k) > 1]))
        echt_k = {norm(m["pfad"]): m["kuerzel"] for m in menue}
        for a in aktionen:
            if a["kuerzel"] and norm(a["menue"]) in echt_k: pruefe(echt_k[norm(a["menue"])] == a["kuerzel"], f"Kuerzel im Menue = Katalog: {a['id']} {a['kuerzel']}")
        for a in aktionen: pruefe(not a["aendert_daten"] or a["undo"], f"datenaendernde Aktion hat Undo: {a['id']}")
        for i in OHNE_KUERZEL: pruefe(next(a for a in aktionen if a["id"] == i)["kuerzel"] is None, f"bewusst ohne Kuerzel: {i}")
        # Ausfuehren + Rueckgaengig = unveraendert
        datei = os.path.join(daten, "einstellungen.json")
        def stand():
            e = get("/zustand")["einstellungen"]
            d = json.load(open(datei)) if os.path.exists(datei) else None   # Datei kann vor der ersten Aenderung fehlen; danach muss sie dem Zustand entsprechen
            if d is not None: pruefe(d == e, "Datei einstellungen.json entspricht dem Zustand")
            return json.dumps(e, sort_keys=True)
        for a in [x for x in aktionen if x["aendert_daten"]]:
            if not a["aktiv"]: print(f"SKIP  {a['id']}: im Demo nicht ausfuehrbar (nichts Gefundenes)"); continue
            arg = {"umbenennen": "Testname", "sicherungsortWaehlen": "/private/tmp/drobo_aktionen_ziel"}.get(a["id"], "")
            vor = stand()
            r = post(f"/aktion?id={a['id']}&arg={arg}")
            pruefe(r["ok"], f"{a['id']}: ausgefuehrt ({r.get('fehler')})")
            nach = stand()
            pruefe(nach != vor, f"{a['id']}: Zustand hat sich geaendert (sonst waere der Test leer)")
            pruefe(get("/zustand")["kann_undo"], f"{a['id']}: Undo vorhanden")
            post("/undo")
            pruefe(stand() == vor, f"{a['id']}: nach Undo unveraendert (Zustand und Datei)")
            post("/redo")
            pruefe(stand() == nach, f"{a['id']}: Redo stellt die Aenderung wieder her")
            post("/undo")
            pruefe(stand() == vor, f"{a['id']}: zweites Undo wieder unveraendert")
        # Navigation ueber die Steuerung
        post("/aktion?id=geheTempo"); pruefe(get("/zustand")["abschnitt"] == "Tempo", "geheTempo wechselt den Bereich")
        # Blatt-Aktion ohne Kuerzel oeffnet das Bestaetigungsblatt (nur eines)
        post("/aktion?id=geheUebersicht"); r = post("/aktion?id=umbenennen")
        pruefe(get("/zustand")["blatt"] is not None, "Umbenennen ohne arg oeffnet das Blatt")
        r = post("/aktion?id=einhaengenSchreiben"); pruefe(not r["ok"], "zweites Blatt wird abgelehnt (hoechstens ein Blatt)")
    finally: beenden(p)
    blatt_test()
    print(f"\n{'ALLES GRUEN' if not fehler else str(len(fehler)) + ' FEHLER'}")
    sys.exit(1 if fehler else 0)

main()
