# SIS Supervisor / Worker Runbook R4

Stand: 2026-08-10
Version: `1.0`
Bezug: `P3-045`
Status: produktive Foundation, konkrete GPT-/Agentinstanzen noch separat zu provisionieren

## Zweck

Dieses Runbook beschreibt, wie Aufgaben in SIS künftig über Supervisor, spezialisierte Worker und unabhängige Reviews abgearbeitet werden.

Verbindlicher Ablauf:

`User -> SIS Supervisor -> Job -> Worker -> Reviewer -> Completion Gate`

Supabase ist immer der autoritative Maschinenstatus. Chat-Historie, Modellgedächtnis oder eine Aussage eines Workers ersetzen niemals Live-State, Approval oder Review-Evidence.

## 1. Aufgabe anstoßen

Eine Ausführung beginnt nur bei eindeutigem Auftrag. Für getrackte SIS-Arbeit müssen ein konkreter Work-Item-/Task-Bezug und ein eindeutiges Ausführungsverb vorliegen, zum Beispiel:

`Führe P3-046 aus.`

Eine reine Auswahl wie `SIS`, ein Business-Case-Name oder eine Statusfrage startet nichts.

Vor Planung liest der Supervisor den aktuellen Work-Item-State aus Supabase und prüft Abhängigkeiten, aktuelle Gates und vorhandene Freigaben.

## 2. Supervisor plant Jobs

Der Supervisor zerlegt das Work Item in ausführbare Jobs und bestimmt je Job:

- Zielumgebung `dev`, `test`, `uat` oder `prod`,
- benötigte Capability Keys,
- benötigte P3-043 Resource Keys bei Provider-Aktionen,
- Review-Profil,
- Priorität und Dedupe-Key,
- notwendige Approval Scopes.

Verbindliche RPC:

`sis_agent_supervisor_queue_job_v1(...)`

Die Datenbank wählt den Worker serverseitig. Der Supervisor darf keinen beliebigen Worker oder Provider-Identifier am Guard vorbei erzwingen.

## 3. Capability-Auswahl

Initiale Worker:

- `sis.worker.database`
- `sis.worker.integration`
- `sis.worker.repository`
- `sis.worker.documentation`
- `sis.worker.runtime`
- `sis.worker.finance`

Reviewer:

- `sis.reviewer.qa_security`

Supervisor:

- `sis.supervisor`

Der Supervisor besitzt nur `orchestration.plan` und `orchestration.delegate`.

Beispiele für Capabilities:

- `database.read`
- `database.migration`
- `integration.provider_read`
- `integration.provider_write`
- `repository.branch_write`
- `repository.pr_write`
- `repository.merge`
- `documentation.write`
- `runtime.read`
- `runtime.change`
- `finance.read`
- `review.qa`
- `review.security`

`finance.external_write` ist im initialen R4-Stand keinem Worker zugewiesen.

## 4. Approval Gate

Approval-pflichtige Jobs werden bereits beim Planning als `blocked` angelegt.

Mögliche Scopes:

- `execute`
- `prod_promotion`
- `provider_write`
- `external_financial_write`
- `destructive_change`

Worker und Supervisor können Approval Records nicht selbst erzeugen. Eine Freigabe muss außerhalb des Worker Pools revisionsfest in den Control Plane eingebracht werden.

Nach vorliegendem Approval kann der Supervisor einen blockierten Job über

`sis_agent_supervisor_release_approved_job_v1(job_id)`

auf `queued` freigeben.

Eine Freigabe gilt nur für den konkret dokumentierten Scope. Frühere Freigaben werden nicht automatisch auf andere Work Items, PRs, Provider-Ressourcen oder PROD-Änderungen übertragen.

## 5. Provider Resource Gate

Provider-Jobs dürfen keine freie Scenario-ID, Connection-ID oder sonstige Provider-ID aus einem Prompt übernehmen.

Sie referenzieren ausschließlich P3-043 `resource_key` Werte. P3-045 validiert diese serverseitig gegen `sis_gpt_action_resources`.

Wenn P3-043 in der Zielumgebung fehlt oder der Resource Key nicht aktiv/zulässig ist, wird das Planning fail-closed abgebrochen.

Aktueller Stand dieser Runbook-Version: P3-043 ist noch nicht nach PROD promotet. Echte Provider-Resource-Ausführung über P3-045 bleibt in PROD daher blockiert, bis P3-043 separat freigegeben und verifiziert wurde.

## 6. Worker Claim und Lease

Worker holen nur Jobs ihres eigenen Profils ab:

`sis_agent_worker_claim_v1(worker_key, lease_seconds)`

Beim Claim entsteht ein Attempt mit Lease. Der zurückgegebene Lease Token ist ein Ausführungsgeheimnis und darf nicht in Supervisor-Status, Dokumentation oder Modellprompt persistiert werden.

Heartbeat:

