#!/bin/bash
set -euo pipefail

CERT_NAME="VibeFocus Local Code Signing"

if security find-identity -v -p codesigning | grep -F "$CERT_NAME" >/dev/null 2>&1; then
  echo "OK: Found code signing identity: $CERT_NAME"
  exit 0
fi

cat <<EOF
Missing code signing identity: $CERT_NAME

Create a local code signing certificate:
1) Open Keychain Access
2) Menu: Keychain Access > Certificate Assistant > Create a Certificate
3) Name: $CERT_NAME
4) Identity Type: Self Signed Root
5) Certificate Type: Code Signing
6) Create, then re-run: ./install.sh
EOF

exit 1
