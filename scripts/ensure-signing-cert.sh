#!/bin/bash
#
# ensure-signing-cert.sh — guarantee a *stable* self-signed code-signing
# identity exists, then print its name on stdout.
#
# Why this exists
# ---------------
# dBrief is not in the Apple Developer Program, so historically `make sign`
# used ad-hoc signing (`codesign --sign -`). Ad-hoc signatures have no stable
# identity: every build gets a fresh code-directory hash. macOS TCC (the
# Privacy database behind Screen Recording, etc.) pins each grant to the
# signing identity's *designated requirement*, so after every release the new
# binary no longer matches the stored grant — the toggle still *looks* enabled,
# but `CGPreflightScreenCaptureAccess()` returns false. Screen Recording does
# not silently re-prompt the way Microphone / Speech do, which is why it needs
# the confusing toggle-off/on + restart dance.
#
# Signing every build with the *same* self-signed certificate gives TCC a
# stable identity to match, so Screen Recording (and the other restart-only
# permissions) survive updates — both on this machine and, for DMG downloads,
# on end-user machines (the public cert is embedded in every release we ship).
#
# This is fully non-interactive: the cert lives in a dedicated keychain whose
# password we control, so `codesign` never has to prompt. It is idempotent —
# safe to run on every `make app`, including from a Homebrew-from-source build.
#
# stdout: the identity name to pass to `codesign --sign` (nothing else).
# stderr: human-readable progress / warnings.
#
set -euo pipefail

CERT_NAME="${SIGNING_CERT_NAME:-dBrief Self-Signed}"
KEYCHAIN_NAME="dbrief-signing.keychain-db"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME"
# Password for our *dedicated* keychain only — never the user's login keychain.
# Known to us so the whole flow stays non-interactive.
KEYCHAIN_PW="dbrief-signing"

log() { echo "ensure-signing-cert: $*" >&2; }

# Add a keychain to the user search list (so `codesign` / `find-identity` see
# it) without dropping the keychains already there.
add_to_search_list() {
  local kc="$1"
  if security list-keychains -d user | grep -q "$kc"; then
    return 0
  fi
  local others
  others="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$kc" $others >&2
}

# Fast path: identity already present and visible — just make sure it's usable.
if [ -f "$KEYCHAIN_PATH" ]; then
  add_to_search_list "$KEYCHAIN_PATH"
  security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
fi
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  log "reusing existing identity \"$CERT_NAME\""
  echo "$CERT_NAME"
  exit 0
fi

log "creating stable self-signed code-signing identity \"$CERT_NAME\"…"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Minimal x509 profile for a code-signing leaf: not a CA, digitalSignature +
# codeSigning EKU. 10-year validity so the cert outlives many releases.
cat > "$tmp/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_codesign
[ dn ]
CN = $CERT_NAME
[ v3_codesign ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/openssl.cnf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$CERT_NAME" -out "$tmp/cert.p12" -passout pass:dbrief >/dev/null 2>&1

# Create (or reuse) our dedicated keychain and import the identity, granting
# codesign/security non-interactive access to the private key.
# Keep every `security` mutation off stdout — only the final identity name may
# reach stdout (the Makefile captures it).
if [ ! -f "$KEYCHAIN_PATH" ]; then
  security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_PATH" >&2
fi
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN_PATH" >&2
# No auto-lock timeout, so long builds never hit a re-lock prompt.
security set-keychain-settings "$KEYCHAIN_PATH" >&2
security import "$tmp/cert.p12" -k "$KEYCHAIN_PATH" -P dbrief \
  -T /usr/bin/codesign -T /usr/bin/security >&2
# Allow Apple tooling (codesign) to use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$KEYCHAIN_PW" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
add_to_search_list "$KEYCHAIN_PATH"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  log "ERROR: identity \"$CERT_NAME\" not found after import."
  exit 1
fi

log "created identity \"$CERT_NAME\" in $KEYCHAIN_NAME"
echo "$CERT_NAME"
