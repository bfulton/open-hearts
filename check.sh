#!/usr/bin/env bash
# Every check the repository has, as much of it as a change needs
# (docs/09-testing.md).
#
#   ./check.sh quick [base]   what you touched since base — committed,
#                             staged or not; origin/claude/launch-punch-list
#                             unless told — each at its fast tier
#   ./check.sh full           everything: every tier, the relay both
#                             ways, the browser suites; side by side
#   ./check.sh <suite>...     the suites named, side by side
#   ./check.sh list           the suites there are
#
# CHECK_PLAN=1 says what would run, and runs nothing.
#
# Quick checks what a change touches; full checks what that touches in
# turn — a change to packages/table runs the table's fast tier here, and
# the service and the app over it in full (and in CI).
#
# Each suite's output is in build/check/<suite>.log, and the table at
# the end says which passed and how long each took. The exit code is
# the verdict. Run from anywhere; it runs from the repository's root.
set -uo pipefail
cd "$(dirname "$0")"
root=$(pwd)
logs=$root/build/check
cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# ---- the suites ------------------------------------------------------------
#
# One function each, run from the root with its output to its log.

suite_engine() { cd packages/engine && dart analyze && dart test -j "$cores"; }
suite_deal() { cd packages/deal && dart analyze && dart test -j "$cores"; }
# The table's fast tier, and the slow one: whole sealed games under
# every departure, the chaos walks past the first eight
# (packages/table/dart_test.yaml).
suite_table() { cd packages/table && dart analyze && dart test -j "$cores" -x slow; }
suite_table_slow() { cd packages/table && dart test -j "$cores" -t slow; }
suite_service() { cd service && dart analyze && dart test -j "$cores"; }
# The same suite against the relay the Cloudflare object runs.
suite_service_js() { cd service && OH_RELAY=js dart test -j "$cores"; }
suite_relay_js() { node --test service/do/*.test.mjs; }
suite_functions() { node --test service/functions/*.test.mjs; }
suite_site() { node --test site/build.test.mjs; }
suite_infra() { node --test infra/*.test.mjs; }
# The page's own workers, in node, against the committed wasm.
suite_workers() { node --test e2e/deal_worker.test.mjs e2e/deal_golden.test.mjs e2e/offline_worker.test.mjs e2e/carry.test.mjs; }
suite_crypto() { (cd crypto/deal && cargo test --release) && (cd crypto/vendor && cargo test --release) && (cd crypto/schnorr && cargo test --release); }
# The scripts that are not anybody's suite: that each still parses.
suite_scripts() {
  local f ok=0
  for f in check.sh deploy.sh build_phone.sh e2e/*.sh crypto/*.sh app/ios/*.sh; do bash -n "$f" || ok=1; done
  for f in e2e/*.mjs app/tool/*.mjs; do node --check "$f" || ok=1; done
  if python3 -c 'import yaml' 2> /dev/null; then
    python3 -c 'import sys, yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/workflows/*.yml || ok=1
  fi
  return $ok
}
suite_app_analyze() { cd app && flutter analyze; }
# The app's tests: all of them, or those $app_tests names, with
# $app_flags (quick leaves the layout matrix out: app/dart_test.yaml).
# And those that need a page under them (test/web), in Chrome, or the
# Chromium Playwright brought where there is no Chrome.
suite_app() {
  local chrome=${CHROME_EXECUTABLE:-$(ls -d /opt/pw-browsers/chromium-*/chrome-linux*/chrome 2> /dev/null | head -1)}
  [ -n "$chrome" ] && export CHROME_EXECUTABLE=$chrome
  cd app || return 1
  if [ "${app_tests:-}" != none ]; then flutter test -j "$cores" ${app_flags:-} ${app_tests:-} || return 1; fi
  flutter test --platform chrome test/web
}
# The browser suites (e2e/README.md), on the one build e2e/build.sh
# makes for all of them, and not again while its sources are unchanged.
# Each starts its own relay on a port of its own, so they run together.
suite_e2e_build() { ./e2e/build.sh; }
suite_e2e_flows() { node e2e/flows.mjs; }
suite_e2e_run() { node e2e/run.mjs; }
suite_e2e_escrow() { node e2e/escrow.mjs; }
suite_e2e_offline() { node e2e/offline.mjs; }
suite_e2e_site() { node e2e/site.mjs; }
suite_e2e_move() { node e2e/move.mjs; }

