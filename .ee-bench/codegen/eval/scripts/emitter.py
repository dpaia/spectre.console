#!/usr/bin/env python3
"""Emit EE-bench JSON v2.0 from test results and environment.

Reads criteria status from environment variables (set by run.sh)
and parser JSON files from /tmp. Prints the result JSON to stdout.
"""
import json
import os
import sys

def read_file(path):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return ""


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def _prefix(name):
    """Strip parameterized suffix: 'Foo.Bar(x: 1)' -> 'Foo.Bar'."""
    idx = name.find("(")
    return name[:idx] if idx > 0 else name


def _test_in(name, name_set):
    """Match by exact name first, then by prefix (method name without parameters)."""
    if name in name_set:
        return True
    pfx = _prefix(name)
    return any(n == pfx or _prefix(n) == pfx for n in name_set)


def _evaluate_criterion(expected, eval_passed, baseline_passed, baseline_failed,
                         has_test_patch, expect_pass_in_eval, empty_label, success_msg):
    """Evaluate a fail_to_pass or pass_to_pass criterion.

    Args:
        expected: list of expected test names
        eval_passed: set of test names that passed in eval run
        baseline_passed: set of test names that passed in baseline run
        has_test_patch: whether a test patch exists
        expect_pass_in_eval: True = tests must pass in eval (p2p/f2p),
                             always True for both criteria
        empty_label: message when expected list is empty
        success_msg: message when all checks pass
    Returns:
        (status, detail) tuple
    """
    if not expected:
        return empty_label

    eval_ok = all(_test_in(t, eval_passed) for t in expected)
    if has_test_patch:
        # Baseline uses exact match only. If a test name doesn't appear in
        # baseline results at all (e.g. added by test_patch), skip it.
        baseline_bad = []
        for t in expected:
            if t not in baseline_passed and t not in baseline_failed:
                continue  # test not in baseline — likely added by test_patch
            in_passed = t in baseline_passed
            if in_passed != expect_pass_in_eval:
                baseline_bad.append(t)
        baseline_ok = not baseline_bad
    else:
        baseline_ok = True
        baseline_bad = []

    status = "pass" if (eval_ok and baseline_ok) else "fail"
    detail_parts = []
    if not eval_ok:
        missing = [t for t in expected if not _test_in(t, eval_passed)]
        detail_parts.append("eval missing: " + ", ".join(missing[:10]))
    if not baseline_ok:
        label = "baseline unexpected pass" if not expect_pass_in_eval else "baseline missing"
        detail_parts.append(label + ": " + ", ".join(baseline_bad[:10]))

    return status, "; ".join(detail_parts) if detail_parts else success_msg


