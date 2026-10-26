#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

T="$SRC/build-tests"
passed=0; failed=0

# 1) Known-answer probes through the dynamically linked CLI, compared in bash: a neutered binary
#    (or a patch that makes the library return nothing / exit early) cannot satisfy these.
[ -x "$T/rz-demangle" ] || { echo "missing $T/rz-demangle — build.sh did not produce it" >&2; emit_ctrf "rz-libdemangle" 0 1 0; exit 1; }
kat() {  # kat <expected> <cli args...>
  local want="$1" got; shift
  got=$("$T/rz-demangle" "$@" 2>&1) || got="<exit $?>"
  if [ "$got" = "$want" ]; then passed=$((passed+1)); else failed=$((failed+1)); echo "KAT FAIL: $* => '$got' (want '$want')" >&2; fi
}
kat 'java.lang.String makeConcatWithConstants(java.lang.String)' java 'makeConcatWithConstants(Ljava/lang/String;)Ljava/lang/String;'
kat 'foo::bar(int)' c++ '_ZN3foo3barEi'
kat 'VTT for std::__cxx11::basic_stringstream<char, std::char_traits<char>, std::allocator<char>>' c++ '_ZTTNSt7__cxx1118basic_stringstreamIcSt11char_traitsIcESaIcEEE_ptr'
kat 'mycrate[3c1c0]::foo::bar' rust '_RNvNtCs1234_7mycrate3foo3bar'
kat 'int __cdecl foo(int)' msvc '?foo@@YAHH@Z'
kat 'class ABC::DEF::GHI<1, class JKL::MNO::PQR>' msvc '.?AV?$GHI@$H0VPQR@MNO@JKL@@@DEF@ABC@@'
kat 'void foo.bar(int)' d '_D3foo3barFiZv'
kat 'main.foo' swift '$s4main3fooyyF'
kat 'class NSObject' objc '_OBJC_CLASS_$_NSObject'

# 2) The project's own assertion suite (test/test_*.c, test/unit/test_*.c), one runner per file.
for r in "$T"/test_*; do
  [ -x "$r" ] || continue
  if "$r" >"$T/$(basename "$r").log" 2>&1; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL: $r" >&2; tail -20 "$T/$(basename "$r").log" >&2; fi
done
[ "$(ls "$T"/test_* 2>/dev/null | grep -vc '\.log$')" -ge 20 ] || { echo "too few test runners built" >&2; failed=$((failed+1)); }

emit_ctrf "rz-libdemangle-minunit" "$passed" "$failed" 0
