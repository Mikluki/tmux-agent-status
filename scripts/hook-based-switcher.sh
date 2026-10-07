#!/usr/bin/env bash

# fzf target switcher — hierarchical session/window/pane list with management actions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"
WAIT_DIR="$STATUS_DIR/wait"

# shellcheck source=lib/session-status.sh
source "$SCRIPT_DIR/lib/session-status.sh"
# shellcheck source=lib/selection-targets.sh
source "$SCRIPT_DIR/lib/selection-targets.sh"
# shellcheck source=lib/pins.sh
source "$SCRIPT_DIR/lib/pins.sh"

status_icon() {
    case "$1" in
        working) printf '\033[1;33m⣾\033[0m' ;;
        done) printf '\033[1;32m✓\033[0m' ;;
        ask) printf '\033[1;31m?\033[0m' ;;
        wait) printf '\033[1;36m⏸\033[0m' ;;
        *) printf '\033[90m·\033[0m' ;;
    esac
}

best_status_for_panes() {
    local session="$1"
    shift

    local best_status=""
    local best_priority=0
    local pane_id=""
    for pane_id in "$@"; do
        [ -n "$pane_id" ] || continue

        local pane_status pane_priority
        pane_status=$(get_pane_status "$session" "$pane_id")
        pane_priority=$(status_priority "$pane_status")
        if [ "$pane_priority" -gt "$best_priority" ]; then
            best_priority="$pane_priority"
            best_status="$pane_status"
        fi
    done

    printf '%s\n' "$best_status"
}

# How long a pane has held its current state, from the mtime of the status
# file the hooks rewrite on every transition. No extra bookkeeping: if there
# is no status file there is no age, and the column stays blank.
pane_age() {
    local session="$1"
    local pane_id="$2"
    local pane_file="$PANE_DIR/${session}_${pane_id}.status"
    local mtime="" now elapsed

    [ -f "$pane_file" ] || return 0

    if [[ "$(uname)" == "Darwin" ]]; then
        mtime=$(stat -f %m "$pane_file" 2>/dev/null || echo "")
    else
        mtime=$(stat -c %Y "$pane_file" 2>/dev/null || echo "")
    fi
    [ -n "$mtime" ] || return 0

    printf -v now '%(%s)T' -1
    elapsed=$(( now - mtime ))
    (( elapsed < 0 )) && elapsed=0

    if (( elapsed < 60 )); then
        printf '%ds\n' "$elapsed"
    elif (( elapsed < 3600 )); then
        printf '%dm\n' "$(( elapsed / 60 ))"
    elif (( elapsed < 86400 )); then
        printf '%dh\n' "$(( elapsed / 3600 ))"
    else
        printf '%dd\n' "$(( elapsed / 86400 ))"
    fi
}

pane_agent_badge() {
    local session="$1"
    local pane_id="$2"
    local agent=""

    [ -f "$PANE_DIR/${session}_${pane_id}.agent" ] && agent=$(< "$PANE_DIR/${session}_${pane_id}.agent")
    [ -n "$agent" ] && printf '  \033[2m(%s)\033[0m' "$agent"
}

SWITCHER_STATE_DIR=""
EXPANDED_SESSIONS_FILE=""
EXPANDED_WINDOWS_FILE=""
MODE_FILE=""

# LOCAL PATCH (not upstream): the preview window was hardcoded as
# "right,65%,border-left,wrap" in three places. Two problems: the 65% left the
# list column too narrow to read a row without truncating, and side-by-side is
# the wrong split for this content - the list is ~33 columns while agent output
# wants the full width. Stack it instead (list on top, preview below) and read
# both position and size from tmux.conf.
#
# Down-position size comes from the popup loop via TMUX_AGENT_PREVIEW_LINES,
# because the loop is what sized the popup and so knows how many lines are
# actually left over; @agent-switcher-preview-lines is the standalone fallback.
PREVIEW_POS=$(tmux show-option -gqv "@agent-switcher-preview-position" 2>/dev/null)
[ -z "$PREVIEW_POS" ] && PREVIEW_POS="down"

preview_window_spec() {
    local size border
    if [ "$PREVIEW_POS" = "right" ]; then
        size=$(tmux show-option -gqv "@agent-switcher-preview-width" 2>/dev/null)
        [ -z "$size" ] && size="55%"
        border="border-left"
    else
        size="${TMUX_AGENT_PREVIEW_LINES:-}"
        [ -z "$size" ] && size=$(tmux show-option -gqv "@agent-switcher-preview-lines" 2>/dev/null)
        [ -z "$size" ] && size=20
        border="border-top"
    fi
    # nowrap: see preview_tail_lines - it is what makes "newest line is the
    # bottom line" exact rather than approximate.
    # noinfo: the capture is tailed to exactly the band height, so fzf's scroll
    # counter would read "1/N" forever - pure noise in the corner.
    printf '%s,%s,%s,nowrap,noinfo' "$PREVIEW_POS" "$size" "$border"
}