def main():
    patch_status = os.environ.get("PATCH_STATUS", "pass")
    patch_duration = int(os.environ.get("PATCH_DURATION", "0"))
    compile_status = os.environ.get("COMPILE_STATUS", "pass")
    compile_duration = int(os.environ.get("COMPILE_DURATION", "0"))
    test_duration = int(os.environ.get("TEST_DURATION", "0"))
    baseline_duration = int(os.environ.get("BASELINE_DURATION", "0"))
    overall_duration = int(os.environ.get("OVERALL_DURATION", "0"))
    timestamp = os.environ.get("TIMESTAMP", "")
    has_test_patch = os.environ.get("HAS_TEST_PATCH", "false") == "true"

    patch_output = read_file("/tmp/_patch_output.txt")
    compile_output = read_file("/tmp/_compile_output.txt")

    # Load parser results for baseline and eval
    baseline_data = load_json("/tmp/baseline_parser.json")
    eval_data = load_json("/tmp/eval_parser.json")

    baseline_passed = {
        t["name"]
        for t in baseline_data.get("passed_tests", [])
        if isinstance(t, dict)
    }
    baseline_failed = {
        t["name"]
        for t in baseline_data.get("failed_tests", [])
        if isinstance(t, dict)
    }
    eval_passed = {
        t["name"] for t in eval_data.get("passed_tests", []) if isinstance(t, dict)
    }

    # Expected test lists (written to file by run.sh to avoid shell quoting issues)
    _expected = load_json("/tmp/_expected.json")
    expected_f2p = _expected.get("fail_to_pass", [])
    expected_p2p = _expected.get("pass_to_pass", [])

    can_run = compile_status == "pass" and patch_status in ("pass", "skipped")

    eval_summary = eval_data.get("summary", {
        "total": 0, "passed": 0, "failed": 0,
        "errors": 0, "skipped": 0, "duration_seconds": 0.0,
    })

    # --- Criterion: baseline_tests ---
    baseline_status = "pass" if has_test_patch and compile_status == "pass" else "skipped"

    # --- Criterion: tests (eval run) ---
    if not can_run:
        tests_status = "skipped"
    else:
        tests_status = "fail" if eval_summary.get("failed", 0) > 0 else "pass"

    # --- Criterion: fail_to_pass ---
    if not expected_f2p:
        f2p_status, f2p_detail = "fail", "no expected fail_to_pass tests defined"
    elif not can_run:
        f2p_status, f2p_detail = "skipped", "skipped due to compilation or patch failure"
    else:
        f2p_status, f2p_detail = _evaluate_criterion(
            expected_f2p, eval_passed, baseline_passed, baseline_failed, has_test_patch,
            expect_pass_in_eval=False,
            empty_label=("fail", "no expected fail_to_pass tests defined"),
            success_msg="all fail_to_pass tests fixed",
        )

    # --- Criterion: pass_to_pass ---
    if not expected_p2p:
        p2p_status, p2p_detail = "skipped", "no expected pass_to_pass tests"
    elif not can_run:
        p2p_status, p2p_detail = "skipped", "skipped due to compilation or patch failure"
    else:
        p2p_status, p2p_detail = _evaluate_criterion(
            expected_p2p, eval_passed, baseline_passed, baseline_failed, has_test_patch,
            expect_pass_in_eval=True,
            empty_label=("skipped", "no expected pass_to_pass tests"),
            success_msg="all pass_to_pass tests still passing",
        )

    # --- Overall status ---
    has_failure = any(
        s == "fail" for s in [compile_status, patch_status, f2p_status, p2p_status]
    )
    overall_status = "failure" if has_failure else "success"

    eval_test_output = read_file("/tmp/eval_stdout.log") + read_file(
        "/tmp/eval_stderr.log"
    )

    result = {
        "schema_version": "2.0",
        "status": overall_status,
        "timestamp": timestamp,
        "duration_seconds": overall_duration,
        "criteria": [
            {
                "criterion": "compilation",
                "status": compile_status,
                "duration_seconds": compile_duration,
                "output": compile_output,
            },
            {
                "criterion": "baseline_tests",
                "status": baseline_status,
                "duration_seconds": baseline_duration,
                "passed_tests": list(baseline_passed),
                "failed_tests": baseline_data.get("failed_tests", []),
            },
            {
                "criterion": "patch_applied",
                "status": patch_status,
                "duration_seconds": patch_duration,
                "output": patch_output,
            },
            {
                "criterion": "tests",
                "status": tests_status,
                "duration_seconds": test_duration,
                "output": eval_test_output,
                "summary": eval_summary,
                "passed_tests": eval_data.get("passed_tests", []),
                "failed_tests": eval_data.get("failed_tests", []),
                "skipped_tests": eval_data.get("skipped_tests", []),
                "methods": eval_data.get("methods", []),
            },
            {
                "criterion": "fail_to_pass",
                "status": f2p_status,
                "expected": expected_f2p,
                "detail": f2p_detail,
            },
            {
                "criterion": "pass_to_pass",
                "status": p2p_status,
                "expected": expected_p2p,
                "detail": p2p_detail,
            },
        ],
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
