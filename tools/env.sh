# Sourced by tools/start.sh: finds flutter, firebase, adb and java in the
# usual macOS locations without changing your shell profile.
export PATH="$PATH:$HOME/.pub-cache/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.homebrew/bin:$HOME/flutter/bin:$HOME/development/flutter/bin"
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
export PATH="$PATH:$ANDROID_SDK/platform-tools:$ANDROID_SDK/emulator"
if ! java -version >/dev/null 2>&1; then
  # Fall back to the Java that ships inside Android Studio.
  JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  [ -x "$JBR/bin/java" ] && export JAVA_HOME="$JBR" PATH="$JBR/bin:$PATH"
fi
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1. $2"; return 1; }; }