# LOCAL PATCH (not upstream): the preview showed the WRONG END of the pane.
# `capture-pane -S -120` returns ~174 lines and fzf renders a preview from its
# first line, so the band showed scrollback from ~150 lines ago rather than what
# the agent is doing now - useless for a status glance. fzf cannot be told to
# scroll to the end (a large +offset clamps with the last line at the TOP of the
# band, showing one line over blanks), so tail the capture to the band height
# instead. With nowrap one captured line is one row, so the newest line always
# lands on the bottom row.
preview_tail_lines() {
    local n=""
    if [ "$PREVIEW_POS" = "right" ]; then
        # Right-hand preview is full popup height; we are running inside the
        # popup, so the terminal knows it.
        n=$(tput lines 2>/dev/null) || n=""
    else
        n="${TMUX_AGENT_PREVIEW_LINES:-}"
        [ -z "$n" ] && n=$(tmux show-option -gqv "@agent-switcher-preview-lines" 2>/dev/null)
    fi
    case "$n" in ''|*[!0-9]*) n=20 ;; esac
    [ "$n" -lt 1 ] && n=1
    printf '%s' "$n"
}

configure_state_dir() {
    SWITCHER_STATE_DIR="$1"
    [ -n "$SWITCHER_STATE_DIR" ] || return 0

    mkdir -p "$SWITCHER_STATE_DIR"
    EXPANDED_SESSIONS_FILE="$SWITCHER_STATE_DIR/expanded_sessions"
    EXPANDED_WINDOWS_FILE="$SWITCHER_STATE_DIR/expanded_windows"
    MODE_FILE="$SWITCHER_STATE_DIR/mode"
    touch "$EXPANDED_SESSIONS_FILE" "$EXPANDED_WINDOWS_FILE"
}

current_mode() {
    local mode=""
    [ -n "$MODE_FILE" ] && [ -f "$MODE_FILE" ] && mode=$(<"$MODE_FILE")
    case "$mode" in
        agents) echo agents ;;
        *)      echo tree ;;
    esac
}

set_mode() {
    local mode="$1"
    [ -n "$MODE_FILE" ] || return 0
    case "$mode" in
        tree|agents) printf '%s' "$mode" > "$MODE_FILE" ;;
    esac
}

toggle_mode() {
    if [ "$(current_mode)" = "agents" ]; then
        set_mode tree
    else
        set_mode agents
    fi
}

# Display priority for agents mode (ask first, then done, then working,
# then wait). Distinct from status_priority used elsewhere for
# "best status" rollups.
agents_mode_priority() {
    case "$1" in
        ask)     echo 5 ;;
        done)    echo 4 ;;
        working) echo 3 ;;
        wait)    echo 2 ;;
        *)       echo 0 ;;
    esac
}

state_has_line() {
    local file="$1"
    local needle="$2"

    [ -f "$file" ] && grep -Fxq -- "$needle" "$file"
}

state_add_line() {
    local file="$1"
    local needle="$2"

    [ -n "$file" ] || return 0
    state_has_line "$file" "$needle" && return 0
    printf '%s\n' "$needle" >> "$file"
}

state_remove_line() {
    local file="$1"
    local needle="$2"
    local tmp_file=""

    [ -f "$file" ] || return 0
    tmp_file="${file}.tmp.$$"
    awk -v needle="$needle" '$0 != needle { print }' "$file" > "$tmp_file"
    mv -f "$tmp_file" "$file"
}

state_remove_prefixed_lines() {
    local file="$1"
    local prefix="$2"
    local tmp_file=""

    [ -f "$file" ] || return 0
    tmp_file="${file}.tmp.$$"
    awk -v prefix="$prefix" 'index($0, prefix) != 1 { print }' "$file" > "$tmp_file"
    mv -f "$tmp_file" "$file"
}

session_expanded() {
    [ -n "$EXPANDED_SESSIONS_FILE" ] && state_has_line "$EXPANDED_SESSIONS_FILE" "$1"
}

window_expanded() {
    [ -n "$EXPANDED_WINDOWS_FILE" ] && state_has_line "$EXPANDED_WINDOWS_FILE" "$1"
}

toggle_expand() {
    local sel_name="$1"
    local sel_type="$2"
    local scope=""

    scope=$(selection_scope "$sel_name" "$sel_type") || return 0

    case "$scope" in
        session)
            if session_expanded "$sel_name"; then
                state_remove_line "$EXPANDED_SESSIONS_FILE" "$sel_name"
                state_remove_prefixed_lines "$EXPANDED_WINDOWS_FILE" "${sel_name}:w"
            else
                state_add_line "$EXPANDED_SESSIONS_FILE" "$sel_name"
            fi
            ;;
        window)
            if window_expanded "$sel_name"; then
                state_remove_line "$EXPANDED_WINDOWS_FILE" "$sel_name"
            else
                state_add_line "$EXPANDED_SESSIONS_FILE" "${sel_name%%:*}"
                state_add_line "$EXPANDED_WINDOWS_FILE" "$sel_name"
            fi
            ;;
    esac
}

