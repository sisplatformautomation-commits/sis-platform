# SIS Multi-Agent Orchestration R4

Stand: 2026-08-10
Work Item: `P3-045`
Status: `PROD verified / foundation active`

## Ziel

SIS arbeitet Aufgaben künftig über einen zentralen Supervisor und spezialisierte Worker ab. Der Supervisor plant, delegiert, überwacht und bewertet den Completion Gate. Er ist nicht der System of Record und erhält keine pauschalen Provider-, Datenbank-, Repository-, Runtime- oder Finance-Write-Rechte.

Autoritativer Zustand bleibt Supabase. Die vorhandene neutrale Kette bleibt verbindlich:

`Work Item -> Job -> Attempt -> Step -> Artifact`

P3-045 ergänzt diese Kette um Worker Registry, Capability Registry, Assignment, Lease/Heartbeat, Approval Gate und unabhängige Reviews. Externe Provider-Ressourcen bleiben über P3-043 Resource Keys und serverseitige Guards kontrolliert.

## Rollen

### SIS Supervisor

`worker_key: sis.supervisor`

Aufgaben:
- Work Item lesen und in Jobs zerlegen,
- benötigte Capabilities und Resource Keys bestimmen,
- serverseitig geeigneten Worker auswählen lassen,
- Approval-/Review-Gates überwachen,
- abgelaufene Leases recovern und Retry-Jobs requeueen,
- Work Item erst abschließen, wenn der Completion Gate grün ist.

Der Supervisor besitzt nur `orchestration.plan` und `orchestration.delegate`. Er führt keine Provider-, Datenbank-, Repository-, Runtime- oder Finance-Aktion selbst aus.

### Worker Pool

- `sis.worker.database`
- `sis.worker.integration`
- `sis.worker.repository`
- `sis.worker.documentation`
- `sis.worker.runtime`
- `sis.worker.finance`

Jeder Worker erhält nur explizite Capability Grants je Umgebung. `finance.external_write` besitzt im initialen R4-Stand absichtlich keinen Worker-Grant.

### Independent Reviewer

`sis.reviewer.qa_security`

Der Reviewer ist vom ausführenden Worker getrennt. Self-Review ist durch den Assignment Contract ausgeschlossen. Review-Profile: `qa`, `security`, `qa_security`.

## Capability Contract

Capabilities tragen serverseitige Risikoeigenschaften:
- `risk_level`
- `provider_write`
- `external_financial_write`
- `destructive`
- `prod_approval_required`
- `independent_review_required`

Der Supervisor wählt keinen Worker frei per Prompt. Die Datenbank wählt nur aktive Worker, die alle angeforderten Capabilities für die Zielumgebung besitzen.

Initiale Capability-Klassen:
- orchestration
- database
- integration
- repository
- documentation
- runtime
- finance
- review

## Approval Gate

Ein Job wird bereits beim Planen als `blocked` angelegt, wenn seine Capabilities eine Freigabe verlangen. Er kann nicht geclaimt werden, solange die erforderlichen Approval Scopes nicht als gültige Control-Plane-Records vorhanden sind.

Mögliche Scopes:
- `execute`
- `prod_promotion`
- `provider_write`
- `external_financial_write`
- `destructive_change`

`service_role` besitzt keinen direkten INSERT/UPDATE-Zugriff auf `sis_agent_job_approvals`. Worker und Supervisor können sich daher nicht selbst freigeben. Approval-Ingestion bleibt außerhalb des Worker Pools.

## Resource Gate

Wenn ein Job `required_resource_keys` enthält, validiert P3-045 die Keys gegen `sis_gpt_action_resources` aus P3-043. Fehlt P3-043 oder ist ein Key nicht aktiv bzw. nicht für die Umgebung registriert, wird das Planen abgebrochen.

Arbitrary Scenario IDs, Connection IDs oder andere freie Provider IDs sind kein Teil des P3-045 Job Contracts.

Aktueller PROD-Zustand: P3-043 ist noch nicht nach PROD promotet. Provider-Resource-Ausführung über P3-045 bleibt deshalb fail-closed, bis P3-043 separat freigegeben und produktiv verifiziert ist.

## Lease und Worker-Ausführung

Ein Worker claimt nur für sein Profil zugewiesene Jobs. Beim Claim entsteht ein `sis_job_attempts`-Record und ein Lease Token. Heartbeat verlängert die Lease innerhalb definierter Grenzen.

