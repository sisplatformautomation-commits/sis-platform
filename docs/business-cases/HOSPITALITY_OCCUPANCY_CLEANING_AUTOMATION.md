# Hospitality Occupancy & Cleaning Automation

Business Case Key: `HOSPITALITY_OCCUPANCY_CLEANING_AUTOMATION`  
Version: `1.0.0`  
Canonicalization: `P3-046`  
Stand: `2026-08-10`  
Status: `active`

## Zweck

Dieser Business Case bildet einen providerneutralen Hospitality-Core für Reservierungsereignisse, Belegung, Turnover/Reinigung und spätere Benachrichtigungen der Reinigungskraft. Airbnb, Booking.com, Direct Booking und weitere Quellen werden als Adapter angebunden; die Fachlogik bleibt providerneutral.

## Source of Truth

Supabase ist der autoritative Maschinenstatus. GitHub ist die kanonische menschenlesbare Dokumentation. Externe Provider-/Runtime-Evidence dient nur zur Verifikation. Historische Drive-/Handoff-Referenzen sind keine SIS-Core-Abhängigkeit und überschreiben den Live-State nicht.

## Live-Stand

- Business Case: `active`, Fortschritt `55`.
- `HOC-001`: Mailmuster für Reservation Events analysiert — `done`.
- `HOC-002`: providerneutrales Occupancy-Datenmodell — `done`.
- `HOC-003`: Airbnb-Mailparser und historischer Backfill — `in_progress`.
- `HOC-004`: Cleaning-/Turnover-Engine — `done`.
- `HOC-005`: Cleaner Assignment/Notification Adapter — `planned`.
- `HOC-006`: Booking.com Adapter — `planned`.
- `HOC-007`: Google-Calendar-Sync — `planned`.

## Providerneutraler Supabase-Core

Verifizierte DEV-Tabellen:

- `sis_hospitality_properties_dev`
- `sis_hospitality_reservation_events_dev`
- `sis_hospitality_reservations_dev`
- `sis_hospitality_cleaning_tasks_dev`

Verifizierte Funktionen/Logik:

- `sis_hospitality_apply_reservation_event_dev`
- `sis_hospitality_recompute_cleaning_task_dev`
- `sis_hospitality_recompute_property_cleaning_dev`
- Parser `sis_hospitality_parse_airbnb_mail_dev`

Die Cleaning-Engine wurde u. a. für Same-Day Turnover, hohe Same-Day-Priorität, idempotente Task-Updates, Reservierungsverschiebungen und Storno-Recompute regressionsgetestet.

## Mailbox-/Provider-Boundary

- Referenzierte Gmail Connection: `9553277`.
- Diese Connection ist Shared-Connector-Infrastruktur für denselben Kunden/dasselbe Environment und kein exklusives Business-Case-Eigentum.
- Aktuell ist im verifizierten P3-046 DEV-Make-Inventar **kein dediziertes HOC Make Scenario** eindeutig belegt.
- Deshalb wird für HOC kein Make-Runtime-Szenario erfunden oder aus Shared-Gmail-Szenarien abgeleitet.
- `HOC-003` bleibt offen, bis der echte Gmail-Backfill über den Parser ausgeführt und evidenzbasiert abgeschlossen ist.

## Komponenten

Die Component Registry wird für den aktuellen, evidenzbasierten Scope mit folgenden Rollen aufgebaut:

- `EMAIL` — Shared Gmail read-only Reservation-Event-Quelle.
- `SUPABASE` — providerneutraler Occupancy-/Cleaning-State und interne Verarbeitung.
- `SECURITY_AUDIT` — Idempotenz, Event-Lineage und kontrollierte Statusänderungen.

`MAKE` wird erst als Business-Case-Komponente gebunden, wenn ein dedizierter HOC-Workflow oder eine explizite Shared-Workflow-Zuordnung technisch verifiziert ist. Benachrichtigungs- und Kalenderkomponenten bleiben bis zu den geplanten HOC-005/HOC-007-Schritten deaktiviert.

## Sicherheits- und Write-Grenzen

- `external_writes_enabled = false`.
- Cleaner Notifications sind nicht aktiviert.
- Calendar Writes sind nicht aktiviert.
- Kein autonomer Nachrichtenversand.
- Provider-/Mailbox-Credentials verbleiben im Connection-/Vault-Layer.
- Booking-/Payment-/Finance-Writes sind nicht Teil des aktuellen Scopes.

## Aktueller nächster Schritt

Die verifizierte GmbH-Gmail-Read-Connection ist an den Parser-/Backfill-Pfad anzubinden und der historische Airbnb-Backfill ist kontrolliert auszuführen. Danach kann `HOC-003` abgeschlossen werden. Erst anschließend folgen HOC-005 bis HOC-007 als separate Work Items mit eigenen Write-/Notification-Gates.

## Rekonstruktionshinweis

Dieses Dokument wurde in P3-046 aus Supabase Business-Case-/Work-Item-State und der verifizierten Plattform-/Provider-Evidence rekonstruiert. Ein nicht evidenzierter Make-Workflow wird bewusst nicht als bestehende Runtime dokumentiert.
