#!/usr/bin/env python3
"""Parse Visual Studio TRX test results into EE-bench JSON.

For C#/.NET projects using dotnet test with TRX logger.

Usage: python3 ee_bench_parser_trx.py <artifacts_dir>
"""
import json
import os
import sys
import xml.etree.ElementTree as ET

MAX_STACKTRACE = 4096


def _truncate(text, limit=MAX_STACKTRACE):
    if text and len(text) > limit:
        return text[:limit] + "\n... [truncated]"
    return text


def parse_trx(root):
    """Parse Visual Studio TRX format."""
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

        entry = {"name": name, "duration_seconds": duration}

        if outcome == "passed":
            entry["status"] = "passed"
        elif outcome in ("failed", "error"):
            entry["status"] = "failed"
            entry["type"] = "error" if outcome == "error" else "assertion"
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


def detect_and_parse(artifacts_dir):
    """Scan artifacts dir for TRX/XML files and parse them."""
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
            methods.extend(parse_trx(root))

    return methods


def aggregate(methods):
    """Build summary and test lists from parsed method results."""
    passed_names = []
    failed_names = []
    skipped_names = []
    total_duration = 0.0
    n_errors = 0

    for m in methods:
        total_duration += m.get("duration_seconds", 0.0)
        status = m["status"]
        if status == "passed":
            passed_names.append(m["name"])
        elif status == "failed":
            failed_names.append(m["name"])
            if m.get("type") == "error":
                n_errors += 1
        elif status == "skipped":
            skipped_names.append(m["name"])

    return {
        "summary": {
            "total": len(methods),
            "passed": len(passed_names),
            "failed": len(failed_names) - n_errors,
            "errors": n_errors,
            "skipped": len(skipped_names),
            "duration_seconds": round(total_duration, 3),
        },
        "passed_tests": [{"name": n} for n in sorted(set(passed_names))],
        "failed_tests": [{"name": n} for n in sorted(set(failed_names))],
        "skipped_tests": [{"name": n} for n in sorted(set(skipped_names))],
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
