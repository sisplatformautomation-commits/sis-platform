# SIS Automation Platform 3.0 – Umsetzungsplan R4

Stand: 2026-08-10
Planversion: `3.0-r4-2026-08-10`
Status: `published / PROD verified`

R4 baut additiv auf dem kanonischen R3-Stand auf. Die Source-of-Truth-Regeln aus R3 bleiben unverändert: Supabase ist der autoritative Maschinenstatus, GitHub ist die kanonische menschenlesbare Dokumentation, Supabase Storage ist der SIS-Binärspeicher und Google Drive ist nur Legacy-/optionaler Connector.

## P3-045 – SIS Supervisor & Multi-Agent Worker Orchestration

Status: `done`
PROD-Verifikation: `passed`

Ziel: Work Items werden nicht mehr primär durch einen einzelnen universellen Agenten abgearbeitet, sondern durch einen Supervisor, der spezialisierte Worker über die bestehende neutrale Execution Plane koordiniert.

Abhängigkeiten:
- P3-013 Artifact Contract
- P3-043 GPT Action Resource Registry / Guarded Provider Dispatcher
- P3-044 providerneutrale Knowledge-/Communication-/Artifact-Layer

### Verbindliches Laufzeitmodell

`User -> SIS Supervisor -> Job -> spezialisierter Worker -> Independent Reviewer -> Supervisor Completion Gate`

Supabase bleibt die Wahrheit. GPT- oder Chat-Historie darf keine Job-, Approval-, Review- oder Completion-Entscheidung ersetzen.

### Initiale Rollen

- `sis.supervisor`
- `sis.worker.database`
- `sis.worker.integration`
- `sis.worker.repository`
- `sis.worker.documentation`
- `sis.worker.runtime`
- `sis.worker.finance`
- `sis.reviewer.qa_security`

Der Supervisor besitzt ausschließlich Orchestrierungsfähigkeiten für Planung und Delegation. Er besitzt keine pauschalen Provider-, Datenbank-, Repository-, Runtime- oder Finance-Ausführungsrechte.

### Control-Plane-Objekte

- `sis_agent_workers`
- `sis_agent_capabilities`
- `sis_agent_worker_capabilities`
- `sis_agent_job_assignments`
- `sis_agent_job_approvals`
- `sis_agent_reviews`

Direkter Tabellenzugriff durch `anon`, `authenticated` und `service_role` ist entzogen. Zugriff erfolgt über kontrollierte SECURITY DEFINER RPCs. Die internen Approval- und Resource-Helper sind selbst für `service_role` nicht direkt ausführbar.

### Supervisor-Vertrag

Der Supervisor darf:
- Worker-/Capability-Inventar lesen,
- Jobs serverseitig planen und geeignete Worker auswählen lassen,
- extern genehmigte Jobs freigeben,
- Retry-Jobs requeueen,
- abgelaufene Leases recovern,
- Job-Status ohne Lease-Secret lesen,
- den Work-Item Completion Gate berechnen.

Der Supervisor darf keine Approval-Records selbst erzeugen und keine fachliche Worker-Aktion als eigene Ausführung umgehen.

### Worker-Vertrag

Worker dürfen ausschließlich Jobs ihres Rollenprofils claimen. Die Ausführung verwendet Attempt + Lease/Heartbeat. Erfolg oder Fehler müssen mit Evidence zurückgegeben werden. `max_concurrency` wird serverseitig durchgesetzt.

### Unabhängiges Review

Bei review-pflichtigen Capabilities führt ein erfolgreicher Worker-Submit noch nicht zum Job-Erfolg. Der zugewiesene unabhängige Reviewer entscheidet `pass`, `changes_required` oder `fail`. Self-Review ist ausgeschlossen.

### Capability- und Approval-Regeln

Capabilities bestimmen serverseitig Risiko, Write-Art, Review-Bedarf und PROD-Approval-Bedarf. PROD-Migrationen, Runtime-Änderungen, Repository-Merges und Provider-Writes können bereits bei Planung als `blocked` angelegt werden und sind vor gültigen Approval-Records nicht claimbar.

`finance.external_write` besitzt im initialen R4-Stand absichtlich keinen Worker-Grant.

