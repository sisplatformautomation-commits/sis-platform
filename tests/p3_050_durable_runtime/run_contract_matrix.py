from __future__ import annotations

import importlib.util
import json
import shutil
import socket
from datetime import datetime, timezone
from pathlib import Path

from contract import CASES, public_contract, validate_contract

ROOT = Path(__file__).resolve().parent


def port_open(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.25):
            return True
    except OSError:
        return False


def module_available(name: str) -> bool:
    return importlib.util.find_spec(name) is not None


def engine_preflight(engine: str) -> dict:
    if engine == "temporal":
        return {
            "engine": "Temporal",
            "server_binary": shutil.which("temporal"),
            "python_module": module_available("temporalio"),
            "server_reachable": port_open("127.0.0.1", 7233),
            "required_server_port": 7233,
        }
    if engine == "restate":
        return {
            "engine": "Restate",
            "server_binary": shutil.which("restate-server"),
            "cli_binary": shutil.which("restate"),
            "python_module": module_available("restate"),
            "server_reachable": port_open("127.0.0.1", 9070),
            "required_server_port": 9070,
        }
    raise ValueError(engine)


def classify(preflight: dict) -> str:
    if preflight["server_reachable"] and preflight["python_module"]:
        return "READY_FOR_ENGINE_MATRIX"
    return "BLOCKED_RUNTIME_NOT_AVAILABLE"


def main() -> int:
    contract_errors = validate_contract()
    engines = []
    # Required evaluation order: Temporal first, then Restate.
    for key in ("temporal", "restate"):
        preflight = engine_preflight(key)
        status = classify(preflight)
        engines.append({
            **preflight,
            "status": status,
            "cases": [{
                "case": case.key,
                "status": "NOT_EXECUTED_ENGINE_RUNTIME" if status != "READY_FOR_ENGINE_MATRIX" else "READY",
                "expected_resolution": case.expected_resolution.value if case.expected_resolution else None,
                "expected_evidence_count": case.expected_evidence_count,
            } for case in CASES],
        })

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "contract_validation": "PASS" if not contract_errors else "FAIL",
        "contract_errors": contract_errors,
        "contract": public_contract(),
        "engines": engines,
        "engine_selection_made": False,
        "provider_write_performed": False,
        "mail_write_performed": False,
        "prod_changes": False,
        "external_financial_writes": False,
    }
    (ROOT / "matrix-result.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if not contract_errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
