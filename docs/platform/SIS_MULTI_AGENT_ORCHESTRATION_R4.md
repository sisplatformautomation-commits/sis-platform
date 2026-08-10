# SIS Multi-Agent Orchestration R4

Stand: 2026-08-10
Work Item: `P3-045`
Status: TEST-implemented, PROD promotion approval-gated

## Ziel

SIS arbeitet Aufgaben kuenftig ueber einen zentralen Supervisor und spezialisierte Worker ab. Der Supervisor plant, delegiert, ueberwacht und bewertet den Completion Gate. Er ist nicht der System of Record und erhaelt keine pauschalen Provider-, Datenbank-, Repository-, Runtime- oder Finance-Write-Rechte.

Autoritativer Zustand bleibt Supabase. Die vorhandene neutrale Kette bleibt verbindlich:

`Work Item -> Job -> Attempt -> Step -> Artifact`

P3-045 ergaenzt diese Kette um Worker Registry, Capability Registry, Assignment, Lease/Heartbeat, Approval Gate und unabhaengige Reviews. Externe Provider-Ressourcen bleiben ueber P3-043 Resource Keys und serverseitige Guards kontrolliert.

## Rollen

### SIS Supervisor

`worker_key: sis.supervisor`

Aufgaben:
- Work Item lesen und in Jobs zerlegen
- benoetigte Capabilities und Resource Keys bestimmen
- serverseitig geeigneten Worker auswaehlen lassen
- Approval-/Review-Gates ueberwachen
- abgelaufene Leases recovern und Retry Jobs requeueen
- Work Item erst abschliessen, wenn der Completion Gate gruen ist

Der Supervisor besitzt nur `orchestration.plan` und `orchestration.delegate`. Er fuehrt keine Provider Writes selbst aus.

### Worker Pool

- `sis.worker.database`
- `sis.worker.integration`
- `sis.worker.repository`
- `sis.worker.documentation`
- `sis.worker.runtime`
- `sis.worker.finance`

Jeder Worker erhaelt nur explizite Capability Grants je Umgebung. `finance.external_write` besitzt im initialen R4-Stand absichtlich keinen Worker Grant.

### Independent Reviewer

`sis.reviewer.qa_security`

Der Reviewer ist vom ausfuehrenden Worker getrennt. Self Review ist durch Assignment Contract ausgeschlossen. Review Profile: `qa`, `security`, `qa_security`.

## Capability Contract

Capabilities tragen serverseitige Risikoeigenschaften:
- `risk_level`
- `provider_write`
- `external_financial_write`
- `destructive`
- `prod_approval_required`
- `independent_review_required`

Der Supervisor waehlt keinen Worker frei per Prompt. Die Datenbank waehlt nur aktive Worker, die alle angeforderten Capabilities fuer die Zielumgebung besitzen.

Initiale Capability Klassen:
- orchestration
- database
- integration
- repository
- documentation
- runtime
- finance
- review

## Approval Gate

Ein Job wird bereits beim Planen als `blocked` angelegt, wenn seine Capabilities eine Freigabe verlangen. Er kann nicht geclaimt werden, solange die erforderlichen Approval Scopes nicht als gueltige Control-Plane-Records vorhanden sind.

Moegliche Scopes:
- `execute`
- `prod_promotion`
- `provider_write`
- `external_financial_write`
- `destructive_change`

`service_role` besitzt keinen direkten INSERT/UPDATE-Zugriff auf `sis_agent_job_approvals`. Worker und Supervisor koennen sich daher nicht selbst freigeben. Approval-Ingestion bleibt ausserhalb des Worker Pools.

## Resource Gate

Wenn ein Job `required_resource_keys` enthaelt, validiert P3-045 die Keys gegen `sis_gpt_action_resources` aus P3-043. Fehlt P3-043 oder ist ein Key nicht aktiv bzw. nicht fuer die Umgebung registriert, wird das Planen abgebrochen.

Arbitrary Scenario IDs, Connection IDs oder andere freie Provider IDs sind kein Teil des P3-045 Job Contracts.

## Lease und Worker-Ausfuehrung

Ein Worker claimt nur fuer sein Profil zugewiesene Jobs. Beim Claim entsteht ein `sis_job_attempts` Record und ein Lease Token. Heartbeat verlaengert die Lease innerhalb definierter Grenzen.

