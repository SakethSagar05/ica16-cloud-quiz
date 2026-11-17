# Sourced by tools/start.sh before every request, so this file can be updated
# while the relay is running. It defines the fixed verbs the relay accepts:
# host steps (setup, analyze, test, build, rules, git) and device steps (adb
# taps, typing, screenshots, logs). run_line at the bottom is the only entry
# point; a line that is not one of its verbs is ignored.

TRAILER=$'\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_016XgwNa5VZAaSY3tdXzD9Ba'

# ------------------------------------------------------------ host steps ---
do_platform() {
  need flutter "Open a terminal where 'flutter --version' works and run this again." || return 1
  flutter --version | head -1
  if [ ! -d android ]; then
    echo "Adding the Android platform (the hand-written files are kept)"
    local B
    B="$(mktemp -d)"
    cp -R lib test "$B"/ || return 1
    cp README.md pubspec.yaml .gitignore analysis_options.yaml firebase.json "$B"/ || return 1
    flutter create . --platforms=android --project-name ica16_cloud_quiz --org com.saketh || return 1
    rm -rf lib test
    cp -R "$B"/lib "$B"/test . || return 1
    cp "$B"/README.md "$B"/pubspec.yaml "$B"/.gitignore "$B"/analysis_options.yaml "$B"/firebase.json . || return 1
  else
    echo "android/ already exists, skipping flutter create"
  fi
  local M=android/app/src/main/AndroidManifest.xml
  grep -q 'android.permission.INTERNET' "$M" ||
    perl -0pi -e 's/(<manifest[^>]*>)/$1\n    <uses-permission android:name="android.permission.INTERNET" \/>/' "$M"
  perl -pi -e 's/android:label="ica16_cloud_quiz"/android:label="ICA16 Cloud Quiz"/' "$M"
  if [ -f android/app/build.gradle.kts ]; then
    perl -pi -e 's/minSdk = flutter\.minSdkVersion/minSdk = maxOf(flutter.minSdkVersion, 23)/' android/app/build.gradle.kts
  fi
  grep -n 'INTERNET' "$M"
  flutter pub get
}

do_configure() {
  need firebase "Run: npm install -g firebase-tools" || return 1
  firebase projects:list > /dev/null 2>&1 || firebase login || return 1
  command -v flutterfire > /dev/null 2>&1 || dart pub global activate flutterfire_cli
  if [ ! -f lib/firebase_options.dart ] || [ ! -f android/app/google-services.json ]; then
    [ "$ALLOW_FIREBASE" = y ] || { echo "Firebase changes were not approved."; return 1; }
    flutterfire configure --project="$FIREBASE_PROJECT" --platforms=android \
      --android-package-name="$PKG" --yes || return 1
  else
    echo "FlutterFire configuration already present"
  fi
  # flutterfire rewrites firebase.json: make sure the rules pointer is there.
  python3 - << 'PY'
import json
path = 'firebase.json'
try:
    data = json.load(open(path))
except Exception:
    data = {}
data.setdefault('firestore', {})['rules'] = 'firestore.rules'
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY
  test -f lib/firebase_options.dart && echo "lib/firebase_options.dart is present"
}

do_firestore() {
  [ "$ALLOW_FIREBASE" = y ] || { echo "Firebase changes were not approved."; return 1; }
  if firebase firestore:databases:list --project "$FIREBASE_PROJECT" 2>&1 | grep -q "(default)"; then
    echo "The (default) Firestore database already exists in $FIREBASE_PROJECT"
  else
    echo "Creating the (default) Firestore database: Standard edition, Native mode, nam5"
    if ! firebase firestore:databases:create "(default)" --location=nam5 --edition=standard --project "$FIREBASE_PROJECT"; then
      echo "Could not create the database from the command line."
      echo "Create it by hand, then run this step again:"
      echo "  https://console.firebase.google.com/project/$FIREBASE_PROJECT/firestore"
      echo "  Create database > Standard edition > production mode"
      return 1
    fi
  fi
  firebase deploy --only firestore:rules --project "$FIREBASE_PROJECT" 2>&1 | tee "$EVID/rules_deploy_output.txt"
}