get_switcher_rows() {
    local tab=$'\t'
    declare -A session_seen=()
    declare -A session_windows=()
    declare -A window_seen=()
    declare -A window_name=()
    declare -A window_panes=()
    declare -A pane_cmd=()
    # LOCAL PATCH (not upstream): tracks which sessions actually contain an
    # agent, so agent-less and dead sessions can be dropped from the tree.
    declare -A session_has_agent=()
    declare -A pane_pid_map=()
    local session_order=()
    local session="" pane_id="" win_idx="" win_name="" cmd="" pane_title="" pane_pid=""

    # LOCAL PATCH: build the PID map once up front (see find_pane_agent_name_var).
    _build_agent_pid_map

    while IFS=$'\t' read -r session pane_id win_idx win_name cmd pane_title pane_pid; do
        [ -z "$session" ] && continue

        if [ -z "${session_seen[$session]:-}" ]; then
            session_seen[$session]=1
            session_order+=("$session")
        fi

        [ "$pane_title" = "agent-sidebar" ] && continue

        # LOCAL PATCH: flag the session if this pane runs an agent.
        if [ -z "${session_has_agent[$session]:-}" ]; then
            if [ -f "$PANE_DIR/${session}_${pane_id}.agent" ] \
               || find_pane_agent_name_var "$pane_pid"; then
                session_has_agent[$session]=1
            fi
        fi

        local window_key="${session}:${win_idx}"
        if [ -z "${window_seen[$window_key]:-}" ]; then
            window_seen[$window_key]=1
            session_windows[$session]+="${win_idx} "
            window_name[$window_key]="$win_name"
        fi

        window_panes[$window_key]+="${pane_id} "
        pane_cmd[$pane_id]="$cmd"
        pane_pid_map[$pane_id]="$pane_pid"
    done < <(tmux list-panes -a -F \
        "#{session_name}${tab}#{pane_id}${tab}#{window_index}${tab}#{window_name}${tab}#{pane_current_command}${tab}#{pane_title}${tab}#{pane_pid}" 2>/dev/null)

    for session in "${session_order[@]}"; do
        # LOCAL PATCH: hide sessions with no agent in them. Upstream listed
        # every tmux session, so long-lived agent-less ones buried the few
        # that matter.
        [ -n "${session_has_agent[$session]:-}" ] || continue

        local win_list="${session_windows[$session]:-}"
        local session_panes=()
        local window_index=""
        for window_index in $win_list; do
            local session_window_key="${session}:${window_index}"
            local session_panes_string="${window_panes[$session_window_key]:-}"
            local session_pane=""
            for session_pane in $session_panes_string; do
                session_panes+=("$session_pane")
            done
        done

        local session_status session_icon
        session_status=$(best_status_for_panes "$session" "${session_panes[@]}")
        [ -z "$session_status" ] && session_status=$(get_agent_status "$session")
        session_icon=$(status_icon "$session_status")

        local session_marker="•"
        if [ -n "$win_list" ]; then
            if session_expanded "$session"; then
                session_marker="▾"
            else
                session_marker="▸"
            fi
        fi
        # LOCAL PATCH (not upstream): render the status word next to the icon,
        # matching the agents view. Upstream showed the glyph alone, which asks
        # you to decode colour+shape to tell done from working from waiting.
        printf 'S\t%s\t%b  %-7s  %s [session] %s\n' \
            "$session" "$session_icon" "$session_status" "$session_marker" "$session"

        session_expanded "$session" || continue

        for window_index in $win_list; do
            local window_key="${session}:${window_index}"
            local panes_string="${window_panes[$window_key]:-}"
            local panes=()
            local pane=""
            for pane in $panes_string; do
                panes+=("$pane")
            done

            local window_status window_icon
            window_status=$(best_status_for_panes "$session" "${panes[@]}")
            [ -z "$window_status" ] && window_status="$session_status"
            window_icon=$(status_icon "$window_status")
            local window_token="${session}:w${window_index}"
            local window_marker="•"
            if [ -n "$panes_string" ]; then
                if window_expanded "$window_token"; then
                    window_marker="▾"
                else
                    window_marker="▸"
                fi
            fi
            printf 'P\t%s:w%s\t%b  %-7s    %s [window] %s / %s\n' \
                "$session" "$window_index" "$window_icon" "$window_status" \
                "$window_marker" "$session" "${window_name[$window_key]}"

            window_expanded "$window_token" || continue

            for pane in "${panes[@]}"; do
                local pane_status pane_icon badge
                badge=$(pane_agent_badge "$session" "$pane")

                # LOCAL PATCH (not upstream): only agent panes get a status.
                # get_pane_status() falls back to the session-wide status for
                # panes with no status file of their own, so an editor or shell
                # sitting beside an agent claimed to be "working" too. Show a
                # dim dash instead - the pane stays listed and jumpable, it
                # just no longer reports a state it doesn't have.
                if [ -f "$PANE_DIR/${session}_${pane}.agent" ] \
                   || find_pane_agent_name_var "${pane_pid_map[$pane]:-}"; then
                    pane_status=$(get_pane_status "$session" "$pane")
                    pane_icon=$(status_icon "$pane_status")
                else
                    pane_status="-"
                    pane_icon=$'\033[2m·\033[0m'
                fi
                printf 'P\t%s:%s\t%b  %-7s      • [pane] %s / %s : %s%b\n' \
                    "$session" "$pane" "$pane_icon" "$pane_status" \
                    "$session" "${window_name[$window_key]}" \
                    "${pane_cmd[$pane]:-shell}" "$badge"
            done
        done
    done
}

