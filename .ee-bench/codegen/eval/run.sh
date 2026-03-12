#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${EE_BENCH_PROJECT_ROOT:-/app}"
EVAL_DIR="/ee-bench/eval"
SUBMISSION_DIR="/ee-bench/submission"
export ARTIFACTS_DIR="/tmp/test-results"
mkdir -p "$ARTIFACTS_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OVERALL_START=$SECONDS
MAX_OUTPUT=51200  # 50K truncation limit

_elapsed() { echo $(( SECONDS - ${1:-$OVERALL_START} )); }

_capture_output() {
  local file="$1" limit="${2:-$MAX_OUTPUT}"
  if [ -f "$file" ]; then
    head -c "$limit" "$file"
  fi
}

cd "$PROJECT_ROOT"

# --- Reset to base commit ---
git reset --hard "{{ instance.base_commit }}" 2>/dev/null
git clean -fdx 2>/dev/null

# ============================================================
# CRITERION 1: patch_applied
# ============================================================
PATCH_START=$SECONDS
PATCH_STATUS="pass"
PATCH_OUTPUT=""
if [ -f "$SUBMISSION_DIR/patch.diff" ]; then
  PATCH_OUTPUT=$(git apply -v "$SUBMISSION_DIR/patch.diff" 2>&1) || {
    PATCH_STATUS="fail"
    echo "WARN: git apply failed for submission patch" >&2
  }
fi
PATCH_DURATION=$(_elapsed $PATCH_START)

# --- Apply test patch (informational, not a criterion) ---
if [ -f "$EVAL_DIR/test_patch.diff" ]; then
  git apply -v "$EVAL_DIR/test_patch.diff" 2>/dev/null || true
fi

# ============================================================
# CRITERION 2: compilation
# ============================================================
COMPILE_START=$SECONDS
COMPILE_STATUS="pass"
bash "$EVAL_DIR/scripts/install.sh" > /tmp/compile_stdout.log 2> /tmp/compile_stderr.log || {
  COMPILE_STATUS="fail"
}
COMPILE_DURATION=$(_elapsed $COMPILE_START)
COMPILE_OUTPUT=$(_capture_output /tmp/compile_stdout.log)
COMPILE_STDERR=$(_capture_output /tmp/compile_stderr.log)

# ============================================================
# CRITERION 3: tests
# ============================================================
TEST_START=$SECONDS
set +e
dotnet test {{ instance.test_framework_flag }} "{{ instance.test_project }}" --logger "{{ instance.test_logger }}" > /tmp/test_stdout.log 2> /tmp/test_stderr.log
TEST_EXIT=$?
set -e
TEST_DURATION=$(_elapsed $TEST_START)
TEST_OUTPUT=$(_capture_output /tmp/test_stdout.log)
TEST_STDERR=$(_capture_output /tmp/test_stderr.log)

# --- Parse results (stdout = JSON) ---
PARSER_JSON=$(python3 "$EVAL_DIR/scripts/parser.py" "$ARTIFACTS_DIR" 2>/dev/null || echo '{}')

OVERALL_DURATION=$(_elapsed $OVERALL_START)

# --- Write temp files for safe passing to Python emitter ---
echo "$PATCH_OUTPUT" > /tmp/_patch_output.txt
echo "$COMPILE_OUTPUT" > /tmp/_compile_output.txt
printf '%s\n%s' "$COMPILE_STDERR" "" >> /tmp/_compile_output.txt
echo "$TEST_OUTPUT" > /tmp/_test_output.txt
printf '%s\n%s' "$TEST_STDERR" "" >> /tmp/_test_output.txt
echo "$PARSER_JSON" > /tmp/_parser.json

# ============================================================
# Emit EE-bench JSON v2.0
# ============================================================
export PATCH_STATUS PATCH_DURATION COMPILE_STATUS COMPILE_DURATION
export TEST_DURATION OVERALL_DURATION TIMESTAMP

python3 -c "
import json, sys, os

def read_file(path, limit=51200):
    try:
        with open(path) as f:
            return f.read(limit)
    except Exception:
        return ''

patch_status = os.environ.get('PATCH_STATUS', 'pass')
patch_duration = int(os.environ.get('PATCH_DURATION', '0'))
compile_status = os.environ.get('COMPILE_STATUS', 'pass')
compile_duration = int(os.environ.get('COMPILE_DURATION', '0'))
test_duration = int(os.environ.get('TEST_DURATION', '0'))
overall_duration = int(os.environ.get('OVERALL_DURATION', '0'))
timestamp = os.environ.get('TIMESTAMP', '')

patch_output = read_file('/tmp/_patch_output.txt')
compile_output = read_file('/tmp/_compile_output.txt')
test_output = read_file('/tmp/_test_output.txt')

try:
    with open('/tmp/_parser.json') as f:
        parser_data = json.load(f)
except Exception:
    parser_data = {}

summary = parser_data.get('summary', {
    'total': 0, 'passed': 0, 'failed': 0, 'errors': 0, 'skipped': 0, 'duration_seconds': 0.0,
})
passed_tests = parser_data.get('passed_tests', [])
failed_tests = parser_data.get('failed_tests', [])
skipped_tests = parser_data.get('skipped_tests', [])
methods = parser_data.get('methods', [])

has_failures = parser_data.get('failed', 0) > 0
test_status = 'fail' if has_failures else 'pass'

result = {
    'schema_version': '2.0',
    'command': 'run',
    'status': 'success' if patch_status == 'pass' and compile_status == 'pass' else 'failure',
    'timestamp': timestamp,
    'duration_seconds': overall_duration,
    'criteria': [
        {
            'criterion': 'patch_applied',
            'status': patch_status,
            'duration_seconds': patch_duration,
            'output': patch_output[:51200],
        },
        {
            'criterion': 'compilation',
            'status': compile_status,
            'duration_seconds': compile_duration,
            'output': compile_output[:51200],
        },
        {
            'criterion': 'tests',
            'status': test_status,
            'duration_seconds': test_duration,
            'output': test_output[:51200],
            'summary': summary,
            'passed_tests': passed_tests,
            'failed_tests': failed_tests,
            'skipped_tests': skipped_tests,
            'methods': methods,
        },
    ],
}
print(json.dumps(result))
"
