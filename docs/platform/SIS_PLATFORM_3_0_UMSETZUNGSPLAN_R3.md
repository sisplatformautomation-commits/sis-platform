# SIS Automation Platform 3.0 – Umsetzungsplan R3

Stand: 2026-08-10
Planversion: `3.0-r3-2026-08-10`

## Verbindliche Ausführungsregeln

1. Supabase ist der autoritative Maschinenstatus.
2. Vor Writes werden Live-Zustand, Schema und Zielressource erneut gelesen.
3. DDL wird als benannte Supabase-Migration ausgeführt und danach mit Security-/Performance-Advisors geprüft.
4. GitHub ist die kanonische menschenlesbare Plattformprojektion; Änderungen laufen über Branch/PR/Merge.
5. Binärartefakte liegen im privaten Supabase-Storage oder in einer ausdrücklich registrierten Customer-Reference; keine großen Rohinhalte in Work-Item-Metadaten.
6. Keine PROD-Änderung, externe Finanzwrites, Bank-/Payment-Writes, destruktiven Kundenressourcenänderungen oder Sicherheitsabschwächungen ohne passende ausdrückliche Freigabe.
7. Google Drive ist keine Kernabhängigkeit mehr. Bestehende Drive-IDs werden als Legacy-Migrationsreferenzen erhalten.
8. Work Items gelten erst als done, wenn ihre Abnahmekriterien live verifiziert sind.

## Zielarchitektur R3

### A. Control Plane

Supabase verwaltet Programme, Business Cases, Work Items, Freigaben, Events, Audit, Knowledge Registry, Deployments, Connections, Health, Support und Observability.

### B. Execution Plane

Work Item → Job → Attempt → Step → Artifact bleibt die neutrale Ausführungskette. Provideraktionen werden über kontrollierte RPC-/Action-Verträge ausgeführt.

### C. Knowledge / Communication / Artifact Plane

- GitHub: kanonische Markdown-/Text-Dokumentation
- Supabase Storage: private, SHA-256-adressierte Binärartefakte
- `sis_platform_messages`: append-only interne Status-/Entscheidungs-/Handoff-Kommunikation
- `sis_events`: revisionsfeste Status-/Auditspur
- `customer_reference`: externe Inhalte, die im Customer Data Plane verbleiben
- Google Drive: legacy/optional connector

### D. Customer Data Plane

Produktive Kundendokumente, Bank-/Zahlungsdaten und produktive Provider-Credentials bleiben kundenseitig isoliert. Das SIS Control Plane hält nur minimale Steuer-, Versions-, Health- und Auditmetadaten.

## R3-Erweiterungen

### P3-043 – GPT Action Resource Registry und Guarded Provider Dispatcher

Ziel: GPTs adressieren logische Resource Keys statt frei wählbarer Provider-/Szenario-IDs. Resource, Kunde, Umgebung, Connection, erlaubte Operationen und Guard-Profil werden serverseitig aufgelöst. Bestehende Actions bleiben rückwärtskompatibel. PROD-Promotion bleibt separat approval-gated.

### P3-044 – Providerneutrale Knowledge-, Communication- und Artifact-Layer / Google-Drive-Ablösung

Abhängigkeiten: P3-013, P3-023, P3-041.

Ergebnis:

- `sis_knowledge_documents` providerneutral erweitert um `canonical_uri`, `revision_ref`, `content_format` und `legacy_reference`
- kontrollierte Registry-RPC `sis_register_knowledge_document_v2`
- providerneutrale View `sis_v_knowledge_documents_v2`
- privater Bucket `sis-platform-artifacts`
- Storage-Backend-Registry und deterministischer SHA-256-Pfadvertrag
- append-only `sis_platform_messages` mit service-role-only Publish-/List-RPCs
- SIS Bootstrap/Start-Menü Source-of-Truth-Vertrag auf GitHub/Supabase Storage aktualisiert
- bestehende Drive-Referenzen bleiben Legacy-Daten und werden nicht gelöscht

Abnahme:

- TEST-Migrationen erfolgreich
- gültige Knowledge-Registrierung getestet
- privater Storage und deterministischer Storage-Ref getestet
- Message-Publish getestet; UPDATE/DELETE/Truncate blockiert
- `anon`/`authenticated` besitzen keine privilegierten RPC-Rechte
- Advisor-Recheck ohne neue P3-044 Security WARN/ERROR
- Start-Menü bleibt read-only: `execution_allowed=false`, `approval_granted=false`, `task_start_allowed=false`
- GitHub-PR geprüft und gemergt
- exakt getestete Migrationen nach ausdrücklicher Freigabe auf PROD angewendet und erneut verifiziert
- GitHub-R3-Dokumente als neue kanonische Knowledge-Records registriert; Drive-R2-Dokumente superseded/legacy erhalten

## Migrationsregel für das kommende SIS-Drive-Archiv

Das Archiv ist keine Voraussetzung für die technische P3-044-Abnahme. Nach Bereitstellung wird es separat inventarisiert, gehasht und dedupliziert. Textbasierte kanonische Inhalte werden nach GitHub überführt, Binärdateien nach Supabase Storage oder als Customer Reference registriert. Historische Dokumente können als Legacy-Referenz archiviert werden. Keine Archivdatei überschreibt ohne Prüfung den aktuellen Supabase-Maschinenstatus.

## Source-of-Truth R3

- Maschinenstatus: Supabase
- Menschenlesbare Plattformdokumentation: GitHub
- Binärartefakte: Supabase Storage
- Kundeneigene Fachdaten: Customer Data Plane
- Google Drive: Legacy/optionaler Connector
- Chatverlauf: sekundärer Kontext
