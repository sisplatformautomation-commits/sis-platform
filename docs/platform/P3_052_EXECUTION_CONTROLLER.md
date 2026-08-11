# P3-052 – SIS Execution Controller / Supervisor Activation

Stand: 2026-08-11
Status: current-main synchronized; TEST regression PASS; no PROD promotion; no merge.

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

## Synchronisierung mit aktuellem main

PR #17 wurde mit dem aktuellen `main` synchronisiert:

- `main`: `5252c48110977aa4cc14515b421f1bd7c33f7cac`
- synchronisierter PR-Head vor diesem Dokumentationsupdate: `c8878a3fbbdd2cec2d36de1db695205bcf54cae3`
- Merge-Base = aktueller `main`
- behind by: 0
- effektiver Diff nach Synchronisierung: 3 P3-052-Dateien
- Diff-Groesse vor diesem Dokumentationsupdate: +518 / -0
- GitHub mergeability: mergeable

Es existierten auf dem synchronisierten Head keine registrierten Commit-Status-Checks. Die TEST-Regression ist daher die ausgefuehrte Runtime-Evidence.

## Supersupervisor-Regression nach main-Sync

Erneut verifiziert auf `sis-platform-test` gegen den Plattformstand mit P3-049 + P3-050 + P3-052:

1. kanonischer Controller `sis.controller.orchestration` aktiv: PASS
2. alter Controller-Worker vorhanden: 0: PASS
3. DEV/TEST `start` / `observe` / `stop` Grants: 6: PASS
4. PROD-Grants: 0: PASS
5. Non-Orchestration-Grants: 0: PASS
6. erforderliche P3-049/P3-050/P3-052 Migrationen vorhanden: PASS
7. Activation-Default = `sis.controller.orchestration`: PASS
8. Activation Create: PASS
9. wiederholter Start idempotent: PASS
10. Activation/Status fuehrt kanonischen Controller-Key: PASS
11. Supervisor Claim: PASS
12. wiederholter Claim idempotent: PASS
13. nach Claim erzeugte Jobs: 0: PASS
14. Cancel: PASS
15. wiederholter Cancel idempotent: PASS
16. PROD-Start blockiert mit `EXECUTION_CONTROLLER_DEV_TEST_ONLY`: PASS
17. fehlender Intent blockiert mit `EXPLICIT_EXECUTION_INTENT_REQUIRED`: PASS
18. `anon` Start-Execute: false: PASS
19. `authenticated` Start-Execute: false: PASS
20. `service_role` Start-Execute: true: PASS
21. temporaere Regression-Fixtures entfernt: PASS
22. alte Activation-Referenzen auf `sis.control_supervisor`: 0: PASS

Die Post-Sync-Regression hat bewusst keinen Delegations-RPC aufgerufen und keinen Worker gestartet. Damit wurde die Controller-/Supervisor-Grenze isoliert geprueft. Die fruehere P3-052-Evidence fuer serverseitige Worker-Zuweisung ueber P3-045 bleibt bestehen.

## Sicherheitsgrenzen

- kein PROD
- kein Provider-/Gmail-/Make-Write
- kein externer Financial Write
- kein Repository Merge
- keine Approval-Erzeugung
- keine Umgehung von P3-045 Worker-Auswahl, Review oder Approval Gates
- kein Service-Role-Secret im Modellkontext

## Naechster Schritt

PR #17 ist mit aktuellem `main` synchronisiert und TEST-regression-verifiziert. Ein Merge erfordert eine separate explizite Autorisierung. Eine PROD-Promotion bleibt ebenfalls separat approval-gated.
