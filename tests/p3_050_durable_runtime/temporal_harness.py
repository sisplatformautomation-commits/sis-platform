"""Temporal P3-050 local/self-hosted harness.

Requires temporalio==1.29.0 and a local `temporal server start-dev`.
No provider/Gmail client exists here; the only side effect is local SQLite evidence.
"""
from __future__ import annotations

import asyncio
import os
import sqlite3
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path
from typing import Optional

from temporalio import activity, workflow
from temporalio.client import Client
from temporalio.common import RetryPolicy
from temporalio.worker import Worker

TASK_QUEUE = "p3-050-durable-eval"
DB_PATH = Path(os.getenv("P3_050_EVIDENCE_DB", ".state/p3_050_evidence.sqlite3"))


@dataclass
class WorkflowInput:
    case_key: str
    run_id: str
    approval_timeout_seconds: int = 5
    fail_after_commit_once: bool = False


@dataclass
class ApprovalSignal:
    approval_id: str
    decision: str


@dataclass
class EvidenceInput:
    run_id: str
    case_key: str
    idempotency_key: str
    fail_after_commit_once: bool = False


def _db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("create table if not exists evidence (idempotency_key text primary key, run_id text not null, case_key text not null, committed_at text default current_timestamp)")
    conn.execute("create table if not exists failures (idempotency_key text primary key, injected integer not null default 0)")
    return conn


@activity.defn
async def record_evidence(inp: EvidenceInput) -> dict:
    conn = _db()
    with conn:
        conn.execute("insert or ignore into evidence(idempotency_key,run_id,case_key) values(?,?,?)", (inp.idempotency_key, inp.run_id, inp.case_key))
        count = conn.execute("select count(*) from evidence where idempotency_key=?", (inp.idempotency_key,)).fetchone()[0]
        injected = conn.execute("select injected from failures where idempotency_key=?", (inp.idempotency_key,)).fetchone()
        if inp.fail_after_commit_once and injected is None:
            conn.execute("insert into failures(idempotency_key,injected) values(?,1)", (inp.idempotency_key,))
            conn.commit()
            raise RuntimeError("P3_050_INJECTED_FAILURE_AFTER_EVIDENCE_COMMIT")
    conn.close()
    return {"evidence_count": int(count), "provider_write_performed": False, "mail_write_performed": False}


@workflow.defn
class P3050TemporalWorkflow:
    def __init__(self) -> None:
        self._decision: Optional[str] = None
        self._approval_id: Optional[str] = None
        self._duplicate_signals = 0

    @workflow.signal
    def resolve_approval(self, signal: ApprovalSignal) -> None:
        if self._approval_id is None:
            self._approval_id = signal.approval_id
            self._decision = signal.decision
        elif self._approval_id == signal.approval_id:
            self._duplicate_signals += 1

    @workflow.query
    def state(self) -> dict:
        return {"decision": self._decision, "approval_id": self._approval_id, "duplicate_signals": self._duplicate_signals}

    @workflow.run
    async def run(self, inp: WorkflowInput) -> dict:
        try:
            await workflow.wait_condition(lambda: self._decision in ("approve", "reject"), timeout=timedelta(seconds=inp.approval_timeout_seconds))
        except asyncio.TimeoutError:
            return {"case": inp.case_key, "resolution": "timeout", "evidence_count": 0, "duplicate_signals": self._duplicate_signals, "provider_write_performed": False, "mail_write_performed": False}

        if self._decision == "reject":
            return {"case": inp.case_key, "resolution": "reject", "evidence_count": 0, "duplicate_signals": self._duplicate_signals, "provider_write_performed": False, "mail_write_performed": False}

        evidence = await workflow.execute_activity(
            record_evidence,
            EvidenceInput(run_id=inp.run_id, case_key=inp.case_key, idempotency_key=f"{inp.run_id}:evidence", fail_after_commit_once=inp.fail_after_commit_once),
            start_to_close_timeout=timedelta(seconds=10),
            retry_policy=RetryPolicy(maximum_attempts=3),
        )
        return {"case": inp.case_key, "resolution": "approve", "evidence_count": evidence["evidence_count"], "duplicate_signals": self._duplicate_signals, "provider_write_performed": False, "mail_write_performed": False}


async def run_worker() -> None:
    client = await Client.connect("127.0.0.1:7233")
    worker = Worker(client, task_queue=TASK_QUEUE, workflows=[P3050TemporalWorkflow], activities=[record_evidence])
    await worker.run()


if __name__ == "__main__":
    asyncio.run(run_worker())
