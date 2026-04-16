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
  dotnet test --framework net7.0 "{{ instance.test_project }}" \
    --logger "junit;LogFilePath=$ARTIFACTS_DIR/tests.log"  \
    > "/tmp/${label}_stdout.log" 2> "/tmp/${label}_stderr.log"
  set -e

  python3 "$EVAL_DIR/scripts/parser.py" "$ARTIFACTS_DIR" > "/tmp/${label}_parser.json" 2>/dev/null || echo '{}' > "/tmp/${label}_parser.json"

  export ARTIFACTS_DIR="$orig_artifacts"
}

cd "$PROJECT_ROOT"

# --- Reset to base commit (only if EE_BENCH_RESET is set) ---
if [ -n "${EE_BENCH_RESET:-}" ]; then
  git reset --hard "{{ instance.base_commit }}" 2>/dev/null
  git clean -fdx 2>/dev/null
fi

# ============================================================
# Apply test patch (setup — not a criterion)
# ============================================================
HAS_TEST_PATCH="false"
if [ -f "$EVAL_DIR/test_patch.diff" ]; then
  git apply -v "$EVAL_DIR/test_patch.diff" 2>/dev/null || true
  HAS_TEST_PATCH="true"
fi

# ============================================================
# Criterion: compilation (initial build)
# ============================================================
COMPILE_START=$SECONDS
COMPILE_STATUS="pass"
dotnet build "./src/Spectre.Console.sln" > /tmp/compile_stdout.log 2> /tmp/compile_stderr.log || {
  COMPILE_STATUS="fail"
}
COMPILE_DURATION=$(_elapsed $COMPILE_START)

# ============================================================
# Run baseline tests (only if test_patch exists)
# ============================================================
BASELINE_DURATION=0
if [ "$COMPILE_STATUS" = "pass" ] && [ "$HAS_TEST_PATCH" = "true" ]; then
  BASELINE_START=$SECONDS
  _run_tests baseline
  BASELINE_DURATION=$(_elapsed $BASELINE_START)
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
# Rebuild after submission patch
# ============================================================
REBUILD_STATUS="skipped"
if [ "$COMPILE_STATUS" = "pass" ] && [ "$PATCH_STATUS" = "pass" ]; then
  dotnet build "./src/Spectre.Console.sln" > /tmp/rebuild_stdout.log 2> /tmp/rebuild_stderr.log || {
    REBUILD_STATUS="fail"
    COMPILE_STATUS="fail"
  }
  if [ "$REBUILD_STATUS" != "fail" ]; then
    REBUILD_STATUS="pass"
  fi
fi

# ============================================================
# Run eval tests (only if compilation and patch OK)
# ============================================================
TEST_DURATION=0
if [ "$COMPILE_STATUS" = "pass" ] && [ "$PATCH_STATUS" = "pass" ]; then
  TEST_START=$SECONDS
  _run_tests eval
  TEST_DURATION=$(_elapsed $TEST_START)
fi

OVERALL_DURATION=$(_elapsed $OVERALL_START)

# --- Write temp files for safe passing to Python emitter ---
echo "$PATCH_OUTPUT" > /tmp/_patch_output.txt
cat /tmp/compile_stdout.log /tmp/compile_stderr.log > /tmp/_compile_output.txt 2>/dev/null || true

# --- Write expected test lists to file (avoids shell quoting issues) ---
cat > /tmp/_expected.json << 'EXPECTED_EOF'
{"fail_to_pass": {{ instance.expected.fail_to_pass | tojson }}, "pass_to_pass": {{ instance.expected.pass_to_pass | tojson }}}
EXPECTED_EOF

# ============================================================
# Emit EE-bench JSON v2.0 (6 criteria)
# ============================================================
export PATCH_STATUS PATCH_DURATION COMPILE_STATUS COMPILE_DURATION
export TEST_DURATION BASELINE_DURATION OVERALL_DURATION TIMESTAMP
export HAS_TEST_PATCH

python3 "$EVAL_DIR/scripts/emitter.py"