all_suites="engine deal table table_slow service service_js relay_js functions site infra workers crypto scripts app_analyze app
  e2e_build e2e_flows e2e_run e2e_escrow e2e_offline e2e_site e2e_move"

# ---- running them ----------------------------------------------------------

results=$(mktemp)
trap 'rm -f "$results"' EXIT

# The suites that only count — the Dart and Flutter tests on the
# simulator's clock and the test clock — run at a lower priority than
# those that keep time: the browser suites and the service's sockets,
# whose tables have deadlines a starved process can miss. They take what
# the clocks leave, and all four cores stay busy.
patient="engine deal table table_slow app app_analyze crypto"

run() {
  local name=$1 began=$SECONDS rc nice=""
  [[ " $patient " == *" $name "* ]] && nice="nice -n 19"
  ( $nice bash -c "$(declare -f "suite_$name"); cores=$cores; app_tests='$app_tests'; app_flags='$app_flags'; suite_$name" ) > "$logs/$name.log" 2>&1
  rc=$?
  echo "$name $rc $((SECONDS - began))" >> "$results"
  return $rc
}

# A lane is steps one after another, and a step is one suite or several
# at once: "e2e_build e2e_run,e2e_flows" is the build, then both suites
# side by side. A failed build ends its lane — a browser suite with no
# build has nothing to say — and anything else fails on its own.
lane() {
  local step s
  while [ $# -gt 0 ]; do
    step=$1
    shift
    local pids=() ok=0
    for s in ${step//,/ }; do
      run "$s" &
      pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || ok=1; done
    if [ $ok != 0 ] && [[ $step == *build* ]]; then
      for step in "$@"; do for s in ${step//,/ }; do echo "$s skip 0" >> "$results"; done; done
      return 1
    fi
  done
}

summary() {
  local total=$1 failed=0 r
  printf '\n%-14s %-6s %6s\n' suite result time
  while read -r name rc secs; do
    case $rc in
      0) r=pass ;;
      skip) r=skip; failed=1 ;;
      *) r=FAIL; failed=1 ;;
    esac
    printf '%-14s %-6s %5ss\n' "$name" "$r" "$secs"
  done < "$results"
  printf '%-14s %-6s %5ss\n' total "$([ $failed = 0 ] && echo pass || echo FAIL)" "$total"
  [ $failed = 0 ] || echo "logs: $logs/"
  return $failed
}

began=$SECONDS

# Runs lanes — each a quoted list of steps — side by side, and waits for
# them. With CHECK_PLAN=1, says what it would run and runs nothing.
lanes() {
  if [ -n "${CHECK_PLAN:-}" ]; then
    printf 'lane: %s\n' "$@"
    [ -z "$app_tests" ] || echo "app tests: $app_tests"
    return 0
  fi
  mkdir -p "$logs"
  local pids=() l
  for l in "$@"; do
    # shellcheck disable=SC2086
    lane $l &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
}

# The table of what ran, once everything has.
verdict() {
  [ -n "${CHECK_PLAN:-}" ] && return 0
  summary $((SECONDS - began))
}

# ---- what a change touches -------------------------------------------------

# The paths that differ from [base]: its merge base with HEAD, the
# commits since, and the working tree, untracked files too.
changed_since() {
  local base=$1 from
  from=$(git merge-base HEAD "$base" 2>/dev/null) || { echo "no merge base with $base" >&2; exit 2; }
  { git diff --name-only "$from"; git ls-files --others --exclude-standard; } | sort -u
}

