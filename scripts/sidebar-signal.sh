#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/session-status.sh"
source "$SCRIPT_DIR/lib/sidebar-clients.sh"

case "${1:-refresh}" in
    collect)
        wake_collector
        ;;
    active)
        signal_sidebar_clients USR2 active
        ;;
    refresh|*)
        signal_sidebar_clients USR1 all
        ;;
esac
