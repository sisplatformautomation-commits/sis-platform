# P3-052 – SIS Execution Controller / Supervisor Activation

Stand: 2026-08-11
Status: DEV/TEST implementation verified; no PROD promotion; no merge.

## Ziel

P3-052 ergaenzt P3-045 um einen kontrollierten Einstiegspunkt oberhalb von `sis.supervisor`:

`User -> SIS Router -> sis.control_supervisor -> Supervisor Activation -> sis.supervisor -> P3-045 Job Queue -> spezialisierter Worker -> Review -> Completion Gate`

Der Execution Controller fuehrt keine fachlichen Aktionen aus und waehlt keinen Worker. Er validiert nur einen expliziten Execution Intent und erzeugt ein dauerhaftes, idempotentes Activation-Signal fuer ein konkretes Work Item.

## Rollen- und Capability-Grenze

Neue logische Rolle:

- `sis.control_supervisor`
- `worker_role = supervisor`
- `runtime_binding.binding = logical`
- `provider_actions = false`

Capabilities nur in DEV/TEST:

- `orchestration.start`
- `orchestration.observe`
- `orchestration.stop`

Nicht vergeben werden Datenbank-, Repository-, Integration-, Runtime-, Finance-, Merge-, Provider- oder Approval-Erzeugungsrechte.

## Activation Contract

Start-RPC:

`sis_execution_controller_start_v1(work_item_key, environment, execution_intent, requested_by, metadata)`

Regeln:

- nur `dev` oder `test`
- Execution Intent muss `start`, `execute` oder `implement` sein
- Work Item muss existieren und darf nicht `done`/`cancelled` sein
- `sis.control_supervisor` muss `orchestration.start` besitzen
- `sis.supervisor` muss in der Zielumgebung aktiv sein und weiterhin `orchestration.plan` + `orchestration.delegate` besitzen
- pro Work Item/Umgebung existiert hoechstens eine offene Activation
- Wiederholung ist idempotent
- der Start erteilt niemals Approval
- der Start fuehrt noch keinen Worker aus

Supervisor-Claim:

`sis_execution_controller_supervisor_claim_v1(activation_id)`

Der Claim setzt die Activation auf `claimed` und liefert den bestehenden Delegationspfad `sis_agent_supervisor_queue_job_v1`. Die Worker-Auswahl bleibt damit vollstaendig beim P3-045 Capability-/Assignment-Contract.

Status:

`sis_execution_controller_status_v1(activation_id)`

Cancel:

`sis_execution_controller_cancel_v1(activation_id, reason)`

Nur eine noch nicht geclaimte Activation kann gecancelt werden.

## TEST-Verifikation

Migration:

`20260810234530_p3_052_supervisor_activation_controller_v1`

Verifiziert auf `sis-platform-test`:

1. Activation fuer TEST erstellt: PASS
2. Supervisor Claim: PASS
3. wiederholter Start liefert dieselbe Activation idempotent: PASS
4. Supervisor delegiert einen `database.read` Job ueber den bestehenden P3-045 Queue-RPC: PASS
5. serverseitige Worker-Auswahl: `sis.worker.database`: PASS
6. kein Approval erzeugt / `approval_required=false` fuer Read-only Regression: PASS
7. kein Worker Attempt gestartet: PASS
8. PROD-Start wird mit `EXECUTION_CONTROLLER_DEV_TEST_ONLY` abgewiesen: PASS
9. leerer/fehlender Execution Intent wird mit `EXPLICIT_EXECUTION_INTENT_REQUIRED` abgewiesen: PASS
10. `anon` Start-Execute: false
11. `authenticated` Start-Execute: false
12. `service_role` Start-Execute: true
13. direkter Tabellen-SELECT fuer anon/authenticated/service_role: false
14. PROD-Capability-Grants fuer `sis.control_supervisor`: 0
15. Non-Orchestration-Capability-Grants fuer `sis.control_supervisor`: 0

Die Regression erzeugte keinen Worker Attempt und keine Provider-/Mail-/Finance-/Runtime-Aktion. Der auditable TEST-Job wurde anschliessend auf `cancelled`, das Assignment auf `cancelled` und die Activation auf `completed` gesetzt. Das append-only Job-Event bleibt als Test-Evidence erhalten.

## Sicherheitsgrenzen

- kein PROD
- kein Provider-/Gmail-/Make-Write
- kein externer Financial Write
- kein Repository Merge
- keine Approval-Erzeugung
- keine Umgehung von P3-045 Worker-Auswahl, Review oder Approval Gates
- kein Service-Role-Secret im Modellkontext

## Naechster Schritt

Vor Merge: Branch-/PR-Review, Security Advisor, Migration-Reihenfolge gegen die offenen P3-049/P3-050 PRs pruefen und erst danach Merge-Readiness bewerten. Eine PROD-Promotion bleibt separat approval-gated.