quick() {
  local base=${1:-origin/claude/launch-punch-list} files suites=() app_files=()
  files=$(changed_since "$base")
  if [ -z "$files" ]; then
    echo "nothing changed since $base"
    return 0
  fi
  add() { local s; for s in "$@"; do [[ " ${suites[*]-} " == *" $s "* ]] || suites+=("$s"); done; }
  local f
  while read -r f; do
    case $f in
      app/lib/*|app/test/*|app/web/*|app/worker/*|app/pubspec.yaml|app/analysis_options.yaml|app/l10n.yaml)
        add app_analyze app; app_files+=("$f")
        case $f in app/web/*|app/worker/*) add workers ;; esac ;;
      packages/engine/*) add engine ;;
      packages/deal/*) add deal ;;
      packages/table/*) add table ;;
      service/do/*) add relay_js service_js ;;
      service/functions/*) add functions ;;
      service/*) add service ;;
      site/*) add site e2e_site ;;
      infra/*) add infra ;;
      e2e/*.test.mjs) add workers ;;
      e2e/*|*.sh|.github/*) add scripts ;;
      crypto/*) add crypto deal workers ;;
    esac
  done <<< "$files"
  # The app's tests a change can reach, by their imports
  # (app/tool/affected_tests.mjs); all of them when it cannot tell.
  if [ ${#app_files[@]} -gt 0 ]; then
    local hit
    hit=$(node app/tool/affected_tests.mjs "${app_files[@]}")
    # Those on a page (test/web) run in Chrome after the rest, every
    # time the app suite runs: not on the VM, which skips them.
    local web=no
    if [ "$hit" != all ] && grep -q '^test/web/' <<< "$hit"; then
      web=yes
      hit=$(grep -v '^test/web/' <<< "$hit" || true)
    fi
    if [ "$hit" = all ]; then
      app_tests=''
    elif [ -z "$hit" ] && [ $web = yes ]; then
      app_tests=none
    elif [ -z "$hit" ]; then
      local kept=() s
      for s in "${suites[@]}"; do [ "$s" = app ] || kept+=("$s"); done
      suites=("${kept[@]}")
    else
      app_tests=$(echo "$hit" | tr '\n' ' ')
      echo "app: $(echo "$hit" | wc -l | tr -d ' ') of $(ls app/test/*_test.dart | wc -l | tr -d ' ') test files reach the change"
    fi
  fi
  local picked=()
  for s in "${suites[@]-}"; do [ -n "$s" ] && picked+=("$s"); done
  if [ ${#picked[@]} -eq 0 ]; then
    echo "nothing to check for: $(echo "$files" | tr '\n' ' ')"
    return 0
  fi
  echo "changed since $base: $(echo "$files" | wc -l | tr -d ' ') files; checking ${picked[*]}"
  echo "logs in $logs/"
  lanes "${picked[@]}"
  verdict
}

# Everything, in two kinds of lane side by side. The suites that count
# run at the lowest priority (above), all at once. The ones that keep
# time run in waves no bigger than four cores can carry: the browser
# suites' build; the move's timings, which hold the app's start to a
# second and a half; the service's sockets both ways and the escrow;
# the four-browser run and the network taken away; the flows. All of
# them at once is no sooner on four cores, only less sure: their tables
# keep deadlines that a starved process misses. The Rust crates' own
# tests where cargo has built them here; a machine that was handed the
# libraries has nothing to test them with.
full() {
  local crypto=""
  [ -d crypto/deal/target/release/.fingerprint ] && command -v cargo > /dev/null && crypto=crypto
  echo "logs in $logs/"
  lanes "table table_slow" "app_analyze app" "engine,deal" "relay_js,functions,site,infra,workers,scripts $crypto" \
    "e2e_build e2e_move,e2e_site service,service_js,e2e_escrow e2e_run,e2e_offline e2e_flows"
  verdict
}

app_tests=''
app_flags=''
case ${1:-} in
  quick) shift; app_flags='-x slow'; quick "$@" ;;
  full) full ;;
  list) echo $all_suites ;;
  ''|-h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  *)
    for s in "$@"; do
      declare -F "suite_$s" > /dev/null || { echo "no suite $s (./check.sh list)" >&2; exit 2; }
    done
    echo "logs in $logs/"
    lanes "$@"
    verdict
    ;;
esac