do_firestore_api() {
  [ "$ALLOW_FIREBASE" = y ] || { echo "Firebase changes were not approved."; return 1; }
  echo "Deploying the rules first: firebase-tools turns on the Cloud Firestore API if it is off"
  firebase deploy --only firestore:rules --project "$FIREBASE_PROJECT" --non-interactive 2>&1 | tail -25
  local i
  for i in 1 2 3 4 5 6; do
    if do_firestore; then return 0; fi
    echo "retry $i: waiting 20 s for the API change to propagate"
    sleep 20
  done
  return 1
}

do_cloudlist() {
  [ -f "$USERS" ] || { echo "no test users recorded"; return 1; }
  # shellcheck disable=SC1090
  source "$USERS"
  local key base tokA tokB
  key="$(python3 -c 'import json; print(json.load(open("android/app/google-services.json"))["client"][0]["api_key"][0]["current_key"])')" || return 1
  rest_token() {
    curl -s -m 20 -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$key" \
      -H 'Content-Type: application/json' \
      -d "{\"email\":\"$1\",\"password\":\"$2\",\"returnSecureToken\":true}" |
      python3 -c 'import json, sys; print(json.load(sys.stdin).get("idToken", ""))'
  }
  tokA="$(rest_token "$A_EMAIL" "$A_PASSWORD")"
  tokB="$(rest_token "$B_EMAIL" "$B_PASSWORD")"
  if [ -z "$tokA" ] || [ -z "$tokB" ]; then echo "REST sign-in failed"; return 1; fi
  base="https://firestore.googleapis.com/v1/projects/$FIREBASE_PROJECT/databases/(default)/documents/users/$A_UID/attempts"
  {
    echo "Independent server read over the Firestore REST API (not the app, no SDK cache)"
    echo "project: $FIREBASE_PROJECT   checked_at_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ')   commit: $(git rev-parse --short HEAD)"
    echo
    echo "== Signed in as test user A (owner): list users/..${A_UID: -6}/attempts"
    curl -s -m 20 -H "Authorization: Bearer $tokA" "$base?pageSize=300" | SUFFIX_UID="${A_UID: -6}" python3 -B tools/cloud_list.py owner
    echo
    echo "== Signed in as test user B (..${B_UID: -6}): read user A's attempts (must be denied)"
    curl -s -m 20 -H "Authorization: Bearer $tokB" "$base?pageSize=1" | python3 -B tools/cloud_list.py other
  } | tee "$EVID/cloud_rest_listing.txt"
}

do_users() {
  if [ -f "$USERS" ]; then
    echo "Test users are already recorded in tools/.relay"
    return 0
  fi
  [ "$ALLOW_USERS" = y ] || { echo "Creating test users was not approved."; return 1; }
  local key tmp who up email pass resp uid
  key="$(python3 -c 'import json; print(json.load(open("android/app/google-services.json"))["client"][0]["api_key"][0]["current_key"])')" || return 1
  tmp="$USERS.tmp"
  : > "$tmp"
  for who in a b; do
    up="$(echo "$who" | tr a-z A-Z)"
    email="ica16.user.$who.$(openssl rand -hex 3)@example.com"
    pass="Ica16-$(openssl rand -hex 6)"
    resp="$(curl -s -m 20 -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$key" \
      -H 'Content-Type: application/json' \
      -d "{\"email\":\"$email\",\"password\":\"$pass\",\"returnSecureToken\":true}")"
    uid="$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("localId", ""))
except Exception:
    print("")')"
    if [ -z "$uid" ]; then
      echo "Could not create test user $up: $(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("error", {}).get("message", "unknown error"))
except Exception:
    print("unreadable response")')"
      echo "Create two users by hand in the Firebase console (Authentication > Users),"
      echo "then write tools/.relay/test_users.env with A_EMAIL, A_PASSWORD, A_UID,"
      echo "B_EMAIL, B_PASSWORD and B_UID."
      rm -f "$tmp"
      return 1
    fi
    printf '%s_EMAIL=%s\n%s_PASSWORD=%s\n%s_UID=%s\n' "$up" "$email" "$up" "$pass" "$up" "$uid" >> "$tmp"
    echo "Created test user $up (UID ..${uid: -6})"
  done
  mv "$tmp" "$USERS"
  chmod 600 "$USERS"
}

do_analyze() {
  {
    flutter --version
    echo
    firebase --version 2> /dev/null | sed 's/^/firebase-tools /'
  } > "$EVID/env.txt" 2>&1
  flutter analyze 2>&1 | tee "$EVID/flutter_analyze_output.txt"
}

do_unittest() {
  flutter test 2>&1 | tee "$EVID/flutter_test_output.txt"
}

