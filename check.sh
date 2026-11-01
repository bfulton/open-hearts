#!/usr/bin/env bash
# Every check the repository has, as much of it as a change needs
# (docs/explanation/testing.md).
#
#   ./check.sh quick [base]   what you touched since base — committed,
#                             staged or not; origin/main
#                             unless told — each at its fast tier
#   ./check.sh full           everything: every tier, the relay three
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

# Every Dart package's dependencies, fetched before any suite reads
# them, as CI does: `dart analyze` does not fetch them itself, and the
# service's three suites, side by side in one package, would each fetch
# them at once. lanes() runs it first wherever a Dart suite is to run.
suite_deps() {
  local d
  for d in packages/engine packages/deal packages/table_sim packages/table service; do
    echo "==> $d" && (cd "$d" && dart pub get) || return 1
  done
}
suite_engine() { cd packages/engine && dart analyze --fatal-infos && dart test -j "$cores"; }
suite_deal() { cd packages/deal && dart analyze --fatal-infos && dart test -j "$cores"; }
# The table's fast tier, after its simulator's own checks
# (packages/table_sim), and the slow one: whole sealed games under
# every departure, the chaos walks past the first eight
# (packages/table/dart_test.yaml).
suite_table() {
  (cd packages/table_sim && dart analyze --fatal-infos && dart test -j "$cores") &&
    cd packages/table && dart analyze --fatal-infos && dart test -j "$cores" -x slow
}
suite_table_slow() { cd packages/table && dart test -j "$cores" -t slow; }
# Tables, presence and the waiting room over real sockets, against the
# relay the Cloudflare object runs (service/lib/src/relay.dart).
suite_service() { cd service && dart analyze --fatal-infos && dart test -j "$cores"; }
suite_relay_js() { node --test service/do/*.test.mjs; }
suite_functions() { node --test service/functions/*.test.mjs; }
suite_site() { node --test site/*.test.mjs; }
suite_infra() { node --test infra/*.test.mjs; }
# The operator's command: its reference is its table, and each command
# does what it says (docs/reference/oh.md).
suite_ops() { node --test ops/*.test.mjs; }
# The page's own workers, in node, against the committed wasm.
suite_workers() { node --test e2e/deal_worker.test.mjs e2e/deal_golden.test.mjs e2e/offline_worker.test.mjs e2e/carry.test.mjs crypto/schnorr_wasm/vectors.test.mjs; }
suite_crypto() {
  (cd crypto/deal && cargo clippy --release --locked --all-targets -- -D warnings && cargo test --release --locked) &&
    (cd crypto/vendor && cargo test --release --locked) &&
    (cd crypto/schnorr && cargo clippy --release --locked --all-targets -- -D warnings && cargo test --release --locked) &&
    (cd crypto/schnorr_wasm && cargo clippy --release --locked --target wasm32-unknown-unknown -- -D warnings)
}
# The scripts that are not anybody's suite: that each still parses.
suite_scripts() {
  local f ok=0
  for f in check.sh deploy.sh build_phone.sh oh ops/wrangler/wrangler e2e/*.sh crypto/*.sh app/ios/*.sh service/bench/build.sh; do bash -n "$f" || ok=1; done
  for f in e2e/*.mjs app/tool/*.mjs; do node --check "$f" || ok=1; done
  # Nothing licensed to Open Hearts as confidential is committed
  # (ops/no_private.mjs).
  node ops/no_private.mjs || ok=1
  CHECK_PLAN=1 ./check.sh full > /dev/null || ok=1
  if python3 -c 'import yaml' 2> /dev/null; then
    python3 -c 'import sys, yaml; [yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/workflows/*.yml || ok=1
  fi
  return $ok
}
# The docs: every link, anchor and repository path they name resolves.
suite_docs() { node --test docs/links.test.mjs && node docs/links.mjs; }
suite_app_analyze() { cd app && flutter analyze; }
# The app's tests: all of them, or those $app_tests names, with
# $app_flags (quick leaves the layout matrix out: app/dart_test.yaml).
# And those that need a page under them (test/web), in Chrome: the one
# CHROME_EXECUTABLE names, else a Chrome or Chromium on the PATH or in
# macOS's Applications, else the Chromium Playwright brought.
suite_app() {
  local chrome=${CHROME_EXECUTABLE:-} c
  if [ -z "$chrome" ]; then
    for c in google-chrome google-chrome-stable chromium chromium-browser; do
      command -v "$c" > /dev/null && chrome=$(command -v "$c") && break
    done
  fi
  if [ -z "$chrome" ]; then
    for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
      [ -x "$c" ] && chrome=$c && break
    done
  fi
  if [ -z "$chrome" ]; then
    chrome=$(ls -d "${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"/chromium-*/chrome-linux*/chrome \
      "${PLAYWRIGHT_BROWSERS_PATH:-$HOME/Library/Caches/ms-playwright}"/chromium-*/chrome-mac*/Chromium.app/Contents/MacOS/Chromium \
      2> /dev/null | head -1)
  fi
  if [ -z "$chrome" ]; then
    echo "app: no Chrome for test/web; set CHROME_EXECUTABLE to one" >&2
    return 1
  fi
  export CHROME_EXECUTABLE=$chrome
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
suite_e2e_house() { node e2e/house.mjs; }
suite_e2e_offline() { node e2e/offline.mjs; }
suite_e2e_site() { node e2e/site.mjs; }
suite_e2e_move() { node e2e/move.mjs; }
# The app under its Content-Security-Policy. It makes a build of its own,
# the suites' with Apple's Services ID (e2e/build.sh --out), and not
# again while that is unchanged.
suite_e2e_csp() { node e2e/csp.mjs; }

