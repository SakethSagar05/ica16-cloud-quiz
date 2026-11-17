#!/bin/bash
# Double-click this file in Finder. It sets the project up on this Mac
# (Android folder, Firebase configuration, rules, test users, analyzer and
# unit tests) and then stays open so builds and emulator test steps can be
# requested from tools/.relay/requests. Close the window to stop it.
cd "$(dirname "$0")" || exit 1
exec /bin/bash tools/start.sh "$@"