do_build() {
  local kind="${1:-both}" commit
  commit="$(git rev-parse --short HEAD 2> /dev/null || echo uncommitted)"
  if [ "$kind" = evidence ] || [ "$kind" = both ]; then
    echo "Building the evidence APK (release mode, fault lab compiled in) at $commit"
    flutter build apk --release --dart-define=ICA16_DEV_TOOLS=true --dart-define=GIT_COMMIT="$commit" || return 1
    cp build/app/outputs/flutter-apk/app-release.apk "$EVIDENCE_APK" || return 1
  fi
  if [ "$kind" = release ] || [ "$kind" = both ]; then
    echo "Building the submission APK (release mode, no fault lab) at $commit"
    flutter build apk --release --dart-define=GIT_COMMIT="$commit" || return 1
    cp build/app/outputs/flutter-apk/app-release.apk "$RELEASE_APK" || return 1
    ls -lh "$RELEASE_APK"
  fi
}

commit_group() {
  # commit_group "message" path...
  local message="$1"
  shift
  git add -- "$@" || return 1
  git commit -q -m "${message}${TRAILER}"
}

do_history() {
  if [ -d .git ]; then
    echo "git history already exists"
    git log --oneline | cat
    return 0
  fi
  git init -q -b main || return 1
  git add -A
  git rm -r -q --cached --ignore-unmatch lib test tools docs README.md \
    firestore.rules firebase.json "Start ICA16.command"
  git add lib/main.dart lib/app.dart lib/config.dart lib/util lib/widgets \
    lib/services/auth_gateway.dart lib/services/firebase_auth_gateway.dart \
    lib/screens/sign_in_screen.dart lib/screens/home_screen.dart
  git commit -q -m "Step 1: Flutter app, Firebase init before runApp, email/password sign-in gate${TRAILER}"
  commit_group "Step 2: Class A OpenTDB request with timeout, API-code and schema validation" \
    lib/models/question.dart lib/services/trivia_api.dart \
    lib/services/fault_switches.dart test/question_parsing_test.dart
  commit_group "Step 3: quiz state machine, one-answer scoring, review of ten answers, replay" \
    lib/state lib/screens/play_screen.dart lib/screens/review_screen.dart \
    test/quiz_controller_test.dart
  commit_group "Step 4: create-once Firestore transaction, server-only verification, rules" \
    lib/models/attempt.dart lib/services/attempt_store.dart \
    lib/services/firestore_attempt_store.dart lib/screens/attempts_screen.dart \
    firestore.rules firebase.json
  commit_group "Development-only fault lab: question faults, save faults, rule probes" \
    lib/services/rule_probes.dart lib/screens/dev_lab_screen.dart
  git add -A
  git commit -q -m "README, Mac helper script, device relay and test scenarios${TRAILER}"
  git log --oneline | cat
}

do_commit() {
  local message="$1"
  if ! [[ "$message" =~ $SAFE_MSG ]]; then
    echo "commit message has characters that are not allowed"
    return 1
  fi
  [ -d .git ] || { echo "no git repository yet (run: history)"; return 1; }
  git add -A
  if git diff --cached --quiet; then
    echo "nothing to commit"
    return 0
  fi
  git commit -q -m "${message}${TRAILER}" || return 1
  git log --oneline -1 | cat
}

do_publish() {
  [ "$ALLOW_GITHUB" = y ] || { echo "Publishing to GitHub was not approved."; return 1; }
  [ -d .git ] || { echo "no git repository yet"; return 1; }
  if git remote get-url origin > /dev/null 2>&1; then
    git push -u origin main 2>&1 | tail -3
  else
    need gh "Install the GitHub CLI, or create the repo by hand and add it as origin." || return 1
    gh auth status > /dev/null 2>&1 || { echo "gh is not signed in (run: gh auth login)"; return 1; }
    gh repo create ica16-cloud-quiz --public --source=. --remote=origin --push || return 1
  fi
  git remote get-url origin | tee "$RELAY/repo_url.txt"
  git log --oneline -1 | cat
}

do_apicheck() {
  curl -s -m 15 "$API_URL" | python3 -c '
import datetime, json, sys
data = json.load(sys.stdin)
results = data.get("results", [])
print("checked_at_utc:", datetime.datetime.now(datetime.timezone.utc).isoformat())
print("url:", sys.argv[1])
print("response_code:", data.get("response_code"))
print("results:", len(results))
print("categories:", sorted(set(r.get("category") for r in results)))
print("difficulties:", sorted(set(r.get("difficulty") for r in results)))
print("types:", sorted(set(r.get("type") for r in results)))
print("incorrect_answers per question:", sorted(set(len(r.get("incorrect_answers", [])) for r in results)))
' "$API_URL" | tee "$EVID/T02_api_response_summary.txt"
}

