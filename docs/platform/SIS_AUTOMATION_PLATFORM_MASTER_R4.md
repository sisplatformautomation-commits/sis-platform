# SIS Automation Platform – Master Architecture R4

Stand: 2026-08-10
Version: `3.0-r4-2026-08-10`
Status: `published / PROD verified`

R4 baut additiv auf R3 auf. Die providerneutrale Knowledge-/Artifact-/Communication-Architektur aus P3-044 bleibt unverändert und wird um die produktive Supervisor-/Worker-Orchestrierung aus P3-045 ergänzt.

## Authority Model

Die Source-of-Truth-Reihenfolge ist verbindlich:

1. Supabase = autoritativer Maschinenstatus.
2. GitHub = kanonische menschenlesbare SIS-Dokumentation.
3. Supabase Storage = private SIS-Binärartefakte.
4. Provider-/Runtime-Evidence = Verifikationsquelle für externe Systeme.
5. Chat-Historie = sekundärer Kontext, niemals Ersatz für Maschinenstatus, Approval oder Review.

Google Drive ist keine SIS-Core-Abhängigkeit mehr. Bestehende Drive-Referenzen werden als Legacy-/Migrationsreferenzen erhalten und können optional als Kunden-/Provider-Connector genutzt werden.

## Architektur-Layer

### 1. SIS Control Plane – Supabase

Supabase verwaltet Programme, Business Cases, Work Items, Execution State, Jobs, Attempts, Steps, Artifacts, Approvals, Events, Audit-Metadaten, Knowledge Registry, Deployment-/Connection-Inventar, Health, Incidents und Support-State.

### 2. Neutral Execution Plane

Die verbindliche Ausführungskette lautet:

`Work Item -> Job -> Attempt -> Step -> Artifact`

Work Items beschreiben Ziele und Abnahmekriterien. Jobs sind ausführbare Einheiten. Attempts tragen Lease-/Heartbeat-State. Steps bilden technische Teilschritte ab. Artifacts speichern immutable Metadaten und Referenzen auf externe oder interne Storage-Ziele.

### 3. Multi-Agent Orchestration Plane – P3-045

Die Ausführung wird durch einen Supervisor koordiniert:

`User -> SIS Supervisor -> Job -> spezialisierter Worker -> Independent Reviewer -> Supervisor Completion Gate`

Der Supervisor ist kein System of Record und besitzt keine fachlichen Ausführungsrechte. Er plant, delegiert, überwacht Approval-/Review-Gates, recoverd abgelaufene Leases und bewertet den Completion Gate.

Initiale Rollen:
- `sis.supervisor`
- `sis.worker.database`
- `sis.worker.integration`
- `sis.worker.repository`
- `sis.worker.documentation`
- `sis.worker.runtime`
- `sis.worker.finance`
- `sis.reviewer.qa_security`

### 4. Capability / Assignment / Review Contract

P3-045 ergänzt den Control Plane um:
- `sis_agent_workers`
- `sis_agent_capabilities`
- `sis_agent_worker_capabilities`
- `sis_agent_job_assignments`
- `sis_agent_job_approvals`
- `sis_agent_reviews`

Capabilities definieren serverseitig Risiko und Freigabeanforderungen. Worker werden nicht frei per Prompt gewählt, sondern nur serverseitig aus aktiven Rollen ausgewählt, die alle angeforderten Capabilities in der Zielumgebung besitzen.

Review-pflichtige Jobs benötigen einen unabhängigen Reviewer. Self-Review ist ausgeschlossen. Ein Worker-Submit ist bei `review_required=true` noch kein erfolgreicher Job.

### 5. Approval Gate

Mögliche Approval-Scopes:
- `execute`
- `prod_promotion`
- `provider_write`
- `external_financial_write`
- `destructive_change`

Jobs werden bei approval-pflichtigen Capabilities bereits als `blocked` geplant. Ohne gültige Approval-Records können sie nicht geclaimt werden.

Worker- und Supervisor-RPCs können keine Approval-Records erzeugen. Direkter Tabellenzugriff auf die P3-045-Agenttabellen ist auch für `service_role` entzogen; kontrollierte SECURITY DEFINER RPCs bilden die zulässige Oberfläche.

### 6. Provider Action / Resource Gate – P3-043

Externe Provider-Ressourcen werden ausschließlich über logische `resource_key`-Werte adressiert. Arbitrary Scenario IDs, Connection IDs oder andere frei angegebene Provider-IDs sind kein Bestandteil des P3-045 Job Contracts.

P3-045 validiert Resource Keys gegen die P3-043 Resource Registry. Wenn P3-043 in der Zielumgebung nicht produktiv verfügbar ist, bleibt Provider-Resource-Ausführung fail-closed.

Wichtig: Die P3-045-PROD-Promotion autorisiert P3-043 nicht automatisch. P3-043 bleibt ein separates PROD-Gate.

### 7. Canonical Knowledge – GitHub

Architektur, Umsetzungspläne, Runbooks, Spezifikationen und Release-Dokumentation werden als versionierte Markdown-/Textdateien im SIS-Repository verwaltet. Die Knowledge Registry speichert providerneutrale URI, Revision, SHA-256 Hash, Version und Verifikationszeitpunkt.

