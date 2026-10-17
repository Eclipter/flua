#!/bin/sh
set -eu
FS_EXECUTABLE=${1:?Pass the built extension executable}
FS_LOAD_COMMANDS=$(xcrun otool -l "$FS_EXECUTABLE")
FS_ENTRY_OFFSET=$(printf '%s\n' "$FS_LOAD_COMMANDS" | awk '/cmd LC_MAIN/ { main = 1 } main && /entryoff/ { print $2; exit }')
FS_TEXT_ADDRESS=$(printf '%s\n' "$FS_LOAD_COMMANDS" | awk '$1 == "segname" && $2 == "__TEXT" { text = 1 } text && $1 == "vmaddr" { print $2; exit }')
test -n "$FS_ENTRY_OFFSET"
test -n "$FS_TEXT_ADDRESS"
FS_ENTRY_ADDRESS=$(printf '0x%x' "$((FS_TEXT_ADDRESS + FS_ENTRY_OFFSET))")
if ! xcrun dyld_info -lookup_va "$FS_ENTRY_ADDRESS" "$FS_EXECUTABLE" |
    awk '$2 == "_NSExtensionMain" { found = 1 } END { exit !found }'; then
    echo 'Extension entrypoint must be _NSExtensionMain' >&2
    exit 1
fi
# The bootstrap still needs the Swift entrypoint; dead stripping it breaks startup.
if ! xcrun nm -g "$FS_EXECUTABLE" |
    awk '$2 == "T" && $3 == "_main" { found = 1 } END { exit !found }'; then
    echo 'Extension must retain Swift main' >&2
    exit 1
fi
echo 'Extension bootstrap and retained Swift main: OK'