get_switcher_list() {
    get_switcher_rows | cut -f3-
}

# LOCAL PATCH (not upstream): best-effort agent name for a single pane, by
# scanning that pane's own process subtree. Mirrors find_session_agent_name()
# but scoped to a pane instead of a whole session.
#
# Deliberately sets a global instead of echoing, and walks the tree inline
# rather than calling find_matching_descendant_pid. Both helpers memoize the
# PID map into globals, so reaching them through $( ) puts the memo in a
# throwaway subshell and re-runs a full `ps -e` for every pane tested. On a
# 40-pane server that cost ~13s per listing and fzf came up empty while it ran.
# Caller must have run _build_agent_pid_map in THIS shell first.
_PANE_AGENT_NAME=""
find_pane_agent_name_var() {
    local pane_pid="$1"
    _PANE_AGENT_NAME=""
    [ -z "$pane_pid" ] && return 1

    local queue=("$pane_pid") qi=0 cur cur_args children child
    while (( qi < ${#queue[@]} )); do
        cur="${queue[$qi]}"
        ((qi++))
        cur_args="${_AP_ARGS[$cur]:-}"
        if [ -n "$cur_args" ] && [[ "$cur_args" =~ (^|[[:space:]/])(claude|codex|devin)([[:space:]]|$) ]]; then
            case "$cur_args" in
                *claude*) _PANE_AGENT_NAME="claude" ;;
                *codex*)  _PANE_AGENT_NAME="codex" ;;
                *devin*)  _PANE_AGENT_NAME="devin" ;;
                *)        _PANE_AGENT_NAME="agent" ;;
            esac
            return 0
        fi
        children="${_AP_CHILDREN[$cur]:-}"
        for child in $children; do
            queue+=("$child")
        done
    done
    return 1
}

