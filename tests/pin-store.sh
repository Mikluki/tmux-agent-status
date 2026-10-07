#!/usr/bin/env bash
# The pin store and the ctrl-i path through pin-target.sh: pinning, renaming,
# unpinning, rejected duplicates, and the free tag derived for an unpinned row.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
MESSAGE_LOG="$TMP_DIR/messages"

mkdir -p "$FAKE_BIN" "$TEST_HOME"

cat > "$FAKE_BIN/tmux" <<'TMUX_EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    show-option)
        [ -f "${TMUX_FAKE_OPTIONS:?}" ] && cat "$TMUX_FAKE_OPTIONS"
        ;;
    set-option)
        if [ "${2:-}" = "-gu" ]; then
            : > "${TMUX_FAKE_OPTIONS:?}"
        else
            printf '%s\n' "${4:-}" > "${TMUX_FAKE_OPTIONS:?}"
        fi
        ;;
    display-message)
        if [ "${2:-}" = "-p" ]; then
            echo "worktree-alpha"
        else
            printf '%s\n' "${2:-}" >> "${TMUX_MESSAGE_LOG:?}"
        fi
        ;;
    command-prompt)
        printf '%s\n' "$*" >> "${TMUX_MESSAGE_LOG:?}"
        ;;
esac
exit 0
TMUX_EOF
chmod +x "$FAKE_BIN/tmux"

export PATH="$FAKE_BIN:$PATH"
export HOME="$TEST_HOME"
export TMUX_FAKE_OPTIONS="$TMP_DIR/options"
export TMUX_MESSAGE_LOG="$MESSAGE_LOG"
: > "$TMUX_FAKE_OPTIONS"
: > "$MESSAGE_LOG"

# shellcheck source=../scripts/lib/pins.sh
source "$REPO_DIR/scripts/lib/pins.sh"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

pins_summary() {
    pins_read | while IFS=$'\t' read -r tag pane _; do
        printf '%s=%s ' "$tag" "$pane"
    done
}

# ── Tag validation ────────────────────────────────────────────────
pin_tag_valid "bug"   || { echo "Assertion failed: 'bug' should be a valid tag" >&2; exit 1; }
pin_tag_valid "abcd"  || { echo "Assertion failed: a four-character tag should be valid" >&2; exit 1; }
pin_tag_valid "abcde" && { echo "Assertion failed: a five-character tag should be rejected" >&2; exit 1; }
pin_tag_valid "a b"   && { echo "Assertion failed: whitespace should be rejected" >&2; exit 1; }
pin_tag_valid "a:b"   && { echo "Assertion failed: the record separator should be rejected" >&2; exit 1; }
pin_tag_valid ""      && { echo "Assertion failed: an empty tag should be rejected" >&2; exit 1; }

# ── Derived tag ───────────────────────────────────────────────────
assert_eq "wor" "$(pin_derive_tag "worktree-a" "api")" "an unpinned row should derive from the window name"
assert_eq "api" "$(pin_derive_tag "" "api")" "a nameless window should fall back to the session name"

# The prefill is always free: when another pane holds the base, the first
# free of base2..base9, so Enter on the prefill pins instead of colliding.
derive_checked() {
    local tag
    tag=$(pin_derive_tag "worktree-a" "api" "$1")
    pin_tag_valid "$tag" || { echo "Assertion failed: derived tag '$tag' should be valid" >&2; exit 1; }
    printf '%s\n' "$tag"
}
assert_eq "wor" "$(derive_checked "%50")" "no pins should derive the bare base"
pin_set "%40" "wor"
assert_eq "wor2" "$(derive_checked "%50")" "a held base should derive base2"
pin_set "%42" "wor2"
assert_eq "wor3" "$(derive_checked "%50")" "held base and base2 should derive base3"
pin_set "%42" "bug"
assert_eq "wor2" "$(derive_checked "%50")" "a freed variant should be reused"
pin_set "%42" "wor2"
for n in 3 4 5 6 7 8 9; do pin_set "%4$n" "wor$n"; done
assert_eq "wor" "$(derive_checked "%50")" "with every variant held, the bare base is left to the rejection"
assert_eq "wor" "$(derive_checked "%40")" "a pane's own pin should not count as held"
for n in 0 2 3 4 5 6 7 8 9; do pin_remove "%4$n"; done
assert_eq "" "$(pins_summary)" "the derivation fixtures should leave the store empty"

