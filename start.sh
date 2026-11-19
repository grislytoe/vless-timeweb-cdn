#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME
BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$BASE"
sha256sum --strict -c SHA256SUMS
if [[ "${1:-}" == --update ]]; then
    shift
    exec bash "$BASE/install.sh" --update "$@"
fi
exec bash "$BASE/install.sh" --install "$@"
