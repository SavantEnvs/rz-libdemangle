#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# The library is plain C with no external dependencies, so it is compiled directly with clang
# (upstream's meson is not in the base image and would need a network fetch).
# Build trees live in build-*/ (gitignored upstream via `build*/`) and are recreated on every run.
SRCS=$(find src -name '*.c' | sort)
INC="-I$SRC/include -I$SRC/src"
DEFS="-DWITH_SWIFT_DEMANGLER=1"
export INC DEFS

# compile_all <outdir> <flags...> — one object per library source, in parallel.
compile_all() {
  local out="$1"; shift
  rm -rf "$out"; mkdir -p "$out"
  for f in $SRCS; do echo "$f"; done | xargs -P "$MAYHEM_JOBS" -I{} bash -c '
    f="$1"; shift
    o="$0/$(echo "$f" | tr / _).o"
    '"$CC"' "$@" $INC $DEFS -c "$f" -o "$o"' "$out" {} "$@"
}

# 1) Sanitized + coverage-instrumented library (fuzzer builds) and a sanitized-only copy (standalone).
compile_all build-fuzz -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link
compile_all build-standalone -O1 $SANITIZER_FLAGS $DEBUG_FLAGS

# 2) Harnesses: the in-tree upstream one (fuzz/fuzz_demangle.c) and mayhem/fuzz_handlers.c, each
#    as a libFuzzer binary and a run-once standalone reproducer. LSan is switched off at build time.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build-fuzz/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-standalone/standalone_main.o
cp build-fuzz/lsan_off.o build-standalone/lsan_off.o

for h in fuzz/fuzz_demangle.c mayhem/fuzz_handlers.c; do
  name=$(basename "$h" .c)
  $CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $INC $DEFS $LIB_FUZZING_ENGINE "$h" \
      build-fuzz/*.o -o "/mayhem/$name"
  $CC -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $INC $DEFS "$h" \
      build-standalone/*.o -o "/mayhem/$name-standalone"
done

# 3) Test suite with the project's NORMAL flags (no sanitizers): every test/test_*.c and
#    test/unit/test_*.c as its own runner, plus the CLI used by test.sh's known-answer probes.
rm -rf build-tests; mkdir -p build-tests
compile_all build-tests-obj -O2
for t in test/test_*.c test/unit/test_*.c; do
  name=$(basename "$t" .c)
  $CC -O2 $COVERAGE_FLAGS $INC -Itest $DEFS -DSOURCE_ROOT="\"$SRC\"" "$t" build-tests-obj/*.o -o "build-tests/$name"
done
$CC -O2 $COVERAGE_FLAGS $INC $DEFS bin/demangle.c build-tests-obj/*.o -o build-tests/rz-demangle
