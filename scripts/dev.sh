#!/bin/bash
# Dev run. Debug only: release builds self-register a login item.
set -euo pipefail

cd "$(dirname "$0")/.."

args=("$@")
for i in "${!args[@]}"; do
    case "${args[$i]}" in
        -c|--configuration)
            case "${args[$((i + 1))]:-}" in
                release)
                    echo "dev.sh is debug-only: release builds self-register a login item." >&2
                    echo "Use ./scripts/package.sh local instead." >&2
                    exit 2
                    ;;
            esac
            ;;
        --configuration=release)
            echo "dev.sh is debug-only: release builds self-register a login item." >&2
            echo "Use ./scripts/package.sh local instead." >&2
            exit 2
            ;;
    esac
done

# Flags before the target: after it, swift run passes them to the app.
exec swift run "$@" --build-system native QuickTodo
