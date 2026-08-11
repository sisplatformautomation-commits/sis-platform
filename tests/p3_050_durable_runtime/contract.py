from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
from typing import Iterable

WORK_ITEM = "P3-050"
REFERENCE_WORKFLOW = "P3-049 Agents-SDK HITL GMA-002 evidence-only pilot"
RESOURCE_KEY = "make.gmail_trash.test.sis_internal_hospitality"
ACTION_KEY = "gmail.trash"
AUTHORIZATION_DECISION = "APPROVAL_REQUIRED"


class Resolution(str, Enum):
    APPROVE = "approve"
    REJECT = "reject"
    TIMEOUT = "timeout"


@dataclass(frozen=True)
class MatrixCase:
    key: str
    purpose: str
    expected_resolution: Resolution | None
    expected_evidence_count: int | None
    requires_runtime_restart: bool = False
    requires_service_restart: bool = False
    requires_duplicate_signal: bool = False
    requires_fail_after_side_effect_commit: bool = False
    requires_timer: bool = False


CASES: tuple[MatrixCase, ...] = (
    MatrixCase("baseline_pause_approve_resume", "Pause on APPROVAL_REQUIRED, approve, then resume.", Resolution.APPROVE, 1),
    MatrixCase("baseline_pause_reject_resume", "Pause on APPROVAL_REQUIRED, reject, then resume without evidence action.", Resolution.REJECT, 0),
    MatrixCase("process_crash_while_waiting_for_approval", "Restart worker/service while approval is pending, then approve and resume.", Resolution.APPROVE, 1, requires_runtime_restart=True, requires_service_restart=True),
    MatrixCase("process_crash_after_approval_before_side_effect_ack", "Commit the evidence-only side effect, fail before acknowledgement, retry idempotently.", Resolution.APPROVE, 1, requires_fail_after_side_effect_commit=True),
    MatrixCase("duplicate_approval_signal_idempotency", "Deliver the same approval twice and prove one logical resolution / one evidence action.", Resolution.APPROVE, 1, requires_duplicate_signal=True),
    MatrixCase("durable_timeout_and_timer_recovery", "Let the durable approval timer expire across a restart.", Resolution.TIMEOUT, 0, requires_runtime_restart=True, requires_service_restart=True, requires_timer=True),
    MatrixCase("worker_restart_and_resume", "Restart the execution worker after workflow start and complete normally.", Resolution.APPROVE, 1, requires_runtime_restart=True, requires_service_restart=True),
    MatrixCase("trace_and_work_item_correlation", "Preserve P3-050/P3-049 correlation and stable run identity across resume.", Resolution.APPROVE, 1),
    MatrixCase("deployment_and_versioning_behavior", "Record engine deployment/version identity and prove a pending run remains addressable after worker redeploy.", Resolution.APPROVE, 1, requires_runtime_restart=True, requires_service_restart=True),
    MatrixCase("operational_footprint_and_security", "Verify local-only endpoints, no provider write, no secret-bearing result payload and durable-state visibility.", None, None),
)


def case_keys() -> list[str]:
    return [case.key for case in CASES]


def validate_contract() -> list[str]:
    errors: list[str] = []
    keys = case_keys()
    if len(keys) != 10:
        errors.append(f"expected_10_cases_got_{len(keys)}")
    if len(set(keys)) != len(keys):
        errors.append("duplicate_case_keys")
    for case in CASES:
        if case.expected_resolution == Resolution.REJECT and case.expected_evidence_count != 0:
            errors.append(f"{case.key}:reject_must_not_execute_evidence")
        if case.expected_resolution == Resolution.TIMEOUT and case.expected_evidence_count != 0:
            errors.append(f"{case.key}:timeout_must_not_execute_evidence")
        if case.expected_resolution == Resolution.APPROVE and case.expected_evidence_count != 1:
            errors.append(f"{case.key}:approve_must_execute_exactly_once")
    return errors


def public_contract() -> dict:
    return {
        "work_item": WORK_ITEM,
        "reference_workflow": REFERENCE_WORKFLOW,
        "authorization_decision": AUTHORIZATION_DECISION,
        "resource_key": RESOURCE_KEY,
        "action_key": ACTION_KEY,
        "safety": {
            "prod_changes": False,
            "provider_write_performed": False,
            "mail_write_performed": False,
            "external_financial_writes": False,
            "evidence_only_side_effect": True,
        },
        "cases": [{**asdict(case), "expected_resolution": case.expected_resolution.value if case.expected_resolution else None} for case in CASES],
    }


def assert_safe_result(result: dict) -> None:
    for field in ("provider_write_performed", "mail_write_performed", "prod_changes", "external_financial_writes"):
        if result.get(field) is True:
            raise AssertionError(f"unsafe_result:{field}")


def require_all_case_keys(observed: Iterable[str]) -> None:
    observed_set = set(observed)
    expected_set = set(case_keys())
    if observed_set != expected_set:
        raise AssertionError(f"matrix_case_set_mismatch:missing={sorted(expected_set-observed_set)} extra={sorted(observed_set-expected_set)}")
