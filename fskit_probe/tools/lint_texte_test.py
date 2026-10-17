#!/usr/bin/env python3
"""Kontrollen fuer lint_texte.py: Positivkontrolle (fehlender Schluessel wird gefunden) und Negativkontrollen (vorhandene, interpolierte, %-haltige Schluessel nicht)."""
import pathlib, tempfile, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import lint_texte as L

def lauf(code):
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d) / "T.swift"; p.write_text(code, encoding="utf-8"); return L.pruefe([p])

assert lauf('Text("Gibt es garantiert nicht xyz")'), "fehlender Schluessel muss auffallen"
assert lauf('Hinweis(symbol: "x", text: "Gibt es garantiert nicht xyz")'), "text:-Argument"
assert lauf('Button("Hinzufügen") {}') == [] and lauf('Text("Gibt es garantiert nicht")  // lint-text: ok') == []
assert lauf('Text("Physisch frei: \\(groesseText(k.frei)) (\\(Int(x)) %)")') == [], "Platzhalterarten und %% sind gleich"
assert lauf('@Published var a = "unbekannt"'), "blankes Literal im Modell"
assert lauf('@Published var a = String(localized: "unbekannt")') == [] and lauf('@Published var a = ""') == []
assert lauf('Zeile(name: "Garantiert nicht vorhanden", wert: x)'), "Zeile(name:)"
assert lauf('DroboEintrag(uuid: u, name: "Garantiert nicht vorhanden")') == [], "name: anderer Aufrufer ist kein UI-Text"
assert lauf('Text("12:30")') == [], "ohne Buchstaben kein Text"
print("lint_texte: Kontrollen ok")
