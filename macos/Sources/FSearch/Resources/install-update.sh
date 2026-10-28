#!/bin/bash
set -euo pipefail
OLD_PID="$1"
TARGET="$2"
WORK_DIR="$3"
STAGED="$WORK_DIR/FSearch.app"
BACKUP="$WORK_DIR/FSearch.previous.app"
RESULT="$WORK_DIR/result"

# The running application has validated this sibling bundle before starting us.
case "$OLD_PID" in ''|*[!0-9]*) exit 1 ;; esac
case "$WORK_DIR" in "$(dirname "$TARGET")"/.FSearch-update-*) ;; *) exit 1 ;; esac
[ -d "$STAGED" ] && [ -d "$TARGET" ] && [ ! -e "$BACKUP" ]

for ((attempt = 0; attempt < 120; attempt++)); do
    if ! kill -0 "$OLD_PID" 2>/dev/null; then break; fi
    sleep 1
done
if kill -0 "$OLD_PID" 2>/dev/null; then
    printf 'failed\n' > "$RESULT"
    exit 1
fi

restore_if_interrupted() {
    local status=$?
    if [ "$status" -ne 0 ] && [ ! -e "$TARGET" ] && [ -d "$BACKUP" ]; then
        mv "$BACKUP" "$TARGET" || return "$status"
        printf 'failed\n' > "$RESULT"
        /usr/bin/open "$TARGET" || true
    fi
    return "$status"
}
trap restore_if_interrupted EXIT
trap 'exit 1' HUP INT TERM

if ! mv "$TARGET" "$BACKUP"; then
    printf 'failed\n' > "$RESULT"
    /usr/bin/open "$TARGET" || true
    exit 1
fi
if ! mv "$STAGED" "$TARGET"; then
    mv "$BACKUP" "$TARGET"
    printf 'failed\n' > "$RESULT"
    /usr/bin/open "$TARGET" || true
    exit 1
fi

printf 'success\n' > "$RESULT"
if ! /usr/bin/open "$TARGET"; then
    # Retain both bundles if launching fails, and restore the previous version.
    mv "$TARGET" "$STAGED"
    mv "$BACKUP" "$TARGET"
    printf 'failed\n' > "$RESULT"
    /usr/bin/open "$TARGET" || true
    exit 1
fi
