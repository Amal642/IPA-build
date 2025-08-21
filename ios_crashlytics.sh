#!/bin/sh
set -e

# Go to ios folder
cd ios

# Upload dSYMs using the pod script
./Pods/FirebaseCrashlytics/run
