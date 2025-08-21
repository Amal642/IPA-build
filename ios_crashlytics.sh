#!/bin/sh
set -e

# Run Firebase Crashlytics to upload dSYMs
"${PODS_ROOT}/FirebaseCrashlytics/run"
