#!/bin/sh
set -eu

version=0.0.0
if [ -e "$1/.git" ]; then
    version=$(
        # Swift Build may point DEVELOPER_DIR at the Swift toolchain instead of Xcode.
        unset DEVELOPER_DIR
        git --no-optional-locks -C "$1" describe --tags --dirty 2>/dev/null
    ) || version=0.0.0
fi
version=$(printf '%s' "$version" | sed 's/\\/\\\\/g; s/"/\\"/g')
source=$(printf 'enum BuildVersion {\n    static let value = "%s"\n}\n' "$version")
output="$2/BuildVersion.swift"
mkdir -p "$2"
if [ ! -f "$output" ] || [ "$(cat "$output")" != "$source" ]; then
    printf '%s\n' "$source" > "$output"
fi