Änderungen folgen Branch -> PR -> Merge -> Registry-Verifikation.

### 8. Binary Artifact Plane – Supabase Storage

Der private Bucket `sis-platform-artifacts` ist der SIS-eigene Binärspeicher. Inhalt wird über SHA-256 adressiert. Der Control Plane speichert Referenzen, Hashes, Content Type, Größe, Lineage und Retention-Metadaten.

Produktive Kundendaten bleiben im Customer Data Plane, sofern keine explizit genehmigte Architektur etwas anderes vorsieht.

### 9. Internal Communication Plane

Agenten- und Systemkommunikation nutzt `sis_platform_messages` plus das bestehende Event-/Audit-Modell. E-Mail, Slack, Teams oder Google sind nur Delivery-/Provider-Adapter und niemals Source of Truth.

### 10. Customer Data Plane

Produktive Kundendokumente, Finance-Daten, Bank-/Payment-Daten und kundenkontrollierte Provider-Credentials bleiben kundenisoliert. Die SIS-Zentrale speichert nur die minimal notwendigen Control-, Version-, Health- und Audit-Metadaten.

## Sicherheitsinvarianten

- Standalone `SIS` bleibt reine read-only Navigation.
- `anon` und `authenticated` erhalten keine privilegierten P3-045-Ausführungspfade.
- P3-045-Agenttabellen besitzen keine direkten Grants für `anon`, `authenticated` oder `service_role`.
- Kontrollierte P3-045-RPCs sind `service_role`-only.
- Interne Resource-/Approval-Helper sind selbst für `service_role` nicht direkt ausführbar.
- Lease-Tokens werden nicht über Supervisor-Statusflächen exponiert.
- `max_concurrency` wird serverseitig erzwungen.
- Abgelaufene Leases werden serverseitig recovered.
- Self-Review ist verboten.
- `finance.external_write` besitzt im initialen R4-Stand 0 Worker-Grants.
- Provider-Writes, externe Finanzwrites, destructive changes und PROD-Promotionen unterliegen den jeweils geltenden Approval-Gates.
- Service-Role-Secrets werden nie an GPTs/Modelle übergeben.

## Produktiver P3-045-Stand

TEST-Verifikation auf `sis-platform-test` erfolgreich.

Explizite PROD-Freigabe:
- SIS Event #138 `task.prod_approval_granted`
- PR #9
- Head `97284d89445183f2dcaac12bf403582bfb385c3e`

GitHub Merge:
- PR #9
- Merge-Commit `4fa353ce2bb65fe1d5c960ae1ede4755dde1b208`

PROD-Verifikation:
- alle P3-045 Tabellen/RPCs vorhanden,
- Rollen-/Capability-Modell aktiv,
- deny-by-default ACLs bestätigt,
- interne Helper nicht direkt ausführbar,
- Supervisor nur mit Orchestrierungsfähigkeiten,
- `finance.external_write` ohne Worker-Grant,
- keine neuen P3-045 Security WARN/ERROR,
- SIS Navigation weiterhin read-only.

Abschluss:
- SIS Event #139 `task.completed`
- P3-045 live `done`
- `prod_status=passed`

## Konkrete GPT-/Agentinstanzen

R4 definiert die produktive Control-Plane- und Action-Vertragsgrundlage. Die konkreten Custom-GPT-/Agent-Instanzen sind noch nicht als produktive Einzelinstanzen provisioniert.

Ihre Bereitstellung muss in einem separaten getrackten Schritt erfolgen und die rollenbezogenen Tool-Oberflächen aus `gpt-agents/p3_045_worker_profiles_v1.yaml` verwenden. Es ist nicht zulässig, allen Worker-Modellen ein gemeinsames universelles Toolset oder ein Service-Role-Secret zur Verfügung zu stellen.

## Aktuelle Grenzen / Folgearbeiten

1. P3-043 muss separat vollständig gehärtet, freigegeben und nach PROD promotet werden, bevor echte Provider-Resource-Jobs über die neue Orchestrierung produktiv laufen.
2. Konkrete Supervisor-/Worker-/Reviewer-Agentinstanzen müssen provisioniert und gegen den P3-045 Contract getestet werden.
3. Legacy-Dokumente, die weiterhin nur als Google-Drive-Referenzen in der Knowledge Registry stehen, werden künftig nach GitHub rekonstruiert oder nach Eingang des Archivs kontrolliert migriert. Das fehlende Drive-Archiv blockiert den SIS-Core nicht.

## Runtime Source-of-Truth Contract

Der SIS Bootstrap-/Startmenüvertrag bleibt:
- machine state: `supabase`
- human-readable projection: `github`
- binary artifacts: `supabase_storage`
- Google Drive role: `legacy_or_optional_connector`
- chat history role: `secondary_context`

Standalone `SIS` bleibt `execution_allowed=false`, `approval_granted=false`, `task_start_allowed=false`.

## Abschlussregel

R4 ist der kanonische Foundation-Stand nach P3-045. P3-045 ist als Supervisor-/Worker-Control-Plane produktiv abgeschlossen. Provider-Ressourcen, externe Finanzwrites und konkrete Agentinstanzen bleiben separat approval-/provisioning-gated.