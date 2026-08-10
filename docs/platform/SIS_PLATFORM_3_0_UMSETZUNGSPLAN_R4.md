# SIS Automation Platform 3.0 – Umsetzungsplan R4

Stand: 2026-08-10
Planversion: `3.0-r4-2026-08-10-draft`

R4 baut additiv auf dem kanonischen R3-Stand auf. Die Source-of-Truth-Regeln aus R3 bleiben unveraendert: Supabase ist Maschinenstatus, GitHub ist kanonische menschenlesbare Dokumentation, Supabase Storage ist der SIS-Binaerspeicher und Google Drive ist nur Legacy/optionaler Connector.

## P3-045 – SIS Supervisor & Multi-Agent Worker Orchestration

Ziel: Work Items werden nicht mehr primaer durch einen einzelnen universellen Agenten abgearbeitet, sondern durch einen Supervisor, der spezialisierte Worker ueber die bestehende neutrale Execution Plane koordiniert.

Abhaengigkeiten:
- P3-013 Artifact Contract
- P3-043 GPT Action Resource Registry / Guarded Provider Dispatcher
- P3-044 providerneutrale Knowledge-/Communication-/Artifact-Layer

### Verbindliches Laufzeitmodell

`User -> SIS Supervisor -> Job -> spezialisierter Worker -> Independent Reviewer -> Supervisor Completion Gate`

Supabase bleibt die Wahrheit. GPT Chat-Historie darf keine Job-, Approval-, Review- oder Completion-Entscheidung ersetzen.

### Initiale Worker

- Database Worker
- Integration Worker
- Repository Worker
- Documentation Worker
- Runtime Worker
- Finance Worker
- QA/Security Reviewer

Der Supervisor besitzt keine fachlichen Ausfuehrungsrechte ausser Planung und Delegation.

### Neue Control-Plane-Objekte

- `sis_agent_workers`
- `sis_agent_capabilities`
- `sis_agent_worker_capabilities`
- `sis_agent_job_assignments`
- `sis_agent_job_approvals`
- `sis_agent_reviews`

Direkter Tabellenzugriff durch `anon`, `authenticated` und `service_role` ist entzogen. Zugriff erfolgt ueber kontrollierte SECURITY DEFINER RPCs. Approval Records sind nicht durch Worker-/Supervisor-RPCs erzeugbar.

### Supervisor RPCs

- Worker/Capability Inventar lesen
- Job serverseitig planen und Worker auswaehlen
- approved Jobs freigeben
- Retry Jobs requeueen
- abgelaufene Leases recovern
- Job Status ohne Lease Secret lesen
- Work-Item Completion Gate berechnen

### Worker RPCs

- Job claimen
- Heartbeat/Lease verlaengern
- Erfolg mit Evidence submitten
- Fehler mit Evidence melden

### Review RPC

Der unabhaengige Reviewer akzeptiert, fordert Rework oder lehnt ab. Self Review ist verboten.

### Capability- und Approval-Regeln

Capabilities bestimmen serverseitig Risk, Write-Art, Review- und PROD-Approval-Bedarf. PROD-Migrationen/Runtime-Aenderungen/Repository-Merges und Provider Writes koennen als blocked geplant werden und sind vor gueltigem Approval nicht claimbar.

`finance.external_write` wird in R4 initial keinem Worker zugewiesen.

### P3-043 Integration

Jobs referenzieren bei Provideraktionen ausschliesslich registrierte `resource_key` Werte. P3-045 validiert diese gegen die P3-043 Resource Registry. Wenn die Resource Registry nicht vorhanden ist oder ein Key nicht zur Umgebung passt, wird das Job-Planning blockiert.

### TEST-Abnahme

Erforderlich vor PROD-Promotion:
- Worker-/Capability-Registry und deny-by-default ACLs verifiziert
- normaler Plan/Claim/Submit/Review-Pfad bestanden
- Review verhindert direkte Worker-Selbstabnahme
- PROD Job vor Approval nicht claimbar
- Approval Records koennen nicht durch Worker direkt geschrieben werden
- Resource-Key Positiv- und Negativtest bestanden
- Finance External Write ohne expliziten Capability Grant blockiert
- Lease Token nicht im Supervisor Status exponiert
- max concurrency und Lease Recovery serverseitig vorhanden
- Security Advisors ohne neue P3-045 WARN/ERROR
- Performance Advisors nach DDL geprueft
- GitHub PR enthaelt exakt die getesteten Migrationen und Agent Contracts

### PROD-Promotion

P3-045 bleibt bis zu einer separaten ausdruecklichen PROD-Freigabe `in_progress`. Eine Freigabe fuer fruehere Foundation-Pakete gilt nicht automatisch fuer P3-045.

### GPT Deployment

Die Datenbank-/Action-Foundation definiert Worker-Profile und erlaubte Tool-Oberflaechen. Die konkreten Custom-GPT-/Agent-Instanzen muessen mit den jeweiligen Action-Profilen provisioniert werden. Jeder Worker erhaelt nur sein Rollenprofil; es gibt kein gemeinsames universelles Worker-Tool mit allen Operationen.
