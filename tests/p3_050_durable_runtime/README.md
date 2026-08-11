# P3-050 local durable-runtime evaluation

This harness compares **Temporal first, then Restate** against the same P3-049-derived, evidence-only approval state machine.

Safety contract: TEST only; `APPROVAL_REQUIRED`; no Gmail/Make/provider call; no PROD; no external financial write. The only side effect is an idempotent row in a local SQLite evidence DB.

## Shared matrix

The ten cases are defined in `contract.py`. Run the environment/contract preflight:

```bash
python run_contract_matrix.py > matrix-result.stdout.json
```

A case is only marked as an engine execution when the actual local engine and its Python SDK are reachable. Missing runtimes are reported as `NOT_EXECUTED_ENGINE_RUNTIME`, never as a pass.

## Temporal local/self-hosted

Pinned evaluation SDK: `temporalio==1.29.0`.

```bash
python -m venv .venv-temporal
. .venv-temporal/bin/activate
pip install temporalio==1.29.0
mkdir -p .state
temporal server start-dev
# second terminal
python temporal_harness.py
```

Temporal uses a Workflow signal for approve/reject, a server-backed workflow timer, and an Activity for the evidence-only side effect. `fail_after_commit_once` commits the SQLite evidence row and then fails once; the Activity retry must leave exactly one evidence row.

For the failure matrix: start a workflow with a unique run ID; kill/restart the worker during pending approval; signal approve/reject; send duplicate signals where required; and verify the workflow result and SQLite evidence count. Server state must remain intact while only the worker process is restarted.

## Restate local/self-hosted

Pinned evaluation SDK: `restate_sdk[serde]==1.0.3`.

```bash
python -m venv .venv-restate
. .venv-restate/bin/activate
pip install 'restate_sdk[serde]==1.0.3' 'hypercorn>=0.17,<1'
restate-server
# second terminal
python restate_service.py
# third terminal
restate deployments register http://localhost:9080
```

Restate uses a Workflow durable promise named `approval`; `resolve_approval` resolves that promise; `restate.select` races approval with a durable timer; `ctx.run_typed` journals the evidence-only side-effect step. Restart the service process for recovery cases while keeping the Restate server data intact.

## Evaluation rule

Do not select an engine from documentation alone. A recommendation is valid only after both actual self-hosted runtimes execute the same ten cases and produce machine-readable evidence. Any environment that cannot start the server/SDK remains `blocked`, not `failed` and not `passed`.