`sis_agent_worker_heartbeat_v1(worker_key, attempt_id, lease_token, extend_seconds)`

`max_concurrency` wird serverseitig geprüft. Ein Worker kann sein Limit nicht durch mehrfaches Claiming umgehen.

## 7. Worker-Ergebnis

Erfolg:

`sis_agent_worker_submit_v1(worker_key, attempt_id, lease_token, result_evidence)`

Fehler:

`sis_agent_worker_fail_v1(worker_key, attempt_id, lease_token, error_code, error_message, evidence)`

Evidence muss technisch prüfbar sein. Typische Nachweise sind Commit/PR-Referenzen, Migrationsergebnis, Query-/RPC-Resultate, Advisor-Ergebnisse, Provider-Readback, Hashes oder Artifact-Referenzen.

Ein Worker darf seinen eigenen Erfolg nicht endgültig abnehmen.

## 8. Independent Review

Bei `review_required=true` führt ein erfolgreicher Worker-Submit zu `review_required`, nicht zu einem endgültigen Job-Erfolg.

Reviewer-RPC:

`sis_agent_reviewer_submit_v1(reviewer_worker_key, attempt_id, decision, evidence)`

Entscheidungen:

- `pass` -> Job `succeeded`, Assignment `accepted`
- `changes_required` -> Job `retry_wait`, Assignment `rework`
- `fail` -> Job `failed`

Self-Review ist verboten.

## 9. Retry und Lease Recovery

Retry-fähige Jobs werden über

`sis_agent_supervisor_requeue_ready_v1(limit)`

wieder in die Queue gestellt.

Abgelaufene Worker-Leases werden über

`sis_agent_supervisor_recover_expired_leases_v1(limit)`

bereinigt. Der Attempt wird `timed_out`; abhängig vom Attempt-Limit geht der Job in `retry_wait/rework` oder endgültig auf `failed`.

Ein abgelaufener Lease Token darf nicht erneut verwendet werden.

## 10. Status prüfen

Job-Status:

`sis_agent_supervisor_job_status_v1(job_id)`

Die Statusoberfläche zeigt Job, Assignment, Attempts und Reviews, aber keinen Lease Token.

Worker-/Capability-Inventar:

`sis_agent_worker_list_v1(environment)`

## 11. Work Item abschließen

Der Supervisor darf ein Work Item nicht auf Basis einer Chat-Aussage oder eines einzelnen Worker-Returns als erledigt betrachten.

Vor Abschluss muss

`sis_agent_supervisor_work_item_gate_v1(work_item_key)`

`ready=true` liefern.

Der Gate ist nur grün, wenn alle zu P3-045 gehörenden Jobs erfolgreich und `accepted` sind, keine fehlgeschlagenen oder offenen Jobs bestehen und alle erforderlichen Approvals erfüllt sind.

Übergeordnete SIS-Gates bleiben zusätzlich wirksam. Ein grüner P3-045 Completion Gate ersetzt keine separate PROD-, Provider-, Finanz- oder destructive-change-Freigabe.

## 12. Sicherheitsregeln

- Kein Worker erhält ein universelles Toolset.
- Service-Role-Secrets werden nie in GPT-Prompts oder Modellkontext exponiert.
- Direkter Tabellenzugriff auf P3-045-Agenttabellen ist für `anon`, `authenticated` und `service_role` entzogen.
- Kontrollierte Orchestrierungs-RPCs sind service-role-only.
- Interne Resource-/Approval-Helper sind auch für `service_role` nicht direkt executable.
- `finance.external_write` bleibt ohne expliziten zukünftigen Capability-Grant blockiert.
- Provider- und PROD-Aktionen bleiben approval-gated.
- Kundendaten verbleiben im Customer Data Plane, sofern keine explizit genehmigte Architektur abweicht.

## 13. Aktueller Betriebsmodus

P3-045 ist als Control-Plane-Foundation in PROD verifiziert und abgeschlossen.

Die konkreten Supervisor-/Worker-/Reviewer-GPTs bzw. Agentinstanzen sind noch nicht produktiv provisioniert. Bis deren separatem Rollout ist dieses Runbook der verbindliche Orchestrierungsvertrag; es entsteht dadurch kein autonomer Hintergrundbetrieb.

P3-043 bleibt ein separates PROD-Gate für Provider-Resource-Ausführung.

## 14. Störungsfall

Bei Unklarheit gilt:

1. Ausführung stoppen bzw. keinen neuen Claim starten.
2. Supabase Live-State lesen.
3. Job/Attempt/Approval/Review und Resource Gate prüfen.
4. Lease Recovery nur über den vorgesehenen Supervisor-RPC durchführen.
5. Keine Freigabe aus Chat-Historie ableiten.
6. Bei Provider- oder PROD-Änderungen fehlende Freigabe explizit beim Nutzer einholen.
7. Erst nach verifiziertem Maschinenstatus fortfahren.
