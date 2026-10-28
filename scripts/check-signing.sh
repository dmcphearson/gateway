#!/bin/sh
# Fails if signing identity or team settings leak into the committed project.
# They belong in Config/Signing.local.xcconfig, which stays out of git.
set -eu
cd "$(dirname "$0")/.."

project="AWS CLI Gateway.xcodeproj/project.pbxproj"
status=0

if grep -nE 'DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY|PROVISIONING_PROFILE' "$project"; then
    echo "error: signing settings found in $project; move them to Config/Signing.local.xcconfig" >&2
    status=1
fi

if git ls-files --error-unmatch Config/Signing.local.xcconfig >/dev/null 2>&1; then
    echo "error: Config/Signing.local.xcconfig is tracked; it must stay local" >&2
    status=1
fi

exit $status
