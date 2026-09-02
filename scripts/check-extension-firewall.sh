#!/bin/bash
# scripts/check-extension-firewall.sh — the IMPORT FIREWALL gate (extension
# architecture, decision doc 496a85fe). The real enforcement is SPM target
# dependencies (the compiler refuses imports a target does not depend on);
# this script is the CI backstop that makes an eroding diff LOUD:
#
#   1. MemtermExtensionKit stays PURE: its sources import only Foundation and
#      AppKit — never MemtermCore, SwiftTerm, CProcShim, the app, SQLite, or
#      any networking module.
#   2. Extension targets (Sources/MemtermClaudeBrowser, Sources/MemtermTimeline,
#      Sources/MemtermExt*) import ONLY MemtermExtensionKit + AppKit +
#      Foundation. None exist yet — the check enumerates what it finds and
#      passes vacuously until they land.
#   3. In Package.swift, each extension target's dependency list is exactly
#      ["MemtermExtensionKit"].
#   4. No extension source (or kit source) touches URLSession/Network — the
#      network-abstinence doctrine's grep-visible half.
#
# Sentinel protocol (TESTING.md): FIREWALL-PASS on success; any violation
# prints FIREWALL-FAIL with the offending file:line and exits 1.
set -u
cd "$(dirname "$0")/.."

FAIL=0

# Extracts the module of every import line in a directory of Swift sources,
# tolerant of `@testable import X` and `import class X.Y` forms.
list_imports() {  # list_imports <dir>  → lines of  path:line:Module
    grep -RnE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]' "$1" \
        --include='*.swift' 2>/dev/null \
        | awk -F: '{
            code = $3; for (i = 4; i <= NF; i++) code = code ":" $i;
            sub(/^[ \t]*(@testable[ \t]+)?import[ \t]+/, "", code);
            sub(/^(class|struct|enum|protocol|func|var|let|typealias)[ \t]+/, "", code);
            sub(/[ \t].*$/, "", code);
            sub(/\..*$/, "", code);
            print $1 ":" $2 ":" code
        }'
}

check_dir() {  # check_dir <dir> <allowed-regex> <label>
    local dir="$1" allowed="$2" label="$3"
    local bad
    bad="$(list_imports "$dir" | awk -F: -v ok="^($allowed)$" '$NF !~ ok')"
    if [ -n "$bad" ]; then
        echo "FIREWALL-FAIL $label imports outside its allowlist ($allowed):"
        echo "$bad" | sed 's/^/    /'
        FAIL=1
    fi
}

# -- 1. Kit purity -----------------------------------------------------------
check_dir "Sources/MemtermExtensionKit" "Foundation|AppKit" "kit"

# -- 2. Extension targets ----------------------------------------------------
EXT_DIRS=""
for dir in Sources/MemtermClaudeBrowser Sources/MemtermTimeline Sources/MemtermExt*; do
    [ -d "$dir" ] || continue
    case "$dir" in Sources/MemtermExtensionKit) continue ;; esac
    EXT_DIRS="$EXT_DIRS $dir"
    check_dir "$dir" "MemtermExtensionKit|AppKit|Foundation" "extension-target $dir"
done
EXT_COUNT=$(echo "$EXT_DIRS" | wc -w | tr -d ' ')

# -- 3. Package.swift dependency lists for extension targets -----------------
for dir in $EXT_DIRS; do
    name="$(basename "$dir")"
    # The target stanza, up to its closing paren: its dependencies must be
    # exactly the kit (no SwiftTerm product lines, no core, no CProcShim).
    stanza="$(awk "/name: \"$name\"/,/^        \),?$/" Package.swift)"
    if [ -z "$stanza" ]; then
        echo "FIREWALL-FAIL $name has sources but no Package.swift target"
        FAIL=1
    elif echo "$stanza" | grep -qE 'MemtermCore|CProcShim|SwiftTerm|"memterm"'; then
        echo "FIREWALL-FAIL $name's Package.swift dependencies reach past MemtermExtensionKit:"
        echo "$stanza" | grep -nE 'MemtermCore|CProcShim|SwiftTerm|"memterm"' | sed 's/^/    /'
        FAIL=1
    fi
done

# -- 4. Network abstinence (grep-visible half) -------------------------------
NET_BAD="$(grep -RnE 'URLSession|NWConnection|NWListener|CFSocket|getaddrinfo' \
    Sources/MemtermExtensionKit $EXT_DIRS --include='*.swift' 2>/dev/null || true)"
if [ -n "$NET_BAD" ]; then
    echo "FIREWALL-FAIL networking symbol in kit/extension sources:"
    echo "$NET_BAD" | sed 's/^/    /'
    FAIL=1
fi

if [ "$FAIL" = "0" ]; then
    echo "FIREWALL-PASS kit=pure extension_targets=$EXT_COUNT network=abstinent"
    exit 0
fi
exit 1
