# SIS Naming Convention

## Canonical hierarchy

Use these terms consistently:

- **Assistant** = reusable user-facing or domain-facing capability.
- **Profile** = deployment/customer/mailbox-specific configuration or operating context of an Assistant.
- **Agent** = specialized decision or processing component inside an Assistant.
- **Workflow** = technical orchestration/scenario that executes steps.
- **Adapter** = provider-specific integration such as Gmail, Outlook, Airbnb or Booking.com.

Do not encode customer, legal entity, mailbox owner, environment, or provider into the canonical Assistant name when the underlying capability is reusable.

## Email Assistant

Canonical Business Case:

- key: `EMAIL_ASSISTANT`
- name: `Email Assistant`

Profiles:

- `gmbh` — GmbH mailbox/policy context
- `personal` — personal mailbox/policy context

Legacy aliases remain resolvable:

- `GMBH_MAIL_ASSISTANT` -> `EMAIL_ASSISTANT` / profile `gmbh`
- `PERSONAL_MAIL_ASSISTANT` -> `EMAIL_ASSISTANT` / profile `personal`

Historical Work Item keys such as `GMA-*` and `PMA-*` are retained as immutable task identifiers. They do not define the canonical Assistant name.

## Example structure

```text
Email Assistant
├── Profile: GmbH
├── Profile: Personal
├── Agents
│   ├── Mail Classification Agent
│   ├── Mail Action Policy Agent
│   ├── Mail Triage Agent
│   ├── Mail Processing Agent
│   └── Alert Agent
├── Workflows
│   └── Inbox Workflow
└── Adapters
    ├── Gmail
    └── future Outlook / other providers
```

## Rule for new capabilities

Before creating a new Business Case, ask:

1. Is this a new reusable capability? -> create a new Assistant/Business Case.
2. Is this only another customer, mailbox, property, legal entity, or environment? -> create a Profile/Deployment.
3. Is this only another external provider? -> create an Adapter.
4. Is this only a specialized processing step? -> create an Agent.
5. Is this only execution/orchestration? -> create a Workflow.