# ---------------------------------------------------------- device steps ---
A() { adb -s "$SERIAL" "$@" < /dev/null; }

screen_size() {
  local s
  s="$(A shell wm size | tr -d '\r' | awk -F': ' '/Physical/ {print $2}')"
  W="${s%x*}"
  H="${s#*x}"
  [[ "$W" =~ ^[0-9]+$ ]] || W=1080
  [[ "$H" =~ ^[0-9]+$ ]] || H=2400
}

ensure_device() {
  need adb "Install Android platform-tools (Android Studio > SDK Manager)." || return 1
  if ! adb devices < /dev/null | awk 'NR>1 && $2=="device"' | grep -q .; then
    local avd
    avd="$(emulator -list-avds 2> /dev/null | grep -v '^INFO' | head -1)"
    if [ -z "$avd" ]; then
      echo "No Android emulator or phone found. Create one in Android Studio"
      echo "(Device Manager) or plug in a phone with USB debugging."
      return 1
    fi
    echo "Booting emulator $avd"
    nohup emulator -avd "$avd" -netdelay none -netspeed full > /dev/null 2>&1 &
  fi
  adb wait-for-device < /dev/null
  until [ "$(adb shell getprop sys.boot_completed 2> /dev/null < /dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
  SERIAL="$(adb devices < /dev/null | awk 'NR>1 && $2=="device"{print $1; exit}')"
  screen_size
  echo "Device ready: $SERIAL ${W}x${H}"
}

need_device() { [ -n "$SERIAL" ] || ensure_device; }

launch() { A shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1; }

dump() {
  local _
  for _ in 1 2 3; do
    A shell uiautomator dump /sdcard/ica16_ui.xml > /dev/null 2>&1 &&
      A exec-out cat /sdcard/ica16_ui.xml > "$UI" 2> /dev/null &&
      grep -q "<node" "$UI" && return 0
    sleep 1
  done
  return 1
}

texts() { dump && python3 -B tools/ui_find.py "$UI" texts x; }
has() { python3 -B tools/ui_find.py "$UI" has "$1"; }
shot() { A exec-out screencap -p > "$SHOTS/$1.png" && echo "    saved docs/evidence/screens/$1.png"; }

wait_text() {
  local end=$((SECONDS + ${2:-30}))
  while [ $SECONDS -lt $end ]; do
    dump && has "$1" && return 0
    sleep 1
  done
  return 1
}

hide_keyboard() {
  if A shell dumpsys input_method | grep -q "mInputShown=true"; then
    A shell input keyevent 4
    sleep 1
  fi
}

swipe_up() { A shell input swipe $((W / 2)) $((H * 60 / 100)) $((W / 2)) $((H * 30 / 100)) 300; sleep 1; }
swipe_down() { A shell input swipe $((W / 2)) $((H * 30 / 100)) $((W / 2)) $((H * 60 / 100)) 300; sleep 1; }

# tap_label LABEL [find|field] [INDEX] [TAPS]: scrolls until the widget is in view.
tap_label() {
  local label="$1" mode="${2:-find}" index="${3:-0}" taps="${4:-1}" reuse="${5:-}" pos x y try
  for try in 1 2 3 4 5 6 7 8; do
    if [ "$try" = 1 ] && [ "$reuse" = reuse ]; then :; else dump; fi
    if pos="$(python3 -B tools/ui_find.py "$UI" "$mode" "$label" "$index")"; then
      x="${pos% *}"
      y="${pos#* }"
      if [ "$y" -gt $((H * 93 / 100)) ]; then swipe_up; continue; fi
      if [ "$y" -lt $((H * 4 / 100)) ]; then swipe_down; continue; fi
      if [ "$taps" = 2 ]; then
        A shell "input tap $x $y; input tap $x $y"
      else
        A shell input tap "$x" "$y"
      fi
      echo "    tapped \"$label\" at $x,$y (taps: $taps)"
      sleep 1
      return 0
    fi
    if [ "$try" -le 4 ]; then swipe_up; else swipe_down; swipe_down; fi
  done
  echo "    could not find \"$label\" on screen"
  return 1
}

type_text() { # replaces whatever is in the focused field
  A shell input keyevent 123
  A shell input keyevent $(printf '67 %.0s' $(seq 1 70))
  A shell "input text '$1'"
  sleep 1
}

cred_value() {
  [ -f "$USERS" ] || { echo "    no test users recorded" >&2; return 1; }
  # shellcheck disable=SC1090
  source "$USERS"
  case "$1" in
    a-email) printf '%s' "$A_EMAIL" ;;
    a-password) printf '%s' "$A_PASSWORD" ;;
    a-uid) printf '%s' "$A_UID" ;;
    b-email) printf '%s' "$B_EMAIL" ;;
    b-password) printf '%s' "$B_PASSWORD" ;;
    b-uid) printf '%s' "$B_UID" ;;
    bad-password) printf '%s' "Wrong-password-000" ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------- composite verbs ---