# Flat list of every agent pane (any status), sorted by agents-mode
# priority then by tmux list-panes order. Emits the same `P\t<session>:<pane_id>\t<display>`
# row shape as get_switcher_rows so the existing fzf bindings continue to work.
#
# The tag column is blank when a pane is unpinned, so it doubles as the pin
# indicator — there is no separate marker to read.
get_agents_rows() {
    local tab=$'\t' us=$'\x1f'

    # Build the PID→children map once for this whole listing, in the same
    # shell as the loop below so every pane test reuses it. See the note on
    # find_pane_agent_name_var above.
    _build_agent_pid_map

    local session pane_id win_idx win_name cmd pane_title pane_pid
    local order=0
    # LOCAL PATCH (not upstream): collect first, emit second, so the session
    # column can be padded to the widest name actually present instead of
    # letting each row set its own ragged width.
    local -a collected=()
    local max_sess=0

    while IFS=$'\t' read -r session pane_id win_idx win_name cmd pane_title pane_pid; do
        [ -z "$session" ] && continue
        [ "$pane_title" = "agent-sidebar" ] && continue

        # LOCAL PATCH (not upstream): require the pane to actually run an agent.
        # get_pane_status() falls back to the session-wide status for any pane
        # with no .status file of its own, so upstream listed every plain shell
        # and editor pane sharing a session with an agent as a phantom row
        # wearing that agent's status. Trust the hook-written .agent marker
        # first, then fall back to a per-pane process scan for agents that
        # predate the hook install.
        local agent=""
        [ -f "$PANE_DIR/${session}_${pane_id}.agent" ] && agent=$(<"$PANE_DIR/${session}_${pane_id}.agent")
        if [ -z "$agent" ] && find_pane_agent_name_var "$pane_pid"; then
            agent="$_PANE_AGENT_NAME"
        fi
        [ -z "$agent" ] && continue

        local status
        status=$(get_pane_status "$session" "$pane_id")
        case "$status" in
            working|done|ask|wait) ;;
            *) continue ;;
        esac

        local pri tag age
        pri=$(agents_mode_priority "$status")
        tag=$(pin_tag_for "$pane_id" || true)
        age=$(pane_age "$session" "$pane_id")

        # \x1f, not tab: tag and age are often empty, and read collapses
        # runs of whitespace IFS characters, which would shift the fields.
        collected+=("${pri}${us}${order}${us}${session}${us}${pane_id}${us}${status}${us}${tag}${us}${age}${us}${win_name}")
        (( ${#session} > max_sess )) && max_sess=${#session}

        order=$((order + 1))
    done < <(tmux list-panes -a -F \
        "#{session_name}${tab}#{pane_id}${tab}#{window_index}${tab}#{window_name}${tab}#{pane_current_command}${tab}#{pane_title}${tab}#{pane_pid}" 2>/dev/null)

    {
    local rec
    for rec in "${collected[@]}"; do
        IFS="$us" read -r pri order session pane_id status tag age win_name <<< "$rec"
        # LOCAL PATCH (not upstream): display is
        # `icon  tag  status  age  session  window`. The tag is blank when the
        # pane is unpinned, so it doubles as the pin indicator; age is time in
        # the current state. Dropped the `[claude]` badge (every row carries
        # it, so it separates nothing) and the `:win.pane` suffix (an
        # fzf-invisible tmux coordinate - the real target still travels in
        # field 2, which is what Enter uses).
        # SORTKEY \t row …  SORTKEY = pri (desc) + order (asc)
        printf '%d\t%010d\tP\t%s:%s\t%b  %-4s  %-7s  %-4s  %-*s  %s\n' \
            "$pri" "$order" \
            "$session" "$pane_id" \
            "$(status_icon "$status")" "$tag" "$status" "$age" \
            "$max_sess" "$session" "$win_name"
    done
    } | sort -k1,1nr -k2,2n | cut -f3-
}

emit_rows_for_mode() {
    if [ "$(current_mode)" = "agents" ]; then
        get_agents_rows
    else
        get_switcher_rows
    fi
}

dispatch_close_job() {
    local sel_name="$1"
    local sel_type="$2"
    local close_cmd=""

    printf -v close_cmd '%q ' "$SCRIPT_DIR/close-target.sh" "$sel_name" "$sel_type"
    tmux run-shell -b "$close_cmd"
}

perform_close() {
    local sel_name="$1"
    local sel_type="$2"

    if selection_requires_confirmation "$sel_name" "$sel_type"; then
        local prompt close_cmd confirm_cmd
        prompt=$(selection_close_prompt "$sel_name" "$sel_type")
        printf -v close_cmd '%q ' "$SCRIPT_DIR/close-target.sh" "$sel_name" "$sel_type"
        printf -v confirm_cmd 'run-shell -b %q' "$close_cmd"
        tmux confirm-before -p "$prompt" "$confirm_cmd"
        sleep 0.2
    else
        dispatch_close_job "$sel_name" "$sel_type"
        sleep 0.1
    fi
}

perform_popup_close() {
    local sel_name="$1"
    local sel_type="$2"

    if selection_requires_confirmation "$sel_name" "$sel_type"; then
        local prompt close_cmd confirm_cmd
        prompt=$(selection_close_prompt "$sel_name" "$sel_type")
        printf -v close_cmd '%q ' "$SCRIPT_DIR/close-target.sh" "$sel_name" "$sel_type"
        printf -v confirm_cmd 'run-shell -b %q' "$close_cmd"
        tmux confirm-before -b -p "$prompt" "$confirm_cmd"
    else
        dispatch_close_job "$sel_name" "$sel_type"
    fi
}

emit_close_fzf_actions() {
    local sel_name="$1"
    local sel_type="$2"

    if selection_requires_confirmation "$sel_name" "$sel_type"; then
        printf 'execute-silent(bash %q --popup-close %q %q)+abort\n' \
            "$0" "$sel_name" "$sel_type"
    else
        printf 'execute-silent(bash %q --state-dir %q --close %q %q)+reload(bash %q --state-dir %q --rows)\n' \
            "$0" "$SWITCHER_STATE_DIR" "$sel_name" "$sel_type" "$0" "$SWITCHER_STATE_DIR"
    fi
}

# ─── Picker modes (normal / insert) ──────────────────────────────
# The picker opens in normal mode: single letters act on the selected row
# and nothing types into the query. `i` or `/` switches to insert mode, where
# letters type and filter; esc goes back to normal with the query (and so the
# filtered list) kept, and esc in normal quits. The ctrl binds work in both.
#
# Search stays enabled in normal mode on purpose. fzf's disable-search keeps
# the visible list only until the next reload, then shows every row again
# under a stale query - and agents mode reloads every 2s. Normal mode instead
# binds every typeable key, so the query cannot change there.
PICKER_NORMAL_PROMPT='› '
PICKER_INSERT_PROMPT='/ '
PICKER_NORMAL_HINT='i search  m pin  r rename  p preview  x close  q quit'
PICKER_INSERT_HINT='esc normal  C-i pin  C-r rename  C-p preview  C-x close'

# Keys that act in normal mode and type in insert mode. Every letter, digit,
# and the common symbols, so a stray key in normal mode is a no-op rather
# than a filter.
picker_normal_keys() {
    local keys=() c
    for c in {a..z} {A..Z} {0..9}; do
        keys+=("$c")
    done
    keys+=(space - _ . / '?' '!' '@' '#' '$' '%' '^' '&' '*' '=' '~' '<' '>' '[' ']' '{' '}' '|' ';')
    local IFS=,
    printf '%s\n' "${keys[*]}"
}

picker_header() {
    printf '\033[90m%s\033[0m' "$1"
}

picker_insert_action() {
    printf 'unbind(%s)+change-prompt(%s)+change-header(%s)\n' \
        "$(picker_normal_keys)" "$PICKER_INSERT_PROMPT" "$(picker_header "$PICKER_INSERT_HINT")"
}

picker_normal_action() {
    printf 'rebind(%s)+change-prompt(%s)+change-header(%s)\n' \
        "$(picker_normal_keys)" "$PICKER_NORMAL_PROMPT" "$(picker_header "$PICKER_NORMAL_HINT")"
}

# esc: back to normal from insert (query kept), quit from normal. fzf exports
# the live prompt as $FZF_PROMPT to transform commands.
picker_esc_action() {
    if [ "${FZF_PROMPT:-}" = "$PICKER_INSERT_PROMPT" ]; then
        picker_normal_action
    else
        printf 'abort\n'
    fi
}

parse_args() {
    SWITCHER_COMMAND=""
    SWITCHER_ARG1=""
    SWITCHER_ARG2=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --state-dir)
                configure_state_dir "$2"
                shift 2
                ;;
            --rows|--list|--rows-agents|--rows-tree|--toggle-mode|--tab-action|--rename-action|--preview-action|--esc-action)
                SWITCHER_COMMAND="$1"
                shift
                ;;
            --set-mode|--request-relaunch)
                SWITCHER_COMMAND="$1"
                SWITCHER_ARG1="${2:-}"
                shift 2
                ;;
            --close|--popup-close|--toggle-expand|--close-fzf-actions)
                SWITCHER_COMMAND="$1"
                SWITCHER_ARG1="${2:-}"
                SWITCHER_ARG2="${3:-}"
                shift 3
                ;;
            *)
                return 0
                ;;
        esac
    done
}

