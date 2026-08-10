# SIS Automation Platform – Master Architecture R3

Stand: 2026-08-10

## Authority model

The authoritative machine state of SIS is Supabase. Human-readable canonical platform documentation is versioned in GitHub. Binary platform artifacts are stored in private Supabase Storage using content-addressed SHA-256 paths. Chat history is secondary context only.

Google Drive is no longer a required SIS core dependency. Existing Drive references remain readable as legacy migration references and Google Drive may still be used as an optional customer/provider connector when a business case requires it.

## Core layers

### 1. SIS Control Plane – Supabase

Supabase stores programs, business cases, work items, execution state, approvals, events, audit metadata, knowledge registry entries, deployment and connection inventory, health, incidents and support state.

### 2. Neutral Execution Plane

Work Items describe goals. Jobs, Attempts and Steps describe execution. Artifacts are immutable metadata records referencing external storage. Provider actions are accessed only through guarded, environment-aware RPC/action contracts.

### 3. Canonical Knowledge – GitHub

Architecture, implementation plans, runbooks, specifications and release documentation are Markdown/text in the SIS repository. Canonical registry rows contain provider-neutral URI, revision reference, SHA-256 content hash and version. Changes follow branch/PR/merge history.

### 4. Binary Artifact Plane – Supabase Storage

The private bucket `sis-platform-artifacts` is the SIS-owned binary artifact backend. Paths are deterministic and content-addressed:

`sha256/<first2>/<next2>/<sha256>`

The Control Plane stores only references, hashes, content type, size, lineage and retention metadata. Customer business data remains in the customer data plane unless an explicitly approved architecture says otherwise.

### 5. Internal Communication Plane

Machine-to-machine and agent-to-agent status, decisions, action-required notices, handoffs and notifications use the append-only `sis_platform_messages` layer plus the existing event/audit model. Communication channels such as email, Slack, Teams or Google are delivery adapters, never the system of record.

### 6. Customer Data Plane

Productive customer documents, finance records, bank/payment data and customer-owned provider credentials remain isolated per customer. SIS central infrastructure stores only the minimum control, version, health and audit metadata required to operate the platform.

## Knowledge provider contract

Allowed knowledge/storage provider classes:

- `github` – canonical human-readable SIS documentation
- `supabase_storage` – binary SIS artifacts
- `customer_reference` – content intentionally retained in a customer-owned data plane
- `google_drive` – legacy or optional connector; not a core dependency

Each canonical knowledge record has a stable `canonical_uri`, an optional `revision_ref`, a SHA-256 `content_hash`, version and verification timestamp. Historical Google Drive IDs are preserved in `legacy_reference` during migration.

## Security invariants

- `anon` and `authenticated` do not receive privileged execution paths.
- Controlled SECURITY DEFINER RPCs are restricted to `service_role` unless explicitly designed otherwise.
- Platform messages are append-only.
- The SIS artifact bucket is private.
- No external finance write, bank transfer/payment write, destructive customer-resource change or Make PROD action is implied by this architecture.
- PROD changes require the applicable explicit approval gate.

## Runtime source-of-truth contract

The SIS bootstrap/start-menu contract reports:

- machine state: `supabase`
- human-readable projection: `github`
- binary artifacts: `supabase_storage`
- Google Drive role: `legacy_or_optional_connector`
- chat history role: `secondary_context`

Standalone `SIS` remains read-only navigation with execution, approval and task-start flags set to false.

## Migration rule

Existing Google Drive documents are not deleted by the R3 transition. When the archived SIS Drive export becomes available, it is inventoried, hashed, deduplicated and mapped to either GitHub canonical text, Supabase Storage binary artifacts or archived legacy references. Supabase live machine state always takes precedence over stale document content.
