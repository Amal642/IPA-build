#!/bin/sh
set -e

flutter pub run firebase_crashlytics:upload-symbols --ios
