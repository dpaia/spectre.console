#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="${EE_BENCH_PROJECT_ROOT:-/app}"
EVAL_DIR="/ee-bench/eval"
SUBMISSION_DIR="/ee-bench/submission"
export ARTIFACTS_DIR="/tmp/test-results"
mkdir -p "$ARTIFACTS_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OVERALL_START=$SECONDS

_elapsed() { echo $(( SECONDS - ${1:-$OVERALL_START} )); }

# --- _run_tests: run dotnet test with isolated ARTIFACTS_DIR ---
# Usage: _run_tests <label>
# Writes: /tmp/<label>_stdout.log, /tmp/<label>_stderr.log, /tmp/<label>_parser.json
_run_tests() {
  local label="$1"
  local orig_artifacts="$ARTIFACTS_DIR"
  export ARTIFACTS_DIR="$orig_artifacts/$label"
  mkdir -p "$ARTIFACTS_DIR"

  set +e
  dotnet test --no-build {{ instance.test_framework_flag }} "{{ instance.test_project }}" \
    --logger "{{ instance.test_logger }}" \
    --results-directory "$ARTIFACTS_DIR" \
    > "/tmp/${label}_stdout.log" 2> "/tmp/${label}_stderr.log"
  local test_exit=$?
  set -e
  echo "$test_exit" > "/tmp/${label}_exit_code"

  python3 "$EVAL_DIR/scripts/ee_bench_parser_trx.py" "$ARTIFACTS_DIR" > "/tmp/${label}_parser.json" 2>/dev/null || echo '{}' > "/tmp/${label}_parser.json"

  export ARTIFACTS_DIR="$orig_artifacts"
}

cd "$PROJECT_ROOT"

# --- Reset to base commit (only if EE_BENCH_RESET is set) ---
if [ -n "${EE_BENCH_RESET:-}" ]; then
  git reset --hard "{{ instance.base_commit }}" 2>/dev/null
  git clean -fdx 2>/dev/null
fi

# ============================================================
# Criterion: compilation (clean base, before test_patch)
# ============================================================
COMPILE_START=$SECONDS
COMPILE_STATUS="pass"
bash "$EVAL_DIR/scripts/install.sh" > /tmp/compile_stdout.log 2> /tmp/compile_stderr.log || {
  COMPILE_STATUS="fail"
}
COMPILE_DURATION=$(_elapsed $COMPILE_START)

# ============================================================
# Run baseline tests (clean base, before test_patch)
# Establishes pass_to_pass baseline and fail_to_pass baseline.
# ============================================================
HAS_TEST_PATCH="false"
if [ -f "$EVAL_DIR/test_patch.diff" ]; then
  HAS_TEST_PATCH="true"
fi

BASELINE_DURATION=0
BASELINE_TEST_EXIT_CODE=0
if [ "$COMPILE_STATUS" = "pass" ]; then
  BASELINE_START=$SECONDS
  _run_tests baseline
  BASELINE_TEST_EXIT_CODE="$(cat /tmp/baseline_exit_code 2>/dev/null || echo 0)"
  BASELINE_DURATION=$(_elapsed $BASELINE_START)
fi

# ============================================================
# Apply test patch (after baseline, before gold patch)
# ============================================================
if [ "$HAS_TEST_PATCH" = "true" ]; then
  git apply -v "$EVAL_DIR/test_patch.diff" 2>/dev/null || true
fi

# ============================================================
# Criterion: patch_applied (submission patch)
# ============================================================
PATCH_START=$SECONDS
PATCH_STATUS="pass"
PATCH_OUTPUT=""
if [ -f "$SUBMISSION_DIR/patch.diff" ]; then
  PATCH_OUTPUT=$(git apply -v "$SUBMISSION_DIR/patch.diff" 2>&1) || {
    PATCH_STATUS="fail"
    echo "WARN: git apply failed for submission patch" >&2
  }
else
  PATCH_STATUS="skipped"
fi
PATCH_DURATION=$(_elapsed $PATCH_START)

# ============================================================
# Rebuild after test_patch and/or submission patch
# ============================================================
# Must also rebuild when test_patch was applied — dotnet test --no-build
# would otherwise run the pre-test_patch DLL and miss any newly added tests.
REBUILD_STATUS="skipped"
if [ "$PATCH_STATUS" = "pass" ] || [ "$HAS_TEST_PATCH" = "true" ]; then
  bash "$EVAL_DIR/scripts/install.sh" > /tmp/rebuild_stdout.log 2> /tmp/rebuild_stderr.log || {
    REBUILD_STATUS="fail"
  }
  if [ "$REBUILD_STATUS" != "fail" ]; then
    REBUILD_STATUS="pass"
    COMPILE_STATUS="pass"
  fi
fi

# ============================================================
# Run eval tests (only if rebuild/compilation OK and patch not failed)
# ============================================================
TEST_DURATION=0
EVAL_TEST_EXIT_CODE=0
if [ "$REBUILD_STATUS" = "pass" ] || ([ "$COMPILE_STATUS" = "pass" ] && [ "$PATCH_STATUS" != "fail" ]); then
  TEST_START=$SECONDS
  _run_tests eval
  EVAL_TEST_EXIT_CODE="$(cat /tmp/eval_exit_code 2>/dev/null || echo 0)"
  TEST_DURATION=$(_elapsed $TEST_START)
fi

OVERALL_DURATION=$(_elapsed $OVERALL_START)

# --- Write temp files for safe passing to Python emitter ---
echo "$PATCH_OUTPUT" > /tmp/_patch_output.txt
cat /tmp/compile_stdout.log /tmp/compile_stderr.log > /tmp/_compile_output.txt 2>/dev/null || true

# --- Write expected test lists to file (avoids shell quoting issues) ---
cat > /tmp/_expected.json << 'EXPECTED_EOF'
{"fail_to_pass": {{ instance.expected.fail_to_pass | tojson }}, "pass_to_pass": {{ instance.expected.pass_to_pass | tojson }}, "fail_to_fail": {{ instance.expected.fail_to_fail | default([]) | tojson }}, "fail_to_fail_strict": {{ instance.expected.fail_to_fail_strict | default(true) | tojson }}}
EXPECTED_EOF

# ============================================================
# Emit EE-bench JSON v2.0 (7 criteria)
# ============================================================
export PATCH_STATUS PATCH_DURATION COMPILE_STATUS COMPILE_DURATION
export TEST_DURATION BASELINE_DURATION OVERALL_DURATION TIMESTAMP
export HAS_TEST_PATCH BASELINE_TEST_EXIT_CODE EVAL_TEST_EXIT_CODE

python3 "$EVAL_DIR/scripts/ee_bench_eval.py"
