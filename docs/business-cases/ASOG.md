# ASOG Document Intake Assistant

Business Case Key: `ASOG`  
Version: `1.0.0`  
Canonicalization: `P3-046`  
Stand: `2026-08-10`  
Status: `active`

## Zweck

ASOG ist der SIS Business Case für den dokumentbasierten Eingangsprozess mit Mail-/Dateiannahme, KI-gestützter Dokumentanalyse und der kontrollierten Übergabe an Buchhaltungs- bzw. Dokumentensysteme. Die fachliche Capability bleibt vom konkreten Provider getrennt; Make ist Workflow-Orchestrierung, Lexware ein Adapter/Zielsystem und Gmail ein Eingangsadapter.

## Source of Truth

Für diesen Stand gilt die SIS-R4-Reihenfolge:

1. Supabase Control Plane = autoritativer Maschinenstatus.
2. GitHub = kanonische menschenlesbare Dokumentation.
3. Supabase Storage = private Binärartefakte.
4. Provider-/Runtime-Evidence = externe Verifikation.
5. Chat-Historie = sekundärer Kontext.

Google Drive ist keine SIS-Core-Abhängigkeit. Eine Nutzung ist nur als Legacy-/optionaler Connector zulässig.

## Live-Stand

- Business Case: `active`, Fortschritt `92`.
- Health: `healthy`.
- Relevante Work Items: `E-004`, `E-004-safe-pdf-patch`, `make-control-bridge`, `PLAT-001` abgeschlossen; `make-integration-setup` historisch abgebrochen/superseded.
- Der sichere PDF-File-Input-Test wurde erfolgreich mit einem ca. 166 KB großen PDF durchgeführt; das temporäre Szenario wurde danach entfernt.
- Das gemeinsame Umgebungsmodell lautet `SIS DEV / SIS TEST / SIS PROD`.

## Runtime- und Provider-Evidence

- DEV Make Scenario: `6865012` — `DEV | ASOG Eingangsbeleg-Agent OPENAI (Mail -> Lexoffice)`.
- TEST Scenario aus `PLAT-001`: `6865005`.
- PROD Scenario aus `PLAT-001`: `6851108`.
- Der P3-046 Make-Inventory-Lauf verifizierte den DEV-Szenarioeintrag read-only.
- Lexware Office ist als fachlicher Adapter Bestandteil des Business Case; konkrete Connection-Bindings werden deployment-/environment-spezifisch aufgelöst und nicht im kanonischen Workflow hart codiert.

## Komponenten

Aktive/kanonische Rollen:

- `AI_DOC` — Dokumentklassifikation, Extraktion und strukturierte Entscheidung.
- `EMAIL` — Eingangs-/Mailbox-Adapter.
- `LEXOFFICE` — Buchhaltungs-/Dokumentenadapter.
- `MAKE` — technische Workflow-Orchestrierung.
- `SECURITY_AUDIT` — Approval, Idempotenz und Audit.
- `SUPABASE` — Control Plane, Status und sichere Provider-Gates.

`GDRIVE` ist nur `legacy_optional` und keine Core-Abhängigkeit.

## Sicherheits- und Write-Grenzen

- Provider- und Finance-Writes unterliegen den jeweils geltenden Approval-Gates.
- Provider-IDs werden nicht als frei steuerbare Modellparameter verwendet.
- Secrets verbleiben im jeweiligen Provider-/Vault-Kontext und werden nicht in Chat, GitHub oder Control-Plane-Dokumenttexte geschrieben.
- Produktive Änderungen werden nicht aus diesem Dokument abgeleitet; der Maschinenstatus in Supabase bleibt maßgeblich.

## Aktueller nächster Schritt

DEV/TEST können über die gehärteten SIS Provider-/Runtime-Gates weitergeführt werden. PROD-Schreibaktionen bleiben separat approval-pflichtig. Registry und Dokumentation sind nach Architekturänderungen synchron zu halten.

## Rekonstruktionshinweis

Dieses Dokument wurde in P3-046 aus Supabase-Live-State, verifizierter Make-Evidence und der kanonischen SIS-R4-Architektur rekonstruiert. Historische Drive-Referenzen sind für den aktuellen Maschinenstatus nicht maßgeblich.