# signin_as a|b: ends on the home screen signed in as that test user.
signin_as() {
  local who="$1" uid email pass end
  uid="$(cred_value "$who-uid")" || return 1
  email="$(cred_value "$who-email")" || return 1
  pass="$(cred_value "$who-password")" || return 1
  end=$((SECONDS + 45))
  while [ $SECONDS -lt $end ]; do
    if dump; then
      if has "Sign in to play"; then break; fi
      if has "UID ..${uid: -6}"; then
        echo "    already signed in as test user $who (UID ..${uid: -6})"
        return 0
      fi
      if has "Sign out"; then tap_label "Sign out" find 0 1 reuse; fi
    fi
    sleep 1
  done
  has "Sign in to play" || { echo "    FAIL: the sign-in screen did not appear"; return 1; }
  tap_label "Email" field 0 1 || return 1
  type_text "$email"
  tap_label "Password" field 1 1 || return 1
  type_text "$pass"
  hide_keyboard
  tap_label "Sign in" find 0 1 || return 1
  echo "    typed the email and password of test user $who (values not logged)"
  if wait_text "UID ..${uid: -6}" 40; then
    echo "    PASS: signed in as test user $who (UID ..${uid: -6})"
  else
    echo "    FAIL: the home screen with UID ..${uid: -6} did not appear"
    return 1
  fi
}

# play_round [CHOICE]: from any question, answers CHOICE (default 1) on every
# remaining question until the results screen is showing.
play_round() {
  local choice="${1:-1}" i
  for i in $(seq 1 60); do
    if ! dump; then sleep 1; continue; fi
    if has "Final score"; then
      echo "    round finished"
      return 0
    fi
    if has "(your answer,"; then
      if has "Question 10 of 10"; then
        tap_label "See results" find 0 1 reuse || return 1
      else
        tap_label "Next question" find 0 1 reuse || return 1
      fi
    elif has "Choice $choice:"; then
      tap_label "Choice $choice:" find 0 1 reuse || return 1
    else
      sleep 1
    fi
  done
  echo "    FAIL: the round did not finish"
  return 1
}

# wait_any SECONDS "A|B": waits until one of the texts is on screen.
wait_any() {
  local end=$((SECONDS + $1)) list="$2" old="$IFS" items t
  IFS='|'
  read -r -a items <<< "$list"
  IFS="$old"
  while [ $SECONDS -lt $end ]; do
    if dump; then
      for t in "${items[@]}"; do
        if has "$t"; then
          echo "    PASS: \"$t\" appeared"
          return 0
        fi
      done
    fi
    sleep 1
  done
  echo "    FAIL: none of \"$list\" appeared within $1 s"
  return 1
}

# Confirms that no test password is in any file that could be committed and
# that the app logs contain no test email.
do_secretscan() {
  [ -f "$USERS" ] || { echo "no test users recorded"; return 1; }
  # shellcheck disable=SC1090
  source "$USERS"
  local bad=0 v
  for v in "$A_PASSWORD" "$B_PASSWORD"; do
    if grep -rIlF -- "$v" docs lib test tools/scenarios README.md firestore.rules 2> /dev/null | grep -q .; then bad=1; fi
  done
  {
    echo "secret scan $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [ "$bad" = 0 ]; then
      echo "PASS: no test password appears in docs/, lib/, test/, tools/scenarios, README.md or firestore.rules"
    else
      echo "FAIL: a test password appears in a file that could be committed"
    fi
    if grep -rIlF -e "$A_EMAIL" -e "$B_EMAIL" docs/evidence/logs 2> /dev/null | grep -q .; then
      echo "FAIL: a test email appears in the app logs"
      bad=1
    else
      echo "PASS: no test email appears in the app logs (docs/evidence/logs)"
    fi
    if grep -rIlE -e 'AIza[0-9A-Za-z_-]{20,}' -e 'BEGIN PRIVATE KEY' docs lib/models lib/services lib/state lib/screens lib/widgets test README.md 2> /dev/null | grep -q .; then
      echo "FAIL: an API key or private key pattern appears in a committed folder"
      bad=1
    else
      echo "PASS: no API key or private key pattern in docs/, lib/ sources, test/ or README.md"
    fi
  } | tee "$EVID/secret_scan.txt"
  [ "$bad" = 0 ]
}

