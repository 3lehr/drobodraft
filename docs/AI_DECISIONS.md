# AI-Entscheidungen

## 2026-10-18 — BB-P01: Matching vor Laufzeitprüfung

Kontext: v0.3 erzeugt den SCSI-Familiencontroller per `IOService::Create`.
Die Panic-Analyse im DriverKit-Plan belegt den übersprungenen Kernel-Start und
NULL-Provider bei Terminierung (L-d7b25d).
Gewählt: den bereits geplanten v0.4-Ansatz implementieren: registrierte
IOUserService-Wurzel mit Nub-Kennung, eigenständige Matching-Personality.
Verworfen: manuellen Create/Terminate-Pfad weiter reparieren; er garantiert
keinen Kernel-Start. Ein Quellguard im normalen Baupfad verhindert Rückkehr.
Prüfung: Guard rot gegen den unveränderten v0.3-Stand, danach grün plus
signierter Build; genaue Resultate stehen im kanonischen Plan und AI_HANDOFF.
Grenze: statische Prüfung/Build beweisen weder Kernel-Matching noch sicheren
Stop. Keine VM vorhanden (`utmctl list` leer); keine Aktivierung am Host.
