"""Restate P3-050 local/self-hosted harness.

Requires restate_sdk[serde]==1.0.3, Hypercorn and a local restate-server.
No provider/Gmail client exists here; the only side effect is local SQLite evidence.
"""
from __future__ import annotations

import os
import sqlite3
from datetime import timedelta
from pathlib import Path
from typing import TypedDict

import restate

DB_PATH = Path(os.getenv("P3_050_EVIDENCE_DB", ".state/p3_050_evidence.sqlite3"))
workflow_service = restate.Workflow("P3050RestateWorkflow")


class RunInput(TypedDict, total=False):
    case_key: str
    run_id: str
    approval_timeout_seconds: int
    fail_after_commit_once: bool


class ApprovalInput(TypedDict):
    approval_id: str
    decision: str


def _record_evidence(run_id: str, case_key: str, fail_after_commit_once: bool) -> dict:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("create table if not exists evidence (idempotency_key text primary key, run_id text not null, case_key text not null, committed_at text default current_timestamp)")
    conn.execute("create table if not exists failures (idempotency_key text primary key, injected integer not null default 0)")
    key = f"{run_id}:evidence"
    with conn:
        conn.execute("insert or ignore into evidence(idempotency_key,run_id,case_key) values(?,?,?)", (key, run_id, case_key))
        count = conn.execute("select count(*) from evidence where idempotency_key=?", (key,)).fetchone()[0]
        injected = conn.execute("select injected from failures where idempotency_key=?", (key,)).fetchone()
        if fail_after_commit_once and injected is None:
            conn.execute("insert into failures(idempotency_key,injected) values(?,1)", (key,))
            conn.commit()
            raise RuntimeError("P3_050_INJECTED_FAILURE_AFTER_EVIDENCE_COMMIT")
    conn.close()
    return {"evidence_count": int(count), "provider_write_performed": False, "mail_write_performed": False}


@workflow_service.main()
async def run(ctx: restate.WorkflowContext, inp: RunInput) -> dict:
    timeout = int(inp.get("approval_timeout_seconds", 5))
    approval_future = ctx.promise("approval", type_hint=dict).value()
    match await restate.select(approval=approval_future, timeout=ctx.sleep(timedelta(seconds=timeout))):
        case ["approval", approval]:
            if approval.get("decision") == "reject":
                return {"case": inp["case_key"], "resolution": "reject", "evidence_count": 0, "provider_write_performed": False, "mail_write_performed": False}
            evidence = await ctx.run_typed(
                "record evidence only",
                _record_evidence,
                run_id=inp["run_id"],
                case_key=inp["case_key"],
                fail_after_commit_once=bool(inp.get("fail_after_commit_once", False)),
            )
            return {"case": inp["case_key"], "resolution": "approve", "evidence_count": evidence["evidence_count"], "provider_write_performed": False, "mail_write_performed": False}
        case _:
            return {"case": inp["case_key"], "resolution": "timeout", "evidence_count": 0, "provider_write_performed": False, "mail_write_performed": False}


@workflow_service.handler()
async def resolve_approval(ctx: restate.WorkflowSharedContext, approval: ApprovalInput) -> str:
    await ctx.promise("approval", type_hint=dict).resolve(dict(approval))
    return "accepted"


@workflow_service.handler()
async def inspect(ctx: restate.WorkflowSharedContext) -> dict:
    return {"workflow_id": ctx.key(), "work_item": "P3-050", "provider_write_performed": False, "mail_write_performed": False}


app = restate.app(services=[workflow_service])

if __name__ == "__main__":
    import asyncio
    import hypercorn.asyncio
    from hypercorn.config import Config

    config = Config()
    config.bind = ["127.0.0.1:9080"]
    asyncio.run(hypercorn.asyncio.serve(app, config))