Worker Submit und Worker Fail benoetigen:
- Worker Key
- Attempt ID
- gueltiges Lease Token

Der Supervisor Status RPC gibt Lease Tokens nicht aus.

`max_concurrency` wird beim Claim serverseitig erzwungen.

Abgelaufene Leases werden durch `sis_agent_supervisor_recover_expired_leases_v1` als `timed_out` markiert und je nach Attempt-Limit in Retry oder Failed ueberfuehrt.

## Review Gate

Bei `review_required=true` ist ein erfolgreiches Worker Submit noch kein erfolgreicher Job. Der Job geht auf `blocked` / `review_required` und wartet auf den zugewiesenen Reviewer.

Review Entscheidungen:
- `pass` -> Job `succeeded`, Assignment `accepted`
- `changes_required` -> Job `retry_wait`, Assignment `rework`
- `fail` -> Job `failed`

Der Completion Gate akzeptiert nur Jobs mit `succeeded` plus Assignment `accepted`.

## Service-Role RPC Surface

Supervisor:
- `sis_agent_worker_list_v1`
- `sis_agent_supervisor_queue_job_v1`
- `sis_agent_supervisor_release_approved_job_v1`
- `sis_agent_supervisor_requeue_ready_v1`
- `sis_agent_supervisor_recover_expired_leases_v1`
- `sis_agent_supervisor_job_status_v1`
- `sis_agent_supervisor_work_item_gate_v1`

Worker Runtime:
- `sis_agent_worker_claim_v1`
- `sis_agent_worker_heartbeat_v1`
- `sis_agent_worker_submit_v1`
- `sis_agent_worker_fail_v1`

Reviewer:
- `sis_agent_reviewer_submit_v1`

Internal Helper `sis_agent_resource_guard_v1` und `sis_agent_job_approval_ok_v1` sind selbst fuer `service_role` nicht direkt executable.

## GPT Action Isolation

Die generischen Datenbank-RPCs werden nicht als ein gemeinsames Vollzugriffs-Tool an jeden GPT gegeben. Jeder GPT bekommt ein eigenes Action-/Tool-Profil, das nur die fuer seine Rolle benoetigten Operationen exponiert und Worker Identity serverseitig bzw. im Guarded Action Contract bindet. Das Service-Role Secret wird nie dem Modell offengelegt.

P3-043 ist die vorgesehene darunterliegende Action-Gateway-Schicht fuer Provider Resource Keys und operation-specific Guards.

## TEST Evidence

Auf `sis-platform-test` verifiziert:
- Worker Registry und Capability Grants vorhanden
- Supervisor besitzt nur Plan/Delegate
- Dokumentationsjob: Plan -> Claim -> Submit -> unabhängiger QA/Security Review -> Succeeded
- PROD Database Migration Job: initial blocked, Claim vor Approval nicht moeglich, nach externen Approval Records Release und Claim moeglich
- registrierter P3-043 Resource Key akzeptiert
- nicht registrierter Resource Key mit `ACTION_RESOURCE_NOT_ALLOWED_FOR_ENVIRONMENT` blockiert
- `finance.external_write` mit `NO_ELIGIBLE_WORKER` blockiert
- anon/authenticated besitzen keine Execute-Rechte auf P3-045 RPCs
- direkte Tabellenrechte fuer anon/authenticated/service_role sind entzogen
- Approval- und Resource-Helper nicht direkt service-role-executable
- Security Advisor: keine P3-045 WARN/ERROR; RLS/no-policy nur INFO und absichtlich deny-by-default

## Betriebsregel

Der Supervisor darf ein Work Item nicht aus eigenem Ermessen als abgeschlossen betrachten. Vor Abschluss muss `sis_agent_supervisor_work_item_gate_v1` einen gruene Completion Gate liefern und alle uebergeordneten SIS Approval-/PROD-Regeln bleiben weiterhin wirksam.

## PROD Gate

Die TEST-Implementierung und dieser GitHub-Stand bedeuten keine PROD-Freigabe. P3-045 PROD-Promotion benoetigt eine separate ausdrueckliche Freigabe fuer den exakt TEST-verifizierten Migration-/Commit-Stand.
