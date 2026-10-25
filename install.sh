#!/usr/bin/env bash
# sapi installer.  curl -fsSL https://raw.githubusercontent.com/sapiensmalti/sapi/main/install.sh | bash
#
# What it does, and nothing more:
#   1. downloads one file, `sapi`, to ~/.local/bin (override with SAPI_INSTALL_DIR)
#   2. tells you if docker is missing or ~/.local/bin is not on your PATH
# It does not use sudo, does not edit your shell configuration, does not install Docker.
set -Eeuo pipefail

REPO="${SAPI_REPO:-sapiensmalti/sapi}"
REF="${SAPI_REF:-v0.6.1}"
DIR="${SAPI_INSTALL_DIR:-$HOME/.local/bin}"
URL="${SAPI_URL:-https://raw.githubusercontent.com/$REPO/$REF/sapi}"

die() { printf 'sapi install: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
    Darwin|Linux) ;;
    *) die "unsupported OS: $(uname -s). sapi supports macOS and Linux." ;;
esac
command -v curl >/dev/null 2>&1 || die "curl is required"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL --proto "=https,file" --tlsv1.2 "$URL" -o "$tmp" || die "download failed: $URL"
head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash$' || die "downloaded file does not look like sapi"
bash -n "$tmp" || die "downloaded file failed a syntax check"

mkdir -p "$DIR"
new="$DIR/.sapi.new.$$"
trap 'rm -f "$tmp" "$new"' EXIT
install -m 0755 "$tmp" "$new"
# Rename within the destination directory: a failed download or copy can
# never truncate a working installation, and upgrade never follows a symlink.
mv -f "$new" "$DIR/sapi"
printf 'sapi install: installed %s (v%s)\n' "$DIR/sapi" "$("$DIR/sapi" version)"

case ":$PATH:" in
    *":$DIR:"*) ;;
    *) printf '\n  %s is not on your PATH. Add this to your shell profile:\n\n    export PATH="%s:$PATH"\n' "$DIR" "$DIR" ;;
esac

if ! command -v docker >/dev/null 2>&1; then
    cat <<'EOF'

  Docker is not installed. sapi needs it for isolation.
    macOS:   brew install orbstack        (or Docker Desktop)
    Ubuntu:  sudo apt-get install -y docker.io && sudo usermod -aG docker "$USER"
             then log out and back in.
EOF
fi

printf '\n  Run `sapi` in any project directory to start.\n\n'