# ─── Flag dispatch ────────────────────────────────────────────────
parse_args "$@"

case "${SWITCHER_COMMAND:-}" in
    --rows)
        emit_rows_for_mode
        exit 0
        ;;
    --rows-tree)
        get_switcher_rows
        exit 0
        ;;
    --rows-agents)
        get_agents_rows
        exit 0
        ;;
    --list)
        get_switcher_list
        exit 0
        ;;
    --set-mode)
        set_mode "$SWITCHER_ARG1"
        exit 0
        ;;
    --toggle-mode)
        toggle_mode
        exit 0
        ;;
    --tab-action)
        # ctrl-i and tab are the same byte, so one binding covers both.
        # Behaviour depends on the current mode:
        #   tree   → expand/collapse session/window then reload rows
        #   agents → pin under the derived tag, or unpin a pinned row, then
        #            reload so the tag column shows it. The picker stays
        #            open. Pinning is agents-mode only; tree mode keeps the
        #            structural navigation it needs.
        if [ "$(current_mode)" = "agents" ]; then
            printf "execute-silent(bash %q --toggle {2})+reload(bash %q --state-dir %q --rows)\n" \
                "$SCRIPT_DIR/pin-target.sh" "$0" "$SWITCHER_STATE_DIR"
        else
            printf "execute-silent(bash %q --state-dir %q --toggle-expand {2} {1})+reload(bash %q --state-dir %q --rows)\n" \
                "$0" "$SWITCHER_STATE_DIR" "$0" "$SWITCHER_STATE_DIR"
        fi
        exit 0
        ;;
    --rename-action)
        # r / ctrl-r: pin under a typed tag, or rename. The tag prompt lives on
        # the tmux status line, which the popup covers, so abort the picker and
        # let the prompt (opened with -b) outlive it. Agents mode only.
        if [ "$(current_mode)" = "agents" ]; then
            printf "execute-silent(bash %q --rename {2})+abort\n" "$SCRIPT_DIR/pin-target.sh"
        else
            printf 'ignore\n'
        fi
        exit 0
        ;;
    --esc-action)
        picker_esc_action
        exit 0
        ;;
    --preview-action)
        # Used only by the in-process ctrl-f flow (window display-method).
        # Wrapped popup uses --request-relaunch instead.
        if [ "$(current_mode)" = "agents" ]; then
            printf 'change-preview-window(%s)\n' "$(preview_window_spec)"
        else
            printf 'change-preview-window(hidden)\n'
        fi
        exit 0
        ;;
    --request-relaunch)
        # Signal the popup-loop wrapper to relaunch with new dimensions.
        case "$SWITCHER_ARG1" in
            toggle-mode)
                # LOCAL PATCH (not upstream): upstream re-derived preview
                # visibility from the new mode - agents on, tree off. That held
                # while agents mode always meant preview-on, but once
                # @agent-switcher-preview-default let agents open compact, the
                # mode toggle stopped being an involution:
                #   agents+hidden -C-f-> tree -C-f-> agents+VISIBLE
                # so the view you started in was unreachable and the preview
                # picker cost two presses. Carry the agents-mode preference
                # across instead.
                #
                # Tree still forces the preview off unconditionally: `tab` is
                # expand/collapse there, so a preview switched on in tree mode
                # would have no key to switch it back off.
                prev_pref="$SWITCHER_STATE_DIR/preview-hidden-agents"
                cur=1
                [ -f "$SWITCHER_STATE_DIR/preview-hidden" ] && cur=$(<"$SWITCHER_STATE_DIR/preview-hidden")
                [ "$(current_mode)" = "agents" ] && printf '%s' "$cur" > "$prev_pref"

                toggle_mode

                if [ "$(current_mode)" = "agents" ]; then
                    restored=""
                    [ -f "$prev_pref" ] && restored=$(<"$prev_pref")
                    # No remembered preference (tree-first launch): fall back to
                    # upstream's "agents shows the preview".
                    [ -n "$restored" ] || restored=0
                    printf '%s' "$restored" > "$SWITCHER_STATE_DIR/preview-hidden"
                else
                    printf '1' > "$SWITCHER_STATE_DIR/preview-hidden"
                fi
                ;;
            toggle-preview)
                cur=0
                [ -f "$SWITCHER_STATE_DIR/preview-hidden" ] && cur=$(<"$SWITCHER_STATE_DIR/preview-hidden")
                if [ "$cur" = "1" ]; then
                    printf '0' > "$SWITCHER_STATE_DIR/preview-hidden"
                else
                    printf '1' > "$SWITCHER_STATE_DIR/preview-hidden"
                fi
                # `tab` only toggles the preview in agents mode, so this IS the
                # agents preference that a mode round-trip has to restore.
                if [ "$(current_mode)" = "agents" ]; then
                    cp -f "$SWITCHER_STATE_DIR/preview-hidden" \
                          "$SWITCHER_STATE_DIR/preview-hidden-agents" 2>/dev/null || :
                fi
                ;;
            *)
                # Unknown subcommand: bail without touching the relaunch
                # sentinel so the popup-loop wrapper exits instead of
                # spinning on unchanged state.
                exit 0
                ;;
        esac
        touch "$SWITCHER_STATE_DIR/relaunch"
        exit 0
        ;;
    --close)
        perform_close "$SWITCHER_ARG1" "$SWITCHER_ARG2"
        exit 0
        ;;
    --popup-close)
        perform_popup_close "$SWITCHER_ARG1" "$SWITCHER_ARG2"
        exit 0
        ;;
    --toggle-expand)
        toggle_expand "$SWITCHER_ARG1" "$SWITCHER_ARG2"
        exit 0
        ;;
    --close-fzf-actions)
        emit_close_fzf_actions "$SWITCHER_ARG1" "$SWITCHER_ARG2"
        exit 0
        ;;
