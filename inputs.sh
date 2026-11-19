#!/usr/bin/env bash
# Values always come from the current SSH operator.
INPUTS_BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
prompt_value() {
    local kind=$1 prompt=$3
    local -n field=$2
    while true; do
        read -e -r -p "$prompt" field </dev/tty || die 'Input cancelled.'
        if python3 - "$INPUTS_BASE" "$kind" "$field" <<'PY'
import ipaddress, sys
sys.path.insert(0, sys.argv[1])
from config import DEFAULTS, validate
try:
    if sys.argv[2] == 'domain':
        validate(dict(DEFAULTS, domain=sys.argv[3]))
    elif sys.argv[2] == 'cdn':
        validate(dict(DEFAULTS, cdn_domain=sys.argv[3]))
    else:
        ipaddress.IPv4Address(sys.argv[3])
except ValueError as exc:
    print(f'Invalid value: {exc} Please enter this field again.', file=sys.stderr)
    raise SystemExit(1)
PY
        then break; fi
    done
}
collect_inputs() {
    if [[ -z "$DOMAIN" || -z "$INBOUND" || -z "$CDN_DOMAIN" ]]; then
        [[ -r /dev/tty ]] || die 'A TTY or --domain, --inbound and --cdn-domain is required.'
        printf '\nSetup: origin domain with DNS A pointing to the VPS, a separate CDN domain, and one public IPv4.\n'
        ip -o -4 addr show scope global
        if [[ -z "$DOMAIN" ]]; then prompt_value domain DOMAIN 'Origin domain (vpn.example.com): '; fi
        if [[ -z "$INBOUND" ]]; then prompt_value inbound INBOUND 'VPS public IPv4: '; fi
        if [[ -z "$CDN_DOMAIN" ]]; then prompt_value cdn CDN_DOMAIN 'CDN domain (cdn.example.com): '; fi
    fi
    OUTBOUND=${OUTBOUND:-$INBOUND}
    [[ -n "$DOMAIN" && -n "$INBOUND" && -n "$CDN_DOMAIN" ]] || die 'Origin, CDN domain and IPv4 are required.'
}
