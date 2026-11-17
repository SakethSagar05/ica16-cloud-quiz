#!/bin/bash
# ICA 16 helper for this Mac. Started by "Start ICA16.command".
#
# 1. Asks three yes/no questions once (Firebase project, test users, GitHub).
# 2. Runs the setup pipeline: Android platform folder, FlutterFire configure,
#    Firestore database + rules, two test users, flutter analyze, flutter test.
# 3. Boots an Android emulator if no device is connected.
# 4. Stays open as a relay: it watches tools/.relay/requests/ for one-line
#    request files and runs ONLY the fixed verbs listed in run_line in
#    tools/verbs.sh (adb taps, screenshots, builds, tests, rules deploy, git).
#    Anything else is ignored. Close the window or press Ctrl+C to stop.
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
source tools/env.sh
set -uo pipefail

PKG="com.saketh.ica16_cloud_quiz"
STUDENT="SakethSagarKokkireni"
RELEASE_APK="$ROOT/submission/ICA16_A_${STUDENT}.apk"
RELAY="$ROOT/tools/.relay"
REQ="$RELAY/requests"
DONE="$RELAY/done"
OUT="$RELAY/out"
EVID="$ROOT/docs/evidence"
SHOTS="$EVID/screens"
LOGS="$EVID/logs"
RUNS="$EVID/runs"
EVIDENCE_APK="$RELAY/ica16_evidence.apk"
CONSENT="$RELAY/consent.env"
USERS="$RELAY/test_users.env"
UI="$RELAY/ui.xml"
LOG="$RELAY/log.txt"
API_URL="https://opentdb.com/api.php?amount=10&category=9&difficulty=easy&type=multiple"
TRAILER=$'\n\nCo-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_016XgwNa5VZAaSY3tdXzD9Ba'
SERIAL=""
W=1080
H=2400
mkdir -p "$REQ" "$DONE" "$OUT" "$SHOTS" "$LOGS" "$RUNS" "$ROOT/submission"

log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
status() { echo "$* $(date +%s)" > "$RELAY/status"; }
yn() { case "${1:-}" in [Yy]*) echo y ;; *) echo n ;; esac; }

# ---------------------------------------------------------------- consent ---
ask_consent() {
  if [ ! -f "$CONSENT" ]; then
    echo
    echo "Three questions before anything touches your accounts."
    echo
    read -r -p "1) Firebase project ID to use [ica13-auth]: " P
    P="${P:-ica13-auth}"
    if ! [[ "$P" =~ ^[a-z0-9-]+$ ]]; then
      echo "That is not a valid project ID."
      exit 1
    fi
    echo "   In project '$P' this script will: register an Android app for this"
    echo "   quiz, create the (default) Firestore database if there is none"
    echo "   (Standard edition, Native mode, location nam5, locked by rules), and"
    echo "   deploy firestore.rules (this replaces that project's Firestore rules)."
    read -r -p "   Allow that? [y/N] " A1
    echo
    read -r -p "2) Create two throwaway Email/Password test users in '$P'? Their passwords stay in tools/.relay on this Mac and are never committed. [y/N] " A2
    echo
    read -r -p "3) When the work is finished, create a PUBLIC GitHub repo 'ica16-cloud-quiz' and push to it? [y/N] " A3
    {
      echo "FIREBASE_PROJECT=$P"
      echo "ALLOW_FIREBASE=$(yn "$A1")"
      echo "ALLOW_USERS=$(yn "$A2")"
      echo "ALLOW_GITHUB=$(yn "$A3")"
    } > "$CONSENT"
  fi
  # shellcheck disable=SC1090
  source "$CONSENT"
  log "consent: project=$FIREBASE_PROJECT firebase=$ALLOW_FIREBASE users=$ALLOW_USERS github=$ALLOW_GITHUB"
}

# ------------------------------------------------------------------ relay ---
handle() {
  local f="$1" name line rc
  name="$(basename "$f" .req)"
  line="$(head -1 "$f" | tr -d '\r')"
  rm -f "$f"
  # shellcheck disable=SC1091
  source "$ROOT/tools/verbs.sh"
  log "request $name: ${line%% *}"
  status "busy $name"
  {
    run_line "$line"
    rc=$?
  } > "$OUT/$name.txt" 2>&1
  echo "$rc" > "$DONE/$name.done"
  log "request $name finished rc=$rc"
  status "ready"
}

pipeline() {
  local s
  for s in platform configure firestore users analyze unittest; do
    status "pipeline $s"
    step "$s"
    if run_line "$s" 2>&1 | tee "$OUT/pipeline_$s.txt"; then
      log "pipeline $s: ok"
    else
      log "pipeline $s: FAILED (continuing)"
    fi
  done
}

# shellcheck disable=SC1091
source "$ROOT/tools/verbs.sh"
ask_consent
if [ "${1:-}" != "relay-only" ]; then
  pipeline
fi
step "Android device"
status "pipeline device"
if ensure_device 2>&1 | tee "$OUT/pipeline_device.txt"; then
  # ensure_device ran in a pipe; run it once more here so SERIAL is set.
  ensure_device > /dev/null 2>&1
fi
echo "pipeline finished $(date +%s)" > "$RELAY/pipeline_done"
step "Relay ready. Leave this window open. Claude continues from here."
status "ready"
while true; do
  for f in "$REQ"/*.req; do
    [ -e "$f" ] || continue
    handle "$f"
  done
  sleep 0.5
done
