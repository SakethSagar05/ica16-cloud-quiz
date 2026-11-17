# ICA 16, Class A: Cloud Quiz

**Course:** CSC 4360 Mobile App Development · **Student:** Saketh Sagar Kokkireni · **Level:** Undergraduate
**Stack:** Flutter/Dart, Open Trivia Database (HTTP GET), Firebase Authentication, Cloud Firestore

A General Knowledge quiz. The app loads exactly 10 easy multiple-choice questions, accepts one answer per question, shows a review of all 10 answers, saves the final score under the signed-in user's own cloud path, and then proves the save with a server-only read.

Evidence for tests T01-T12 is in `docs/evidence/` (screenshots, app logs, run logs). The submitted APK and the evidence document are uploaded to the course portal, not committed.

## How it fits together

```
Sign in ──▶ Firebase Authentication (email/password) ──▶ UID
Start round ──▶ GET opentdb.com (10 s timeout) ──▶ JSON ▶ response_code ▶ schema ──▶ 10 questions
Finish ──▶ frozen payload ──▶ Firestore transaction on users/{uid}/attempts/{roundId}
       ──▶ get(Source.server) on the same document ──▶ "Cloud verified"
```

| Service | Role | File |
|---|---|---|
| Open Trivia Database | Supplies questions over HTTP GET. It never receives scores. | `lib/services/trivia_api.dart`, `lib/models/question.dart` |
| Firebase Authentication | Identifies the user. The UID in the document path comes from here, never from a form field. | `lib/services/firebase_auth_gateway.dart` |
| Cloud Firestore | Stores each completed attempt once and returns it on a server-only read. | `lib/services/firestore_attempt_store.dart` |
| Security rules | Owner-only read, schema-checked create, no update or delete. | `firestore.rules` |
| State machine | Every phase and guard of the app. | `lib/state/quiz_controller.dart` |

### Cloud contract

Path: `users/{authenticatedUid}/attempts/{roundId}`. Exactly six fields:

| Field | Value |
|---|---|
| `schemaVersion` | integer `1` |
| `variant` | string `"A"` |
| `categoryId` | integer `9` |
| `questionCount` | integer `10` |
| `correctCount` | integer `0`-`10` |
| `submittedAt` | `FieldValue.serverTimestamp()` |

The document ID is the round ID. It is generated once with `attempts.doc().id` when a round starts and is reused by every retry of that round. No passwords, tokens, names or question text are stored.

### States

`signedOut → home → loading → playing → readyToSubmit → submitting → verifying → cloudVerified`

Branches: `authError`, `requestError`, `saveUnknown`, `permissionDenied`, `saveFailed` (unavailable, resource-exhausted, unauthenticated), `collision`, `verificationUnavailable`.

- A save that gets no answer in 10 seconds becomes `saveUnknown`, not failed. The timeout does not cancel the operation. **Check the cloud** reads the same round ID from the server: a matching document resolves to `cloudVerified` without writing again; no document plus a finished operation returns to `readyToSubmit` with the same round ID.
- A transaction that succeeds followed by a failed read is `verificationUnavailable`, not a failed save. **Retry verification** only repeats the read.
- Replay and sign-out are disabled while a submission is pending or unresolved.
- Every response is tied to the UID and round ID that started it. If either changed, the response is dropped.
- Retries are user-triggered only. Question requests are at least five seconds apart. Two submissions never run at once.

## Run it

Prerequisites: Flutter SDK, Android Studio with an emulator (or a phone with USB debugging), Firebase CLI, FlutterFire CLI.

```bash
flutter pub get
firebase login
dart pub global activate flutterfire_cli
flutterfire configure --project=<your-project-id> --platforms=android   # writes lib/firebase_options.dart
firebase deploy --only firestore:rules --project <your-project-id>
flutter run
```

`lib/firebase_options.dart` and `android/app/google-services.json` are not committed; `flutterfire configure` regenerates them for your own project.

### Firebase project setup

1. Create (or reuse) a Firebase project that is only used for this class.
2. Firestore: create a **Standard edition, Native mode** database in **production mode**.
3. Authentication: enable **Email/Password**.
4. Create two test users (Authentication > Users > Add user). Keep their passwords out of the repository and out of any evidence.
5. Deploy `firestore.rules` with the command above. Never loosen the rules to get past an error.

On my Mac, `Start ICA16.command` does steps 2, 4 and 5 from the command line after asking for permission: it creates the database with `firebase firestore:databases:create "(default)" --location=nam5 --edition=standard`, creates two throwaway test users through the Firebase Authentication sign-up endpoint, and deploys the rules. The test passwords are generated on the machine and kept in `tools/.relay/`, which is git-ignored.

### Builds

```bash
flutter build apk --release                                      # submission APK, no fault lab
flutter build apk --release --dart-define=ICA16_DEV_TOOLS=true   # same code with the fault lab
flutter run                                                      # debug build, fault lab on
```

## Fault lab (development only)

The fault lab is compiled in only for debug builds or when `ICA16_DEV_TOOLS=true` is passed. The submission APK does not contain it. Every injected fault is labelled **INJECTED FAULT** on screen and `[INJECTED]` in the log, fires once, and then disarms.

| Control | Test | What it does |
|---|---|---|
| Inject bad JSON / API code 1 / nine results | T03 | Feeds a bad body through the real `parseRound` validation instead of calling the network. |
| Inject lost acknowledgement | T09 | Runs the real transaction to completion, then hides its result from the app. |
| Inject unavailable / resource-exhausted | T12 | Throws a modelled repository error. Nothing is sent, so no quota is spent. |
| Run T10 probes | T10 | As user B, reads and writes user A's path against the deployed rules. |
| Run T11 probes | T11 | Tries score 11, an extra field and an update against the deployed rules, then re-reads the original. |

## Tests

```bash
flutter analyze
flutter test
```

`test/question_parsing_test.dart` covers the response validation. `test/quiz_controller_test.dart` covers the state machine with fake services: one answer per question, replay reset, single write on double tap, lost acknowledgement recovery, timeout is unknown rather than failed, distinct denied/unavailable/exhausted errors, verification failure is not a save failure, collision, and the stale-user guard.

The device tests T01-T12 are scripted in `tools/scenarios/` and run against the deployed Firebase project. Their run logs, screenshots and app logs are in `docs/evidence/`.

## Security notes

- No passwords, tokens, private keys or service accounts are in this repository.
- The Firebase client configuration is not secret, but it is still left out; security comes from Authentication and the rules.
- The rules protect ownership, schema and immutability. They do not prove that a client-calculated score is honest: a signed-in user could submit any in-range score for their own account.
- IDs are shown on screen as a six-character suffix unless **Show full IDs** is turned on, so screenshots are redacted by default.

## AI assistance

This project was built with Claude (Anthropic) as a coding assistant. Commits carry a `Co-Authored-By` trailer.