Worker Submit und Worker Fail benötigen:
- Worker Key,
- Attempt ID,
- gültiges Lease Token.

Der Supervisor-Status-RPC gibt Lease Tokens nicht aus. `max_concurrency` wird beim Claim serverseitig erzwungen.

Abgelaufene Leases werden durch `sis_agent_supervisor_recover_expired_leases_v1` als `timed_out` markiert und abhängig vom Attempt-Limit in Retry oder Failed überführt.

## Review Gate

Bei `review_required=true` ist ein erfolgreicher Worker Submit noch kein erfolgreicher Job. Der Job geht auf `blocked` / `review_required` und wartet auf den zugewiesenen Reviewer.

Review-Entscheidungen:
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

Die internen Helper `sis_agent_resource_guard_v1` und `sis_agent_job_approval_ok_v1` sind selbst für `service_role` nicht direkt executable.

## GPT Action Isolation

Die generischen Datenbank-RPCs werden nicht als ein gemeinsames Vollzugriffs-Tool an jeden GPT gegeben. Jeder GPT erhält ein eigenes Action-/Tool-Profil, das nur die für seine Rolle benötigten Operationen exponiert und die Worker Identity serverseitig bzw. im Guarded Action Contract bindet.

Das Service-Role Secret wird nie dem Modell offengelegt. P3-043 ist die darunterliegende Action-Gateway-Schicht für Provider Resource Keys und operation-specific Guards.

## Verifikationsnachweis

### TEST

Auf `sis-platform-test` verifiziert:
- Worker Registry und Capability Grants vorhanden,
- Supervisor besitzt nur Plan/Delegate,
- Dokumentationsjob: Plan -> Claim -> Submit -> unabhängiger QA/Security Review -> Succeeded,
- PROD Database Migration Job vor Approval blockiert und nach externen Approval-Records freigebbar,
- registrierter P3-043 Resource Key akzeptiert,
- nicht registrierter Resource Key blockiert,
- `finance.external_write` mit `NO_ELIGIBLE_WORKER` blockiert,
- anon/authenticated ohne Execute-Rechte auf P3-045 RPCs,
- direkte Tabellenrechte für anon/authenticated/service_role entzogen,
- Approval- und Resource-Helper nicht direkt service-role-executable,
- Lease-Token im Supervisor-Status redigiert,
- max concurrency und Lease-Recovery verifiziert,
- keine verbliebenen Fixtures,
- keine neuen P3-045 Security WARN/ERROR.

### PROD

Explizite Freigabe: SIS Event #138 `task.prod_approval_granted` für PR #9 / Head `97284d89445183f2dcaac12bf403582bfb385c3e`.

Merge: PR #9, Merge-Commit `4fa353ce2bb65fe1d5c960ae1ede4755dde1b208`.

Die exakt auf TEST verifizierten fünf Migrationen wurden nach PROD promotet. Live bestätigt sind Rollen, Capabilities, deny-by-default ACLs, service-role-only RPCs, unabhängiges Review, Approval Gate, Lease/Heartbeat/Recovery und 0 Grants für `finance.external_write`.

Abschluss: SIS Event #139 `task.completed`; P3-045 steht live auf `done`, `prod_status=passed`.

## Betriebsregel

Der Supervisor darf ein Work Item nicht aus eigenem Ermessen als abgeschlossen betrachten. Vor Abschluss muss `sis_agent_supervisor_work_item_gate_v1` einen grünen Completion Gate liefern. Alle übergeordneten SIS Approval-/PROD-Regeln bleiben weiterhin wirksam.

Für Provider-Jobs gilt zusätzlich: ohne produktiv verfügbare P3-043 Resource Registry ist keine Provider-Resource-Ausführung zulässig.

## Konkrete Agentinstanzen

P3-045 liefert die produktive Control-Plane- und Action-Vertragsgrundlage. Die konkreten Custom-GPT-/Agent-Instanzen sind noch nicht produktiv provisioniert. Ihre Bereitstellung ist ein separater getrackter Schritt und muss die rollenbezogenen Tool-Oberflächen aus `gpt-agents/p3_045_worker_profiles_v1.yaml` verwenden.

Es gibt kein zulässiges universelles Worker-Profil mit allen Operationen.