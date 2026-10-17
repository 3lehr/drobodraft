#!/usr/bin/env python3
"""Findet Oberflaechentexte ohne Eintrag in Localizable.xcstrings (fest verdrahtet = in der englischen Oberflaeche deutsch).
Geprueft werden woertliche Zeichenketten in Text/Label/Button/Section/Toggle/Picker/LabeledContent/Menu, in text:/titel:/name:-Argumenten der Bausteine
(Hinweis, Karte, Zeile), in String(localized:), navigationTitle und accessibilityLabel/Hint/Value. Interpolation \\(...) zaehlt als %@ (oder %lld/%d/%f).
Ausnahme einer Zeile: Kommentar `lint-text: ok`. Exit 1 bei Treffern."""
import json, re, sys, pathlib

app = pathlib.Path(__file__).resolve().parent.parent / "App"
def spez(k): return re.sub(r"%(?:\d+\$)?(?:\.\d+)?(?:lld|ld|d|f|lf|@)", "%@", k)   # alle Platzhalterarten gelten als gleich
keys = {spez(k) for k in json.load(open(app / "Localizable.xcstrings", encoding="utf-8"))["strings"]}
muster = re.compile(r'(?:\b(?:Text|Label|Button|Section|Toggle|Picker|LabeledContent|Menu|TextField|SecureField|Link|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|help)\(\s*|String\(localized:\s*|Zeile\(name:\s*|\b(?:text|titel|kurz|wort):\s*)"')

def literal(z, i):
    """Zeichenkette ab z[i] (hinter dem oeffnenden Anfuehrungszeichen), Interpolation samt verschachtelter Zeichenketten; None = nicht abgeschlossen."""
    out = ""
    while i < len(z):
        c = z[i]
        if c == '"': return out
        if z.startswith("\\(", i):
            t, j = 1, i + 2
            while j < len(z) and t:
                if z[j] == '"':
                    j += 1
                    while j < len(z) and z[j] != '"': j += 2 if z[j] == "\\" else 1
                t += (z[j] == "(") - (z[j] == ")"); j += 1
            out += z[i:j]; i = j
        elif c == "\\": out += z[i:i + 2]; i += 2
        else: out += c; i += 1
    return None

def normal(s):
    out, i = "", 0
    while i < len(s):
        if s.startswith("\\(", i):
            t, j = 1, i + 2
            while j < len(s) and t:
                if s[j] == '"':
                    j += 1
                    while j < len(s) and s[j] != '"': j += 2 if s[j] == "\\" else 1
                t += (s[j] == "(") - (s[j] == ")"); j += 1
            out += "%@"; i = j
        elif s.startswith("\\n", i): out += "\n"; i += 2
        elif s.startswith('\\"', i): out += '"'; i += 2
        else: out += "%%" if s[i] == "%" else s[i]; i += 1
    return out

def gefunden(roh):
    n = normal(roh)
    if n.strip() == "" or not re.search(r"[A-Za-zÄÖÜäöüß]", n): return True
    return n in keys

def pruefe(pfade):
    fehler = []
    for p in pfade:
        for nr, z in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if "lint-text: ok" in z or z.lstrip().startswith("//"): continue
            # Ein String-Wert im Modell wird nicht uebersetzt, wenn er als blankes Literal steht (Text(String) lokalisiert nicht): String(localized:) verlangen.
            if re.search(r'@Published var \w+(?:: String)? = "[^"]*[A-Za-zÄÖÜäöüß]', z): fehler.append(f"{p.name}:{nr}: published String literal needs String(localized:)")
            for m in muster.finditer(z):
                lit = literal(z, m.end())
                if lit is not None and not gefunden(lit): fehler.append(f"{p.name}:{nr}: {lit!r}")
    return fehler

if __name__ == "__main__":
    f = pruefe(sorted(app.glob("*.swift")))
    print("\n".join(f)); print(f"{len(f)} unlocalized UI strings")
    sys.exit(1 if f else 0)
