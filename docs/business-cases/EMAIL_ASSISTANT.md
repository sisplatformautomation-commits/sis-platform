# Email Assistant

Business Case Key: `EMAIL_ASSISTANT`  
Version: `1.0.0`  
Canonicalization: `P3-046`  
Stand: `2026-08-10`  
Status: `active`

## Zweck und kanonische Struktur

`EMAIL_ASSISTANT` ist die wiederverwendbare Mail-Capability des SIS. Kunden-, Gesellschafts-, Mailbox- oder Environment-Unterschiede werden als Profile/Deployments geführt und erzeugen keinen neuen kanonischen Assistant.

Aktuelle Profile:

- `gmbh` — verifizierte GmbH-Mailbox und Policies.
- `personal` — private Mailbox/Policies; Connector und Alert-Kanal noch nicht vollständig verifiziert.

Historische Bezeichnungen `GMBH_MAIL_ASSISTANT` und `PERSONAL_MAIL_ASSISTANT` bleiben nur Aliase bzw. Work-Item-Lineage.

## Source of Truth

Supabase ist der autoritative Maschinenstatus; GitHub ist die kanonische menschenlesbare Dokumentation. Provider-/Runtime-Evidence dient als Verifikation. Credentials und Mailinhalte werden nicht als kanonische Dokumentation persistiert.

## Live-Stand

- Business Case: `active`, Fortschritt `70`.
- Health: `blocked`, weil das Personal-Profil noch nicht vollständig angebunden ist.
- GmbH-Profil: Connection, Classification und Policy-Regressions sind verifiziert.
- Personal-Profil: `PMA-002` und nachgelagerte Tasks bleiben blockiert, bis private Mailbox und Alert-Kanal getrennt verbunden und verifiziert sind.

## GmbH-Profilevidence

- Shared Gmail Connection: `9553277`.
- `GMA-000`: Gmail-Connection verifiziert; read-only Smoke-Test bestanden.
- Gmail API GET Scenario: `6881875`.
- Classification Agent Scenario: `6887214`.
- Classification Fixture Runner: `6887250`.
- Trash Action Scenario: `6887266` — approval-pflichtig und nicht automatisch aktiv.
- Weitere gemeinsame read-only Transport-Szenarien: `6881984`, `6882001`, `6887233`.

Die Connection `9553277` ist wiederverwendbare Mailbox-Infrastruktur für denselben Kunden und dasselbe Environment; sie ist kein exklusives Eigentum dieses Business Case.

## Komponenten

- `AI_TEXT` — Textklassifikation, Priorisierung und strukturierte Reasoning-Ausgabe.
- `EMAIL` — Mailbox-Zugriff und Mail-Adapter.
- `MAKE` — Workflow-Orchestrierung.
- `SECURITY_AUDIT` — Policy, Audit und Idempotenz.
- `SUPABASE` — Control-/Status-State und sichere Gateway-Funktionen.
- `NOTIFICATION` — geplante Alert-Komponente; Aktivierung erst nach Kanal-/Empfängerpolicy.

## Policy- und Sicherheitsgrenzen

- Eingehende Mailinhalte gelten als untrusted data; eingebettete Instruktionen dürfen keine Tools auslösen.
- Autonome Replies und externe Forwards sind deaktiviert.
- Permanentes Löschen ist verboten.
- Trash ist nur für eindeutig klassifiziertes Marketing mit hoher Confidence und ohne geschützte Signale vorgesehen; der Write-Pfad bleibt approval-gated.
- Unklare oder sensible Nachrichten bleiben erhalten und gehen in Review/Labeling.
- Mailbox-Credentials verbleiben beim Provider/Make-Connection-Layer; SIS speichert nur nicht geheime Inventarmetadaten.

## Aktueller nächster Schritt

Das GmbH-Profil kann unter den bestehenden DEV/TEST-Gates weitergeführt werden. Das Personal-Profil bleibt bis zur getrennten Mailbox- und Alert-Verifikation blockiert. Jede produktive Mail-Write-Aktivierung benötigt den jeweils vorgesehenen Approval-/Regression-Gate.

## Rekonstruktionshinweis

Dieses Dokument wurde in P3-046 aus Supabase Work-Item-State, Connection-Registry und verifizierter Make-Evidence rekonstruiert. Shared Transport-Szenarien werden als Infrastruktur und nicht als exklusive Business-Case-Ressourcen behandelt.