all_suites="engine deal table table_slow service relay_js functions site infra ops workers crypto scripts docs app_analyze app
  e2e_build e2e_flows e2e_run e2e_house e2e_offline e2e_site e2e_move e2e_csp"

# ---- running them ----------------------------------------------------------

results=$(mktemp)
trap 'rm -f "$results"' EXIT

# The suites that only count — the Dart and Flutter tests on the
# simulator's clock and the test clock — run at a lower priority than
# those that keep time: the browser suites and the service's sockets,
# whose tables have deadlines a starved process can miss. They take what
# the clocks leave, and every core stays busy.
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
  local pids=() l s
  for s in ${*//,/ }; do
    case $s in engine | deal | table | table_slow | service) run deps; break ;; esac
  done
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
  local base=${1:-origin/main} files suites=() app_files=()
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
        case $f in
          app/web/*) add workers site e2e_csp ;;
          app/worker/*) add workers ;;
          app/lib/net/buying.dart) add site ;;
          app/lib/net/provider_tokens_web.dart) add site e2e_csp ;;
        esac ;;
      packages/engine/*) add engine ;;
      packages/deal/*) add deal ;;
      packages/table/*|packages/table_sim/*) add table ;;
      service/do/*) add relay_js service ;;
      # The name filter: the relay reads it too, and the app is held to
      # its cases.
      service/functions/names.vectors.json) add functions ops relay_js app_analyze app; app_files+=(app/lib/names.dart) ;;
      service/functions/names.mjs|service/functions/name_fold.mjs|service/functions/blocked_names.mjs) add functions ops relay_js ;;
      third_party/ldnoobw/*) add functions ops ;;
      # The pictures withheld: the relay reads the list too.
      service/functions/pictures.mjs) add functions ops relay_js ;;
      service/functions/*) add functions ops ;;
      service/tool/*.mjs) add functions ops ;;
      service/*) add service ;;
      # The app's Content-Security-Policy: held to the code, and the app
      # loaded under it.
      site/public/_headers|site/headers.mjs|site/headers.test.mjs) add site e2e_site e2e_csp ops ;;
      site/*) add site e2e_site ops ;;
      config/*) add site functions infra ops ;;
      infra/*) add infra ops ;;
      # The New Relic definition: infra's suite loads its script.
      observability/*) add infra ops ;;
      ops/*|oh) add ops ;;
      e2e/*.test.mjs) add workers ;;
      e2e/csp.mjs) add scripts e2e_csp ;;
      e2e/*|*.sh|.github/*) add scripts ;;
      crypto/*) add crypto deal workers ;;
    esac
  done <<< "$files"
  # Whatever changed, the docs: a file renamed or removed leaves a doc
  # pointing at nothing, and this takes a second.
  add docs
  # The app's tests a change can reach, by their imports
  # (app/tool/affected_tests.mjs); all of them when the change is to
  # something every test stands on.
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
# time run in waves no bigger than a laptop can carry: the browser
# suites' build; the move's timings, which hold the app's start to a
# second and a half; the service's sockets all three ways and the house;
# the four-browser run and the network taken away; the flows. All of
# them at once is no sooner on a few cores, only less sure: their tables
# keep deadlines that a starved process misses. The Rust crates' own
# tests where cargo has built them here; a machine that was handed the
# libraries has nothing to test them with.
full() {
  local crypto="" s
  [ -d crypto/deal/target/release/.fingerprint ] && command -v cargo > /dev/null && crypto=crypto
  local plan=("table table_slow" "app_analyze app" "engine,deal" "relay_js,functions,site,infra,ops,workers,scripts,docs $crypto"
    "e2e_build e2e_move,e2e_site service,e2e_house e2e_run,e2e_offline e2e_flows e2e_csp")
  # Every suite there is, in a lane: one left out would never run here.
  for s in $all_suites; do
    [ "$s" = crypto ] && [ -z "$crypto" ] && continue
    [[ " ${plan[*]//,/ } " == *" $s "* ]] || { echo "check: full runs no $s: put it in a lane" >&2; exit 2; }
  done
  echo "logs in $logs/"
  [ -n "$crypto" ] || echo "crypto: not run, as crypto/deal has not been built here (./check.sh crypto builds and runs it)"
  lanes "${plan[@]}"
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
