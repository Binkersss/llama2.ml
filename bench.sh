#!/bin/sh
# Benchmark llama2.ml. Run from the project root (next to tokenizer.bin).
#
#   ./bench.sh [label]
#
# Environment overrides:
#   MODEL=stories15M.bin  STEPS=64  RUNS=5  WARMUP=1  TARGET=llama2.exe
#
# Results go to bench/<timestamp>_<commit>[-dirty][_label]/ :
#   meta.txt          commit, dirty flag, machine, OCaml version, settings
#   diff.patch        uncommitted changes (only if the tree was dirty)
#   llama2.exe        copy of the exact binary that was measured
#   hyperfine.json    hyperfine results (machine-readable)
#   hyperfine.md      hyperfine results (markdown table)
#   output.txt        generated text + "achieved tok/s" line
#   gc.txt            OCaml GC statistics (OCAMLRUNPARAM=v=0x400)
#   time.txt          /usr/bin/time -l output (peak RSS, page faults, ...)
#   summary.txt       the key numbers in one place
#
# The first run saves bench/reference.txt (generated text with the tok/s
# line removed). Later runs are diffed against it to catch behavior changes.

set -u
# this is a benching script for openbsd that requires hyperfine
doas sysctl hw.perfpolicy=high

 
MODEL=${MODEL:-stories15M.bin}
STEPS=${STEPS:-64}
RUNS=${RUNS:-5}
WARMUP=${WARMUP:-1}
TARGET=${TARGET:-llama2.exe}
TEMP=0.0   # greedy decoding: deterministic output, skips the slow sampling path
LABEL=${1:-}
 
die() { echo "bench: $*" >&2; exit 1; }
 
command -v hyperfine >/dev/null 2>&1 || die "hyperfine not found (doas pkg_add hyperfine)"
command -v dune      >/dev/null 2>&1 || die "dune not found (run: eval \$(opam env))"
[ -f "$MODEL" ]         || die "model file '$MODEL' not found"
[ -f tokenizer.bin ]    || die "tokenizer.bin not found in $(pwd)"
 
# ---- which version is this? ----
if git rev-parse --git-dir >/dev/null 2>&1; then
  COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "nocommit")
  FULL_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "nocommit")
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    DIRTY=yes
  else
    DIRTY=no
  fi
else
  COMMIT=nogit
  FULL_COMMIT=nogit
  DIRTY=unknown
fi
 
TAG=$COMMIT
[ "$DIRTY" = yes ] && TAG=${TAG}-dirty
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=bench/${STAMP}_${TAG}
[ -n "$LABEL" ] && OUT=${OUT}_${LABEL}
mkdir -p "$OUT" || die "cannot create $OUT"
 
# ---- build ----
echo "== building ($TAG) =="
dune build --release "./$TARGET" || die "build failed"
BIN_SRC=_build/default/$TARGET
[ -x "$BIN_SRC" ] || die "binary $BIN_SRC not found"
cp "$BIN_SRC" "$OUT/$TARGET"
BIN=$OUT/$TARGET
 
# ---- metadata ----
{
  echo "date:        $(date)"
  echo "commit:      $FULL_COMMIT"
  echo "dirty:       $DIRTY"
  [ -n "$LABEL" ] && echo "label:       $LABEL"
  echo "model:       $MODEL ($(ls -l "$MODEL" | awk '{print $5}') bytes)"
  echo "steps:       $STEPS"
  echo "temperature: $TEMP"
  echo "hyperfine:   runs=$RUNS warmup=$WARMUP"
  echo "ocaml:       $(ocamlfind ocamlopt -version 2>/dev/null || ocamlopt -version)"
  echo "uname:       $(uname -a)"
  echo "cpu:         $(sysctl -n hw.model 2>/dev/null)"
  echo "ncpu:        $(sysctl -n hw.ncpu 2>/dev/null)"
  echo "perfpolicy:  $(sysctl -n hw.perfpolicy 2>/dev/null)"
  echo "cpuspeed:    $(sysctl -n hw.cpuspeed 2>/dev/null) MHz"
} > "$OUT/meta.txt"
 
if [ "$DIRTY" = yes ]; then
  git diff HEAD > "$OUT/diff.patch"
fi
 
# ---- hyperfine: wall-clock statistics over several runs ----
# (hyperfine discards program output; output is captured in the next step)
echo "== hyperfine: $RUNS runs, $WARMUP warmup =="
hyperfine \
  --warmup "$WARMUP" \
  --runs "$RUNS" \
  --command-name "$TAG" \
  --export-json "$OUT/hyperfine.json" \
  --export-markdown "$OUT/hyperfine.md" \
  "$BIN $MODEL $TEMP $STEPS" \
  || die "hyperfine failed"
 
# ---- one instrumented run: output text + OCaml GC stats ----
# v=0x400 prints GC statistics to stderr at exit.
echo "== instrumented run (output + GC stats) =="
OCAMLRUNPARAM=v=0x400 "$BIN" "$MODEL" "$TEMP" "$STEPS" \
  > "$OUT/output.txt" 2> "$OUT/gc.txt" || die "instrumented run failed"
 
# ---- one run under time -l: peak memory, page faults ----
echo "== time -l run =="
/usr/bin/time -l "$BIN" "$MODEL" "$TEMP" "$STEPS" \
  > /dev/null 2> "$OUT/time.txt" || die "time run failed"
 
# ---- check output against the reference ----
grep -v 'achieved tok/s' "$OUT/output.txt" > "$OUT/output.notoks.txt"
if [ -f bench/reference.txt ]; then
  if cmp -s bench/reference.txt "$OUT/output.notoks.txt"; then
    REF="output matches bench/reference.txt"
  else
    REF="OUTPUT DIFFERS from bench/reference.txt (see $OUT/output.notoks.txt)"
  fi
else
  cp "$OUT/output.notoks.txt" bench/reference.txt
  REF="saved as new bench/reference.txt (first run)"
fi
 
# ---- summary ----
TOKS=$(grep -h 'achieved tok/s' "$OUT/output.txt" | tail -1)
ROW=$(sed -n '3p' "$OUT/hyperfine.md")
MEAN=$(echo "$ROW" | awk -F'|' '{print $3}' | awk '{print $1}')
MIN=$(echo "$ROW" | awk -F'|' '{print $4}' | awk '{print $1}')
RSS=$(grep 'maximum resident' "$OUT/time.txt")
GC_SELECT='minor_collections|major_collections|heap_words|top_heap_words|minor_words|promoted_words|major_words|compactions'
 
{
  echo "version:         $TAG ($FULL_COMMIT)"
  echo "hyperfine mean:  ${MEAN:-?} s    min: ${MIN:-?} s"
  echo "$TOKS"
  echo "peak memory:     ${RSS:-?}"
  echo "correctness:     $REF"
  echo "--- GC ---"
  grep -E "$GC_SELECT" "$OUT/gc.txt"
} | tee "$OUT/summary.txt"
 
echo
echo "results in $OUT/"

doas sysctl hw.perfpolicy=auto
