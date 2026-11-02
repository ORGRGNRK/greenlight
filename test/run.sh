#!/usr/bin/env bash
# Tests for greenlight. Each case makes a throwaway git repo and uses a fake "AI" (--cmd) so no real AI is needed.
# Run: bash test/run.sh      (prints ok / FAIL per case; exit 1 if any fail)
set -u
GL="$(cd "$(dirname "$0")/.." && pwd)/greenlight"
T="$(mktemp -d "${TMPDIR:-/tmp}/gl-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export XDG_STATE_HOME="$T/state" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name tester; git config --global user.email tester@example.com
git config --global init.defaultBranch main
fails=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails+1)); }

# a repo whose "test" checks that value.txt holds a number below 100
mkrepo() {
  local r="$T/$1"; mkdir -p "$r"; cd "$r" || exit 1
  git init -q
  echo 1 > value.txt
  printf 'TEST=test "$(cat value.txt)" -lt 100\n' > .greenlight
  git add -A && git commit -qm init
  echo "$r"
}
head_of() { git -C "$1" rev-parse HEAD; }

# 1. a good change lands
r=$(mkrepo good); before=$(head_of "$r")
out=$("$GL" -C "$r" --cmd 'echo 5 > value.txt' "set it to 5" 2>&1); rc=$?
if [ $rc -eq 0 ] && [ "$(cat "$r/value.txt")" = 5 ] && [ "$(head_of "$r")" != "$before" ] && [ -z "$(git -C "$r" status --porcelain)" ]
then ok "good change lands"; else bad "good change lands" "rc=$rc $out"; fi

# 2. a change that fails the tests changes nothing
r=$(mkrepo badtest); before=$(head_of "$r")
out=$("$GL" -C "$r" --cmd 'echo 500 > value.txt' "set it to 500" 2>&1); rc=$?
if [ $rc -eq 1 ] && [ "$(cat "$r/value.txt")" = 1 ] && [ "$(head_of "$r")" = "$before" ] && echo "$out" | grep -q "FAILED at test"
then ok "failing tests change nothing"; else bad "failing tests change nothing" "rc=$rc $out"; fi

# 3. a failing build changes nothing
r=$(mkrepo badbuild); before=$(head_of "$r")
printf 'BUILD=false\nTEST=true\n' > "$r/.greenlight"; git -C "$r" commit -qam steps; before=$(head_of "$r")
out=$("$GL" -C "$r" --cmd 'echo 2 > value.txt' "x" 2>&1); rc=$?
if [ $rc -eq 1 ] && [ "$(head_of "$r")" = "$before" ] && echo "$out" | grep -q "FAILED at build"
then ok "failing build changes nothing"; else bad "failing build changes nothing" "rc=$rc $out"; fi

# 4. no test step = refused before anything runs
r=$(mkrepo notest); git -C "$r" rm -q .greenlight; git -C "$r" commit -qm "no steps"
out=$("$GL" -C "$r" --cmd 'touch "$PWD/../ran"' "x" 2>&1); rc=$?
if [ $rc -eq 2 ] && echo "$out" | grep -q "no test step" && [ ! -e "$T/ran" ]
then ok "no test step is refused"; else bad "no test step is refused" "rc=$rc $out"; fi

# 5. the AI making no change is a failure
r=$(mkrepo nochange); before=$(head_of "$r")
out=$("$GL" -C "$r" --cmd 'true' "do nothing" 2>&1); rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "made no changes" && [ "$(head_of "$r")" = "$before" ]
then ok "no change = failure"; else bad "no change = failure" "rc=$rc $out"; fi

# 6. the AI tool exiting non-zero is a failure, even if it edited files
r=$(mkrepo aifail); before=$(head_of "$r")
out=$("$GL" -C "$r" --cmd 'echo 3 > value.txt; exit 7' "x" 2>&1); rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "exited 7" && [ "$(cat "$r/value.txt")" = 1 ]
then ok "AI exit code is respected"; else bad "AI exit code is respected" "rc=$rc $out"; fi

# 7. your unsaved edits to the same file are never overwritten; the tested change is kept on a branch
r=$(mkrepo dirty); before=$(head_of "$r"); echo 9 > "$r/value.txt"
out=$("$GL" -C "$r" --cmd 'echo 4 > value.txt' "x" 2>&1); rc=$?
kept=$(git -C "$r" for-each-ref --format='%(refname:short)' refs/heads/greenlight-kept/)
if [ $rc -eq 4 ] && [ "$(cat "$r/value.txt")" = 9 ] && [ "$(head_of "$r")" = "$before" ] && [ -n "$kept" ] \
   && [ "$(git -C "$r" show "$kept:value.txt")" = 4 ]
then ok "unsaved edits kept, change parked on a branch"; else bad "unsaved edits kept" "rc=$rc kept=$kept $out"; fi

# 8. --keep-branch leaves your branch alone
r=$(mkrepo keep); before=$(head_of "$r")
out=$("$GL" -C "$r" --keep-branch --cmd 'echo 6 > value.txt' "x" 2>&1); rc=$?
if [ $rc -eq 4 ] && [ "$(head_of "$r")" = "$before" ] && git -C "$r" for-each-ref refs/heads/greenlight-kept/ | grep -q .
then ok "--keep-branch"; else bad "--keep-branch" "rc=$rc $out"; fi