# ── Pin, rename, unpin ────────────────────────────────────────────
pin_set "%12" "bug"
pin_set "%14" "rfc"
assert_eq "bug=%12 rfc=%14 " "$(pins_summary)" "pins should append in pin order"
assert_eq "bug" "$(pin_tag_for "%12")" "a pinned pane should report its tag"
pin_tag_for "%99" && { echo "Assertion failed: an unpinned pane should report no tag" >&2; exit 1; }

pin_set "%12" "api"
assert_eq "api=%12 rfc=%14 " "$(pins_summary)" "renaming should keep the pin in place"

if pin_set "%14" "api"; then
    echo "Assertion failed: a duplicate tag should be rejected" >&2
    exit 1
fi
assert_eq "api=%12 rfc=%14 " "$(pins_summary)" "a rejected duplicate should leave the store untouched"

pin_remove "%12"
assert_eq "rfc=%14 " "$(pins_summary)" "unpinning should drop just that pin"
pin_remove "%14"
assert_eq "" "$(pins_summary)" "unpinning the last pin should empty the store"

# ── The ctrl-i path, end to end ───────────────────────────────────
apply() {
    "$REPO_DIR/scripts/pin-target.sh" --apply "$@" >/dev/null 2>&1
}

apply "%12" "bug"
assert_eq "bug=%12 " "$(pins_summary)" "--apply with text should pin"

apply "%12" "task"
assert_eq "task=%12 " "$(pins_summary)" "--apply with new text should rename"

: > "$MESSAGE_LOG"
apply "%14" "task"
assert_eq "task=%12 " "$(pins_summary)" "--apply should refuse a tag another pane holds"
grep -q "already taken" "$MESSAGE_LOG" || { echo "Assertion failed: a duplicate should be reported" >&2; exit 1; }

: > "$MESSAGE_LOG"
apply "%14" "far-too-long"
assert_eq "task=%12 " "$(pins_summary)" "--apply should refuse an over-long tag"
grep -q "1-4 characters" "$MESSAGE_LOG" || { echo "Assertion failed: an invalid tag should be reported" >&2; exit 1; }

apply "%12" ""
assert_eq "" "$(pins_summary)" "--apply with no text should unpin"

# ── The prompt itself ─────────────────────────────────────────────
: > "$MESSAGE_LOG"
"$REPO_DIR/scripts/pin-target.sh" "api:%12" "P" >/dev/null 2>&1
grep -q -- "-I wor" "$MESSAGE_LOG" || {
    echo "Assertion failed: the prompt should be prefilled with the derived tag" >&2
    cat "$MESSAGE_LOG" >&2
    exit 1
}

pin_set "%12" "bug"
: > "$MESSAGE_LOG"
"$REPO_DIR/scripts/pin-target.sh" "api:%12" "P" >/dev/null 2>&1
grep -q -- "-I bug" "$MESSAGE_LOG" || {
    echo "Assertion failed: the prompt should be prefilled with an existing tag" >&2
    cat "$MESSAGE_LOG" >&2
    exit 1
}

# A second agent in a window of the same name gets the next free variant.
pin_set "%12" "wor"
: > "$MESSAGE_LOG"
"$REPO_DIR/scripts/pin-target.sh" "api:%14" "P" >/dev/null 2>&1
grep -q -- "-I wor2 " "$MESSAGE_LOG" || {
    echo "Assertion failed: the prompt should be prefilled with a free variant" >&2
    cat "$MESSAGE_LOG" >&2
    exit 1
}

# A pinned row still prefills its own tag, even when that tag is the base.
: > "$MESSAGE_LOG"
"$REPO_DIR/scripts/pin-target.sh" "api:%12" "P" >/dev/null 2>&1
grep -q -- "-I wor " "$MESSAGE_LOG" || {
    echo "Assertion failed: a pinned row should keep its own tag as the prefill" >&2
    cat "$MESSAGE_LOG" >&2
    exit 1
}

# command-prompt replaces the first %% and every %1 in its template with the
# reply, so the pane id goes into the template without its %.
grep -q -- '--apply "12" "%%"' "$MESSAGE_LOG" || {
    echo "Assertion failed: the prompt template should carry the pane id without its %" >&2
    cat "$MESSAGE_LOG" >&2
    exit 1
}
pin_remove "%12"
apply "12" "bug"
assert_eq "bug=%12 " "$(pins_summary)" "--apply should restore the % of a bare pane number"

echo "pin store checks passed"