esac

# ─── Main: fzf picker ────────────────────────────────────────────
# If the popup-loop wrapper provided a state dir, reuse it (mode and
# preview-hidden state survive across relaunches). Otherwise own one.
if [ -n "${TMUX_AGENT_SWITCHER_STATE_DIR:-}" ]; then
    state_dir="$TMUX_AGENT_SWITCHER_STATE_DIR"
    OWN_STATE_DIR=0
else
    state_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-status-switcher.XXXXXX")
    OWN_STATE_DIR=1
fi
configure_state_dir "$state_dir"

# Initial mode: state file (wrapper) wins; else env var; else tree.
if [ -f "$state_dir/mode" ]; then
    initial_mode=$(<"$state_dir/mode")
else
    initial_mode="${TMUX_AGENT_SWITCHER_MODE:-tree}"
fi
case "$initial_mode" in
    tree|agents) ;;
    *) initial_mode=tree ;;
esac
set_mode "$initial_mode"

socket="$state_dir/fzf.sock"
if [ "$OWN_STATE_DIR" = "1" ]; then
    trap 'rm -rf "$state_dir"' EXIT
else
    trap 'rm -f "$socket"' EXIT
fi

# Background poker for agents-mode live refresh. Only pokes while
# mode=agents — in tree mode it idles.
if command -v curl >/dev/null 2>&1; then
    refresh_action=$(printf 'reload(bash %q --state-dir %q --rows)' "$0" "$state_dir")
    (
        while [ ! -S "$socket" ]; do sleep 0.1; done
        while [ -S "$socket" ]; do
            if [ "$(current_mode)" = "agents" ]; then
                curl --silent --unix-socket "$socket" -X POST http://localhost \
                    -d "$refresh_action" >/dev/null 2>&1 || break
            fi
            sleep 2
        done
    ) &
    refresh_pid=$!
    if [ "$OWN_STATE_DIR" = "1" ]; then
        trap 'kill "$refresh_pid" 2>/dev/null || true; rm -rf "$state_dir"' EXIT
    else
        trap 'kill "$refresh_pid" 2>/dev/null || true; rm -f "$socket"' EXIT
    fi
fi