# 9. no leftovers: no worktrees, no greenlight/ branches, no lock
r=$(mkrepo tidy)
"$GL" -C "$r" --cmd 'echo 7 > value.txt' "x" >/dev/null 2>&1
"$GL" -C "$r" --cmd 'echo 700 > value.txt' "x" >/dev/null 2>&1
wts=$(git -C "$r" worktree list | wc -l | tr -d ' ')
brs=$(git -C "$r" for-each-ref refs/heads/greenlight/ | wc -l | tr -d ' ')
if [ "$wts" = 1 ] && [ "$brs" = 0 ] && [ ! -e "$r/.git/greenlight.lock" ]
then ok "cleans up after itself"; else bad "cleans up after itself" "worktrees=$wts branches=$brs"; fi

# 10. a lock left by a dead run is cleared; a live one blocks
r=$(mkrepo lock); mkdir "$r/.git/greenlight.lock"; echo 999999 > "$r/.git/greenlight.lock/pid"
out=$("$GL" -C "$r" --cmd 'echo 8 > value.txt' "x" 2>&1); rc1=$?
mkdir "$r/.git/greenlight.lock"; echo $$ > "$r/.git/greenlight.lock/pid"
out2=$("$GL" -C "$r" --cmd 'echo 2 > value.txt' "x" 2>&1); rc2=$?; rm -rf "$r/.git/greenlight.lock"
if [ $rc1 -eq 0 ] && [ $rc2 -eq 3 ] && [ "$(cat "$r/value.txt")" = 8 ]
then ok "stale lock cleared, live lock blocks"; else bad "locks" "rc1=$rc1 rc2=$rc2 $out $out2"; fi

# 11. the AI gets the instruction (stdin and $GREENLIGHT_PROMPT), and - reads it from stdin
r=$(mkrepo prompt)
out=$(echo "make it 11" | "$GL" -C "$r" --cmd 'grep -q "make it 11" && case "$GREENLIGHT_PROMPT" in *"make it 11"*) echo 11 > value.txt;; esac' - 2>&1); rc=$?
if [ $rc -eq 0 ] && [ "$(cat "$r/value.txt")" = 11 ]
then ok "instruction reaches the AI"; else bad "instruction reaches the AI" "rc=$rc $out"; fi

# 12. .greenlight is read, never run
r=$(mkrepo safe); printf 'TEST=true\n$(touch %s/pwned)\ntouch %s/pwned2\n' "$T" "$T" > "$r/.greenlight"; git -C "$r" commit -qam steps
"$GL" -C "$r" --plan >/dev/null 2>&1
if [ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ]; then ok ".greenlight is never executed"; else bad ".greenlight is never executed" "a line ran"; fi

# 13. works when the project is a subfolder of the repo
r="$T/mono"; mkdir -p "$r/app"; cd "$r" && git init -q && echo 1 > app/value.txt \
  && printf 'TEST=test "$(cat value.txt)" -lt 100\n' > app/.greenlight && git add -A && git commit -qm init
out=$("$GL" -C "$r/app" --cmd 'echo 12 > value.txt' "x" 2>&1); rc=$?
if [ $rc -eq 0 ] && [ "$(cat "$r/app/value.txt")" = 12 ]; then ok "project in a subfolder"; else bad "project in a subfolder" "rc=$rc $out"; fi

# 14. detection and --plan
r="$T/node"; mkdir -p "$r"; cd "$r" && git init -q && printf '{"scripts":{"build":"tsc","test":"jest"}}\n' > package.json
out=$("$GL" -C "$r" --plan); if echo "$out" | grep -q "build:   npm run build" && echo "$out" | grep -q "test:    npm test"
then ok "--plan detects npm"; else bad "--plan detects npm" "$out"; fi

# 15. works with no git identity configured (falls back to greenlight@localhost)
r=$(mkrepo noid); : > "$GIT_CONFIG_GLOBAL"; git config --global init.defaultBranch main
out=$("$GL" -C "$r" --cmd 'echo 13 > value.txt' "x" 2>&1); rc=$?
git config --global user.name tester; git config --global user.email tester@example.com
if [ $rc -eq 0 ] && [ "$(git -C "$r" log -1 --format=%ae)" = greenlight@localhost ]
then ok "no git identity"; else bad "no git identity" "rc=$rc $out"; fi

# 16. PROTECT: the AI may not touch the tests it is judged by
r=$(mkrepo protect); mkdir -p "$r/tests"; echo 'test "$(cat value.txt)" -lt 100' > "$r/tests/check.sh"
printf 'TEST=bash tests/check.sh\nPROTECT=tests/\n' > "$r/.greenlight"; git -C "$r" add -A; git -C "$r" commit -qm protect; before=$(head_of "$r")
out=$("$GL" -C "$r" --cmd 'echo 500 > value.txt; echo true > tests/check.sh' "cheat" 2>&1); rc=$?
out2=$("$GL" -C "$r" --cmd 'echo 50 > value.txt' "fine" 2>&1); rc2=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "protected paths: tests/check.sh" && [ $rc2 -eq 0 ] && [ "$(cat "$r/value.txt")" = 50 ]
then ok "PROTECT blocks test tampering"; else bad "PROTECT" "rc=$rc rc2=$rc2 $out $out2"; fi

[ $fails -eq 0 ] && echo "all passed" || echo "$fails failed"
exit $((fails > 0))