### P3-043 Integration

Provider-Jobs referenzieren ausschließlich registrierte `resource_key`-Werte. P3-045 validiert diese gegen die P3-043 Resource Registry. Fehlt die Registry oder passt der Key nicht zur Umgebung, wird das Planning fail-closed abgebrochen.

P3-043 besitzt weiterhin ein separates PROD-Gate. Die erfolgreiche P3-045-Promotion autorisiert keine P3-043-Provider-Ressourcen und keine externen Provider-Writes.

## Verifikation

### TEST

Auf `sis-platform-test` verifiziert:
- Worker-/Capability-Registry und deny-by-default ACLs,
- Plan -> Claim -> Submit -> unabhängiges Review -> Succeeded,
- PROD-Job vor Approval nicht claimbar,
- Approval-Records nicht durch Worker/Supervisor erzeugbar,
- registrierter P3-043 Resource-Key akzeptiert,
- beliebiger Resource-Key blockiert,
- `finance.external_write` ohne Worker-Grant blockiert,
- Lease-Token im Supervisor-Status redigiert,
- `max_concurrency` durchgesetzt,
- Lease-Recovery `timed_out -> retry_wait/rework`,
- keine verbliebenen Test-Fixtures,
- keine neuen P3-045 Security WARN/ERROR,
- Performance-Advisor nach FK-Index-Härtung ohne neue P3-045 WARN/ERROR.

### PROD

Explizite PROD-Freigabe wurde für PR #9 / Head `97284d89445183f2dcaac12bf403582bfb385c3e` erteilt und als SIS Event #138 dokumentiert.

PR #9 wurde gemergt. Merge-Commit:
`4fa353ce2bb65fe1d5c960ae1ede4755dde1b208`

Die fünf exakt auf TEST verifizierten Migrationen wurden in derselben Reihenfolge nach PROD promotet. Die Live-Abnahme bestätigte:
- alle P3-045 Tabellen und RPCs vorhanden,
- privilegierte RPCs nur `service_role`,
- interne Helper nicht direkt `service_role`-ausführbar,
- keine direkten Agent-Tabellenrechte für `anon`, `authenticated` oder `service_role`,
- Supervisor nur mit `orchestration.plan` und `orchestration.delegate`,
- `finance.external_write` mit 0 Worker-Grants,
- SIS Start-/Navigation weiterhin read-only,
- keine neuen P3-045 Security WARN/ERROR,
- Performance nur INFO-Findings.

P3-045 wurde mit SIS Event #139 als `task.completed` abgeschlossen.

## GPT-/Agent-Deployment

Die produktive Foundation definiert Worker Registry, Capability Contract, Rollenprofile, Approval-/Review-/Lease-Verträge und die kontrollierten RPC-Oberflächen.

Die konkreten Custom-GPT-/Agent-Instanzen sind noch nicht als produktive Einzelinstanzen provisioniert. Sie müssen in einem separaten, getrackten Schritt mit rollenbezogenen Action-/Tool-Profilen bereitgestellt werden. Jeder Worker erhält nur sein Rollenprofil; ein gemeinsames universelles Worker-Tool ist nicht zulässig. Service-Role-Secrets werden niemals dem Modell offengelegt.

## Offene Folgearbeiten

1. P3-043 separat in TEST vollständig härten, freigeben und nach PROD promoten, bevor Provider-Resource-Ausführung über die neue Orchestrierung produktiv genutzt wird.
2. Konkrete Supervisor-/Worker-/Reviewer-Agentinstanzen aus den R4-Profilen provisionieren und gegen den P3-045 Control Plane Contract verifizieren.
3. Die weiterhin nur als Google-Drive-Legacy registrierten Fach-/Runbook-Dokumente kontrolliert nach GitHub rekonstruieren oder nach Eingang des Archivs migrieren. Das fehlende Drive-Archiv blockiert den SIS-Core nicht.

## Abschlussregel

P3-045 ist als Foundation-/Control-Plane-Baustein abgeschlossen. Dieser Abschluss bedeutet ausdrücklich nicht, dass P3-043-Provider-Ressourcen oder externe Finanz-/Provider-Writes implizit freigegeben sind.