# Preview-window visibility: state file wins (set by wrapper or prior
# iteration); else default by mode (hidden in tree, shown in agents).
if [ -f "$state_dir/preview-hidden" ] && [ "$(<"$state_dir/preview-hidden")" = "1" ]; then
    preview_hidden_flag=",hidden"
elif [ -f "$state_dir/preview-hidden" ]; then
    preview_hidden_flag=""
elif [ "$initial_mode" = "tree" ]; then
    preview_hidden_flag=",hidden"
else
    preview_hidden_flag=""
fi

# ctrl-p and ctrl-f bindings: preview on/off. ctrl-i (= tab) pins now, so
# preview moved to ctrl-p, and ctrl-f stays a preview alias because that is
# where the muscle memory points. The tree view is retired, so nothing
# switches modes any more and the mode machinery stays pinned at whatever
# @agent-switcher-default-mode says. When wrapped by popup-loop, abort +
# relaunch with new popup geometry (a popup cannot be resized in flight);
# otherwise toggle in place (window display-method).
if [ -n "${TMUX_AGENT_SWITCHER_STATE_DIR:-}" ]; then
    ctrl_p_bind="execute-silent(bash '$0' --state-dir '$state_dir' --request-relaunch toggle-preview)+abort"
else
    ctrl_p_bind="change-preview-window($(preview_window_spec)|$(preview_window_spec),hidden)"
fi
ctrl_f_bind="$ctrl_p_bind"

# LOCAL PATCH (not upstream): the key hints were one 85-column string, which
# tmux clipped to "ctrl-w wai··" in the compact popup, and it described both
# views at once ("tab expand/preview") so half of it was wrong either way.
# Now each picker mode has its own short hint line (see PICKER_*_HINT), and
# change-header swaps it on every mode switch.
tab_bind="transform(bash '$0' --state-dir '$state_dir' --tab-action)"
rename_bind="transform(bash '$0' --state-dir '$state_dir' --rename-action)"
close_bind="transform(bash '$0' --state-dir '$state_dir' --close-fzf-actions {2} {1})"

# Normal-mode letters: the actions, plus `ignore` for every other typeable
# key so nothing reaches the query. Insert mode unbinds this whole set.
normal_binds="j:down,k:up,i:$(picker_insert_action),/:$(picker_insert_action),q:abort"
normal_binds+=",m:$tab_bind,r:$rename_bind,p:$ctrl_p_bind,x:$close_bind"
IFS=, read -r -a _picker_keys <<< "$(picker_normal_keys)"
for _key in "${_picker_keys[@]}"; do
    case "$_key" in
        j|k|i|/|q|m|r|p|x) ;;
        *) normal_binds+=",$_key:ignore" ;;
    esac
done

# LOCAL PATCH (not upstream): when the popup wrapper sized the box it already
# built the row list, so consume that instead of sweeping ps/tmux a second time
# before fzf can draw. Single-use: deleted on read, and every reload binding
# still goes through --rows.
emit_initial_rows() {
    local seed="$state_dir/rows.seed"
    if [ -f "$seed" ]; then
        cat "$seed"
        rm -f "$seed"
        return 0
    fi
    emit_rows_for_mode
}

# LOCAL PATCH (not upstream): this popup's geometry is computed exactly, so it
# cannot inherit the user's interactive fzf preferences. FZF_DEFAULT_OPTS is
# applied before argv, and a `--border` in there makes fzf draw a second frame
# (plus a scrollbar gutter) inside tmux's popup border - 2 rows and ~3 columns
# the size calculation knows nothing about, so the list scrolls and the header
# clips. Drop the inherited options; every flag this picker wants is explicit.
unset FZF_DEFAULT_OPTS FZF_DEFAULT_OPTS_FILE

selected=$(emit_initial_rows | fzf \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=3.. \
    --no-sort \
    --listen="$socket" \
    --preview="id={2}; tmux capture-pane -e -p -t \"\${id##*:}\" -S -120 2>/dev/null | tail -n $(preview_tail_lines)" \
    --preview-window="$(preview_window_spec)${preview_hidden_flag}" \
    --prompt="$PICKER_NORMAL_PROMPT" \
    --header="$(picker_header "$PICKER_NORMAL_HINT")" \
    --header-first \
    --bind="ctrl-j:down,ctrl-k:up" \
    --bind="tab:$tab_bind" \
    --bind="ctrl-f:$ctrl_f_bind" \
    --bind="ctrl-p:$ctrl_p_bind" \
    --bind="ctrl-r:$rename_bind" \
    --bind="ctrl-x:$close_bind" \
    --bind="esc:transform(bash '$0' --state-dir '$state_dir' --esc-action)" \
    --bind="$normal_binds" \
    --layout=reverse \
    --info=hidden \
    --no-separator \
    --no-border \
    --no-scrollbar \
    --height=100% \
    --margin=0 \
    --padding=0)

# ─── Switch to selected target ────────────────────────────────────
if [ -n "$selected" ]; then
    IFS=$'\t' read -r sel_type sel_name _ <<< "$selected"
    selection_switch_client "$sel_name" "$sel_type"
fi