# ------------------------------------------------------------- dispatcher ---
SAFE_NAME='^[A-Za-z0-9_-]+$'
SAFE_MSG='^[A-Za-z0-9 ,.:()/_+-]+$'
SAFE_TEXT='^[A-Za-z0-9@._+:/-]+$'
NUM='^[0-9]+$'

run_line() {
  local line="$1" verb rest value n
  verb="${line%% *}"
  rest=""
  [ "$verb" != "$line" ] && rest="${line#* }"
  case "$verb" in
    # ---- host ----
    platform) do_platform ;;
    configure) do_configure ;;
    firestore) do_firestore ;;
    firestoreapi) do_firestore_api ;;
    dbinfo) firebase firestore:databases:get "(default)" --project "$FIREBASE_PROJECT" 2>&1 | tee "$EVID/firestore_database_info.txt" ;;
    wake) need_device && A shell input keyevent 224 && A shell wm dismiss-keyguard && A shell svc power stayon true && echo "    screen awake" ;;
    users) do_users ;;
    analyze) do_analyze ;;
    unittest) do_unittest ;;
    build) do_build "${rest:-both}" ;;
    history) do_history ;;
    commit) do_commit "$rest" ;;
    publish) do_publish ;;
    apicheck) do_apicheck ;;
    device) ensure_device ;;
    run) [[ "$rest" =~ $SAFE_NAME ]] && need_device && run_scenario "$rest" ;;
    # ---- device ----
    shot) [[ "$rest" =~ $SAFE_NAME ]] && need_device && shot "$rest" ;;
    texts) need_device && texts ;;
    tap) need_device && tap_label "$rest" find 0 1 ;;
    tap2) need_device && tap_label "$rest" find 0 2 ;;
    tapif)
      need_device || return 1
      if dump && has "$rest"; then tap_label "$rest" find 0 1; else echo "    \"$rest\" is not on screen, skipped"; fi
      return 0
      ;;
    field)
      need_device || return 1
      n="${rest##*|}"
      [[ "$n" =~ $NUM ]] || n=0
      tap_label "${rest%%|*}" field "$n" 1
      ;;
    type) [[ "$rest" =~ $SAFE_TEXT ]] && need_device && type_text "$rest" && echo "    typed ${#rest} characters" ;;
    cred)
      need_device || return 1
      value="$(cred_value "$rest")" || return 1
      [[ "$value" =~ $SAFE_TEXT ]] || { echo "    credential has unsupported characters"; return 1; }
      type_text "$value"
      echo "    typed $rest (${#value} characters, value not logged)"
      ;;
    wait)
      need_device || return 1
      if wait_text "$rest" 30; then echo "    PASS: \"$rest\" appeared"; else echo "    FAIL: \"$rest\" did not appear within 30 s"; return 1; fi
      ;;
    waitfor)
      need_device || return 1
      n="${rest%% *}"
      value="${rest#* }"
      [[ "$n" =~ $NUM ]] || return 1
      if wait_text "$value" "$n"; then echo "    PASS: \"$value\" appeared"; else echo "    FAIL: \"$value\" did not appear within $n s"; return 1; fi
      ;;
    expect)
      need_device || return 1
      if dump && has "$rest"; then echo "    PASS: screen shows \"$rest\""; else echo "    FAIL: screen does not show \"$rest\""; fi
      return 0
      ;;
    expectnot)
      need_device || return 1
      if dump && has "$rest"; then echo "    FAIL: screen shows \"$rest\""; else echo "    PASS: screen does not show \"$rest\""; fi
      return 0
      ;;
    expectuid)
      need_device || return 1
      value="$(cred_value "$rest-uid")" || return 1
      if dump && has "${value: -6}"; then
        echo "    PASS: UID on screen ends in ${value: -6}, the UID Firebase issued for test user $rest"
      else
        echo "    FAIL: UID suffix ${value: -6} for test user $rest is not on screen"
      fi
      return 0
      ;;
    signin) need_device && signin_as "$rest" ;;
    playround)
      [ -z "$rest" ] && rest=1
      [[ "$rest" =~ $NUM ]] && need_device && play_round "$rest"
      ;;
    waitany)
      need_device || return 1
      n="${rest%% *}"
      value="${rest#* }"
      [[ "$n" =~ $NUM ]] || return 1
      wait_any "$n" "$value"
      ;;
    secretscan) do_secretscan ;;
    cloudlist) do_cloudlist ;;
    back) need_device && A shell input keyevent 4 && sleep 1 ;;
    hidekb) need_device && hide_keyboard ;;
    scroll)
      need_device || return 1
      case "$rest" in
        down) swipe_up ;;
        up) swipe_down ;;
        top) swipe_down; swipe_down; swipe_down; swipe_down ;;
        bottom) swipe_up; swipe_up; swipe_up; swipe_up ;;
        *) return 1 ;;
      esac
      ;;
    net)
      need_device || return 1
      if [ "$rest" = off ]; then
        A shell cmd connectivity airplane-mode enable
        A shell svc wifi disable
        A shell svc data disable
        echo "    network OFF (airplane mode)"
      elif [ "$rest" = on ]; then
        A shell cmd connectivity airplane-mode disable
        A shell svc wifi enable
        A shell svc data enable
        echo "    network ON"
      else
        return 1
      fi
      sleep 2
      ;;
    restart) need_device && A shell am force-stop "$PKG" && sleep 1 && launch && sleep 3 && echo "    app restarted" ;;
    stop) need_device && A shell am force-stop "$PKG" ;;
    launch) need_device && launch && sleep 3 ;;
    sleep) [[ "$rest" =~ $NUM ]] && sleep "$rest" ;;
    note) echo "    NOTE: $rest" ;;
    logs)
      [[ "$rest" =~ $SAFE_NAME ]] || return 1
      need_device || return 1
      A logcat -d -v time | grep -F '[ICA16]' > "$LOGS/$rest.log"
      echo "    saved docs/evidence/logs/$rest.log ($(wc -l < "$LOGS/$rest.log" | tr -d ' ') lines)"
      ;;
    clearlogs) need_device && A logcat -c ;;
    install)
      need_device || return 1
      case "$rest" in
        evidence) A install -r "$EVIDENCE_APK" | tail -1 ;;
        release) A install -r "$RELEASE_APK" | tail -1 ;;
        *) return 1 ;;
      esac
      ;;
    info)
      need_device || return 1
      {
        echo "model=$(A shell getprop ro.product.model)"
        echo "android=$(A shell getprop ro.build.version.release)"
        echo "sdk=$(A shell getprop ro.build.version.sdk)"
        echo "screen=${W}x${H}"
        echo "serial=$SERIAL"
      } | tr -d '\r' | tee "$EVID/device.txt"
      ;;
    *)
      echo "ignored: $verb"
      return 1
      ;;
  esac
}

# run_scenario NAME: runs tools/scenarios/NAME.txt one line at a time and
# writes docs/evidence/runs/NAME.log.
run_scenario() {
  local name="$1" file="tools/scenarios/$1.txt" line rc=0
  [ -f "$file" ] || { echo "no scenario file $file"; return 1; }
  {
    echo "# scenario $name started $(date -u '+%Y-%m-%dT%H:%M:%SZ') device=$SERIAL commit=$(git rev-parse --short HEAD 2> /dev/null || echo uncommitted)"
    while IFS= read -r line <&3 || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in '' | '#'*) continue ;; esac
      echo "[$(date -u '+%H:%M:%SZ')] $line"
      if ! run_line "$line"; then
        echo "    STOPPED: this step failed"
        shot "FAIL_$name"
        texts
        rc=1
        break
      fi
    done 3< "$file"
    echo "# scenario $name finished $(date -u '+%Y-%m-%dT%H:%M:%SZ') result=$([ "$rc" = 0 ] && echo COMPLETED || echo STOPPED)"
    [ "$rc" = 0 ]
  } 2>&1 | tee "$RUNS/$name.log"
}

