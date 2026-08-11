# P3-052 – SIS Execution Controller / Supervisor Activation

Stand: 2026-08-11
Status: DEV/TEST identity v2 verified; no PROD promotion; no merge.

## Ziel

P3-052 ergaenzt P3-045 um einen kontrollierten Einstiegspunkt oberhalb von `sis.supervisor`:

`User -> SIS Router -> sis.controller.orchestration -> Supervisor Activation -> sis.supervisor -> P3-045 Job Queue -> spezialisierter Worker -> Review -> Completion Gate`

Der Execution Controller fuehrt keine fachlichen Aktionen aus und waehlt keinen Worker. Er validiert einen expliziten Execution Intent und erzeugt ein dauerhaftes, idempotentes Activation-Signal fuer ein konkretes Work Item.

## Kanonische Benennung

Anzeigename:

- `SIS Execution Controller`

Technischer Worker-Key:

- `sis.controller.orchestration`

`Supersupervisor` bleibt nur ein verstaendlicher interner Spitzname und wird nicht als technische Identitaet persistiert.

Der fruehere TEST-Key `sis.control_supervisor` ist abgeloest. Bestehende TEST-Activations wurden auf den kanonischen Key migriert; neue Activations verwenden ihn als Default.

Die Schema-Rollenklasse bleibt aus Kompatibilitaetsgruenden `worker_role = supervisor`. Die fachliche Abgrenzung erfolgt ueber `domain_key = orchestration` und die eng begrenzten Capabilities.

## Rollen- und Capability-Grenze

Kanonische logische Rolle:

- `worker_key = sis.controller.orchestration`
- `worker_role = supervisor`
- `domain_key = orchestration`
- `runtime_binding.binding = logical`
- `provider_actions = false`

Capabilities nur in DEV/TEST:

- `orchestration.start`
- `orchestration.observe`
- `orchestration.stop`

Der normale `sis.supervisor` bleibt davon getrennt und behaelt:

- `orchestration.plan`
- `orchestration.delegate`

Nicht vergeben werden Datenbank-, Repository-, Integration-, Runtime-, Finance-, Merge-, Provider- oder Approval-Erzeugungsrechte.

## Activation Contract

Start-RPC:

`sis_execution_controller_start_v1(work_item_key, environment, execution_intent, requested_by, metadata)`

Regeln:

- nur `dev` oder `test`
- Execution Intent muss `start`, `execute` oder `implement` sein
- Work Item muss existieren und darf nicht `done`/`cancelled` sein
- `sis.controller.orchestration` muss `orchestration.start` besitzen
- `sis.supervisor` muss in der Zielumgebung aktiv sein und weiterhin `orchestration.plan` + `orchestration.delegate` besitzen
- pro Work Item/Umgebung existiert hoechstens eine offene Activation
- Wiederholung ist idempotent
- der Start erteilt niemals Approval
- der Start fuehrt noch keinen Worker aus

Supervisor-Claim:

`sis_execution_controller_supervisor_claim_v1(activation_id)`

Der Claim setzt die Activation auf `claimed` und liefert den bestehenden Delegationspfad `sis_agent_supervisor_queue_job_v1`. Er ruft diesen Delegations-RPC nicht selbst auf. Die Worker-Auswahl bleibt damit beim P3-045 Capability-/Assignment-Contract.

Status:

`sis_execution_controller_status_v1(activation_id)`

Cancel:

`sis_execution_controller_cancel_v1(activation_id, reason)`

Nur eine noch nicht geclaimte Activation kann gecancelt werden.

## Migrationen

Kanonische Basismigration, auf TEST-Historie ausgerichtet:

`20260810234455_p3_052_supervisor_activation_controller_v1`

Identity-Migration fuer bereits bestehende TEST-Installationen:

`20260811002852_p3_052_orchestration_controller_identity_v2`

Die v2-Migration legt `sis.controller.orchestration` an, uebertraegt ausschliesslich die drei DEV/TEST-Orchestration-Capabilities, migriert bestehende Activation-Referenzen, setzt den Tabellen-Default um, aktualisiert den Start-RPC und entfernt den alten Worker-Key.

## TEST-Verifikation nach Identity-v2

Verifiziert auf `sis-platform-test`:

1. `sis.controller.orchestration` aktiv: PASS
2. alter aktiver Worker `sis.control_supervisor` entfernt: PASS
3. DEV/TEST Grants: `start`, `observe`, `stop`: PASS
4. PROD-Capability-Grants: 0: PASS
5. Non-Orchestration-Capability-Grants: 0: PASS
6. Activation-Default = `sis.controller.orchestration`: PASS
7. bestehende Activation-Referenzen auf alten Key: 0: PASS
8. TEST-Activation mit neuem Key erstellt: PASS
9. wiederholter Start idempotent mit gleicher Activation: PASS
10. Status liefert `controller_worker_key = sis.controller.orchestration`: PASS
11. Supervisor Claim nach Rename: PASS
12. wiederholter Supervisor Claim idempotent: PASS
13. Claim erzeugt keinen Job und startet keinen Worker: PASS
14. PROD-Start wird mit `EXECUTION_CONTROLLER_DEV_TEST_ONLY` abgewiesen: PASS
15. leerer/fehlender Execution Intent wird mit `EXPLICIT_EXECUTION_INTENT_REQUIRED` abgewiesen: PASS
16. Test-Fixtures nach Regression entfernt: PASS

Die vorangegangene P3-052-Regression fuer serverseitige Worker-Auswahl und P3-045-Delegation bleibt als bestehende Test-Evidence erhalten. Die Identity-v2-Regression hat den Delegations-RPC bewusst nicht ausgefuehrt und damit keinen Worker Attempt gestartet.

## Sicherheitsgrenzen

- kein PROD
- kein Provider-/Gmail-/Make-Write
- kein externer Financial Write
- kein Repository Merge
- keine Approval-Erzeugung
- keine Umgehung von P3-045 Worker-Auswahl, Review oder Approval Gates
- kein Service-Role-Secret im Modellkontext

## Naechster Schritt

PR #17 gegen den inzwischen durch P3-049 und P3-050 aktualisierten `main` synchronisieren, den effektiven Diff erneut pruefen und die P3-052-Regression gegen diesen Stand wiederholen. Erst danach Merge-Readiness bewerten. Eine PROD-Promotion bleibt separat approval-gated.
