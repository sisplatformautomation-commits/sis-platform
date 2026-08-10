# Lexoffice Integration Hub

Business Case Key: `LEXOFFICE_HUB`  
Version: `1.0.0`  
Canonicalization: `P3-046`  
Stand: `2026-08-10`  
Status: `active`

## Zweck

`LEXOFFICE_HUB` bündelt die providerneutralen Finance-/Dokumentenadapter für Lexware, Bank-/Kontodaten und deren kontrollierte Reconciliation. Der Banking-Adapter ist von Lexware getrennt; Matching ist eine eigene Service-Schicht und führt im aktuellen Scope keine automatischen Zahlungen, Transfers oder Buchhaltungswrites aus.

## Source of Truth

Supabase ist der autoritative Maschinenstatus. GitHub ist die kanonische menschenlesbare Dokumentation. Provider-/Runtime-Evidence verifiziert externe Adapter. Secrets und Bank-/Finance-Nutzdaten gehören nicht in die kanonische Dokumentation.

## Live-Stand

- Business Case: `active`, Fortschritt `100` für den aktuellen Meilenstein.
- Work Items `LHX-001` bis `LHX-005`: `done`.
- Qonto Full-Sync: `602/602` Transaktionen verifiziert.
- Reconciliation-Live-TEST: erfolgreich; Review-Queue und Idempotenz wurden verifiziert.

## Architekturentscheidung Banking

`LHX-002` hat Qonto als initialen Banking-Provider ausgewählt.

- Provider: `qonto`.
- Initialmodus: `read_only_reconciliation`.
- Keine Transfer- oder Payment-Initiation im aktuellen Scope.
- Normalisierte Banking-Schnittstelle: Accounts, Transactions, Transaction Detail, Statements und Attachments.
- Weitere PSD2/Open-Banking-Provider können später über denselben Adaptervertrag ergänzt werden.

Damit ist die frühere Registry-Aussage „Bankanbieter offen/planned“ überholt.

## Runtime- und Connection-Evidence

Qonto:

- Make Scenario `6871294` — `LEXHUB | DEV | Qonto Read Adapter`.
- Connections `9597442` und `9595851` sind als Qonto-Verbindungen im Provider-Inventar vorhanden.
- Live Read und vollständige Pagination über sieben Seiten wurden verifiziert.

Lexware:

- Make Scenario `6871333` — `LEXHUB | DEV | Lexware Read Adapter`.
- Lexware Connection `9577049`.
- Voucherlist und Payments-Read wurden live verifiziert.
- Lexware Payments wird als Payment-Status gelesen; allgemeine Banktransaktionen stammen aus dem Banking-Adapter.

## Komponenten

- `BANKING` — aktiver providerneutraler Bank-/Konto-Adapter; initial Qonto read-only.
- `LEXOFFICE` — Lexware/Lexoffice Read- und Dokumentadapter.
- `MAKE` — Workflow-Orchestrierung.
- `SUPABASE` — Reconciliation-State, Review-Queue und Audit-State.
- `SECURITY_AUDIT` — Idempotenz, Evidence und Review-Gates.
- `EMAIL` — optionaler Dokument-/Mailbox-Eingang je Deployment.

`GDRIVE` ist nur `legacy_optional` und keine Core-Abhängigkeit der SIS-R4-Architektur.

## Sicherheits- und Write-Grenzen

- Automatische finanzielle Writes sind deaktiviert.
- Matching erzeugt Evidence/Audit und Review-Kandidaten, keine Zahlung oder Buchung.
- Qonto- und Lexware-Credentials verbleiben in den jeweiligen Provider-Connections/Vaults.
- Provider-Writes und externe Finanzwrites benötigen separate Capability-/Approval-Gates.

## Aktueller nächster Schritt

Für den abgeschlossenen aktuellen Meilenstein besteht kein offener Implementierungsblocker. Ein nächster Ausbau ist separat zu definieren. Die Qonto-Pagination sollte dynamisch gehärtet werden, falls der Bestand über die aktuell verifizierten sieben Seiten wächst.

## Rekonstruktionshinweis

Dieses Dokument wurde in P3-046 aus Supabase Work-Item-State, Reconciliation-Evidence und verifiziertem Make-Inventar rekonstruiert. Die Registry wird auf Qonto als ausgewählten read-only Banking-Adapter und Google Drive als Legacy-/optional Connector korrigiert.
