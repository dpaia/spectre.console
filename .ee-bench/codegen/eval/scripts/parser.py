#!/usr/bin/env python3
"""Parse C# test result logs (JUnit XML or TRX) into EE-bench JSON."""
import json
import os
import sys
import xml.etree.ElementTree as ET

MAX_STACKTRACE = 4096


def _truncate(text: str, limit: int = MAX_STACKTRACE) -> str:
    if text and len(text) > limit:
        return text[:limit] + "\n... [truncated]"
    return text


def parse_junit_xml(path: str) -> list[dict]:
    """Parse JUnit XML format (<testsuites><testsuite><testcase>)."""
    tree = ET.parse(path)
    root = tree.getroot()
    methods = []

    if root.tag == "testsuite":
        suites = [root]
    elif root.tag == "testsuites":
        suites = root.findall("testsuite")
    else:
        suites = root.findall(".//testsuite")

    for suite in suites:
        for tc in suite.findall("testcase"):
            name = tc.get("name", "unknown")
            classname = tc.get("classname", "")
            full_name = f"{classname}.{name}" if classname else name

            duration = 0.0
            try:
                duration = float(tc.get("time", "0"))
            except (ValueError, TypeError):
                pass

            entry = {
                "name": full_name,
                "duration_seconds": duration,
            }

            failure = tc.find("failure")
            error = tc.find("error")
            skipped = tc.find("skipped")

            if failure is not None:
                entry["status"] = "failed"
                entry["type"] = "assertion"
                entry["message"] = failure.get("message", "")
                entry["stacktrace"] = _truncate(failure.text or "")
            elif error is not None:
                entry["status"] = "failed"
                entry["type"] = "error"
                entry["message"] = error.get("message", "")
                entry["stacktrace"] = _truncate(error.text or "")
            elif skipped is not None:
                entry["status"] = "skipped"
                msg = skipped.get("message", "") or (skipped.text or "")
                if msg:
                    entry["message"] = msg
            else:
                entry["status"] = "passed"

            methods.append(entry)
    return methods


def parse_trx(path: str) -> list[dict]:
    """Parse Visual Studio TRX format."""
    tree = ET.parse(path)
    root = tree.getroot()
    ns = {"t": "http://microsoft.com/schemas/VisualStudio/TeamTest/2010"}
    methods = []

    for result in root.findall(".//t:UnitTestResult", ns):
        name = result.get("testName", "unknown")
        outcome = result.get("outcome", "").lower()

        # Parse duration HH:MM:SS.mmmmmmm
        duration = 0.0
        dur_str = result.get("duration", "")
        if dur_str:
            try:
                parts = dur_str.split(":")
                if len(parts) == 3:
                    h, m = int(parts[0]), int(parts[1])
                    s = float(parts[2])
                    duration = h * 3600 + m * 60 + s
            except (ValueError, IndexError):
                pass

        entry = {
            "name": name,
            "duration_seconds": duration,
        }

        if outcome == "passed":
            entry["status"] = "passed"
        elif outcome in ("failed", "error"):
            entry["status"] = "failed"
            entry["type"] = "error" if outcome == "error" else "assertion"
            # Extract message and stacktrace from <Output><ErrorInfo>
            error_info = result.find("t:Output/t:ErrorInfo", ns)
            if error_info is not None:
                msg_el = error_info.find("t:Message", ns)
                st_el = error_info.find("t:StackTrace", ns)
                if msg_el is not None and msg_el.text:
                    entry["message"] = msg_el.text
                if st_el is not None and st_el.text:
                    entry["stacktrace"] = _truncate(st_el.text)
        elif outcome in ("notexecuted", "inconclusive"):
            entry["status"] = "skipped"
        else:
            entry["status"] = "failed"

        methods.append(entry)
    return methods


def detect_and_parse(artifacts_dir: str) -> list[dict]:
    """Scan artifacts dir for XML/TRX files and parse them."""
    methods = []
    for fname in sorted(os.listdir(artifacts_dir)):
        fpath = os.path.join(artifacts_dir, fname)
        if not os.path.isfile(fpath):
            continue
        try:
            tree = ET.parse(fpath)
            root = tree.getroot()
        except ET.ParseError:
            continue

        ns_tag = root.tag
        if "TestRun" in ns_tag or "VisualStudio" in ns_tag:
            methods.extend(parse_trx(fpath))
        elif root.tag in ("testsuites", "testsuite"):
            methods.extend(parse_junit_xml(fpath))
        else:
            if root.findall(".//testcase"):
                methods.extend(parse_junit_xml(fpath))

    return methods


def aggregate(methods: list[dict]) -> dict:
    """Build class-level aggregation and summary from method-level results."""
    passed_classes = set()
    failed_classes = set()
    skipped_classes = set()
    total_duration = 0.0

    for m in methods:
        cls = m["name"].rsplit(".", 1)[0] if "." in m["name"] else m["name"]
        total_duration += m.get("duration_seconds", 0.0)
        if m["status"] == "passed":
            passed_classes.add(cls)
        elif m["status"] == "failed":
            failed_classes.add(cls)
        elif m["status"] == "skipped":
            skipped_classes.add(cls)

    # A class that has any failure is failed, not passed
    passed_classes -= failed_classes
    passed_classes -= skipped_classes

    passed_tests = [{"name": c} for c in sorted(passed_classes)]
    failed_tests = [{"name": c} for c in sorted(failed_classes)]
    skipped_tests = [{"name": c} for c in sorted(skipped_classes)]

    n_passed = sum(1 for m in methods if m["status"] == "passed")
    n_failed = sum(1 for m in methods if m["status"] == "failed" and m.get("type") != "error")
    n_errors = sum(1 for m in methods if m["status"] == "failed" and m.get("type") == "error")
    n_skipped = sum(1 for m in methods if m["status"] == "skipped")

    summary = {
        "total": len(methods),
        "passed": n_passed,
        "failed": n_failed,
        "errors": n_errors,
        "skipped": n_skipped,
        "duration_seconds": round(total_duration, 3),
    }

    return {
        "total": len(methods),
        "passed": n_passed,
        "failed": n_failed + n_errors,
        "summary": summary,
        "passed_tests": passed_tests,
        "failed_tests": failed_tests,
        "skipped_tests": skipped_tests,
        "methods": methods,
    }


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <artifacts_dir>", file=sys.stderr)
        sys.exit(1)

    artifacts_dir = sys.argv[1]
    methods = detect_and_parse(artifacts_dir)
    result = aggregate(methods)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
