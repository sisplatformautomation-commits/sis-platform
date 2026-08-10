# Hospitality Guest Communication Assistant – Airbnb Review Only

Business Case Key: `AIRBNB_GUEST_COMM_REVIEW_ONLY`  
Version: `1.0.0`  
Canonicalization: `P3-046`  
Stand: `2026-08-10`  
Status: `active`

## Zweck

Dieser Business Case verarbeitet eingehende Airbnb-Gastkommunikation bis zu einer manuellen Review-Queue. Er ist ausdrücklich `review_only`: Analyse, Faktenprüfung und Review-Vorbereitung sind erlaubt; autonomer Versand, Buchungswrites und Zahlungswrites sind nicht Bestandteil des freigegebenen Scopes.

## Source of Truth

Supabase ist der autoritative Maschinenstatus. GitHub ist die kanonische menschenlesbare Dokumentation. Deployment- und Provider-Evidence verifizieren die laufenden DEV-/PROD-Komponenten. Mail- und Provider-Credentials werden nicht in Dokumenten oder Modellkontexten gespeichert.

## Live-Stand

- Business Case: `active`, Fortschritt `100`.
- Review-only ist aktiv.
- Produktiver Gmail-Intake läuft im registrierten Deployment alle `900` Sekunden.
- Automatischer Versand bleibt deaktiviert und ist eine separate spätere Entscheidung.
- Historisch existieren keine regulären Work Items für diesen Business Case; P3-046 stellt daher die kanonische Lineage erstmals aus Business-Case-, Deployment- und Runtime-Evidence her.

## PROD-Deployment

Deployment: `airbnb_guest_comm_prod_review`.

Registrierte Komponenten:

- Make Inbox Scheduler `6887008` — Gmail read, review-only, Intervall 900 Sekunden.
- Make Review Agent `6886943` — on-demand, review-only.
- Supabase Analyzer Edge Function `sis-guest-communication-prod`.
- Supabase Intake Edge Function `sis-guest-communication-prod-intake`.
- Control-/Review-/Policy-/Knowledge-State in Supabase.

Registrierte Connections:

- Gmail `9553277` — read-only Mailbox-Connection, healthy/passed.
- Intake/Auth-Connection für den produktiven Edge-Intake ist separat registriert.

## DEV-Evidence

- DEV Review Agent Scenario `6883005` — `DEV | SIS Airbnb Guest Communication Agent | REVIEW ONLY`.
- Shared Airbnb/Gmail Inbox Webhook `6881984` — read-only Transport-Infrastruktur.

Shared Gmail-Transport ist Infrastruktur und nicht exklusives Eigentum dieses Business Case.

## Komponenten

Die Component Registry wird für diesen Business Case mit folgenden Rollen aufgebaut:

- `AI_TEXT` — Analyse/Klassifikation und strukturierte Reasoning-Ausgabe.
- `EMAIL` — Gmail read-only Intake.
- `MAKE` — Scheduler-/Review-Workflow-Orchestrierung.
- `SUPABASE` — Intake, Analyzer, Review-Queue, Policy und Knowledge-State.
- `SECURITY_AUDIT` — Idempotenz, Policy- und Review-Evidence.

## Sicherheits- und Write-Grenzen

- `mail_write_allowed = false`.
- Kein autonomer Reply-/Send-Pfad.
- Keine Booking-/Reservation-Writes.
- Keine Payment-/Finance-Writes.
- Provider-Credentials verbleiben im Connection-/Vault-Layer.
- Eine spätere Send-Aktivierung benötigt einen separaten fachlichen, technischen und Approval-gesteuerten Ausbau.

## Aktueller nächster Schritt

Review-Qualität und Produktiv-Evidence weiter beobachten. Jede Erweiterung von `review_only` zu automatischem Versand ist ein eigener, separat zu genehmigender Work-Item-/Release-Schritt.

## Rekonstruktionshinweis

Dieses Dokument wurde in P3-046 aus Supabase Business-Case-State, PROD-Deployment-/Connection-Inventar und verifizierter DEV-Make-Evidence rekonstruiert. Der frühere Dokumentationsgap „PROD nur behauptet“ ist durch die registrierte PROD-Deployment-Evidence geschlossen.
