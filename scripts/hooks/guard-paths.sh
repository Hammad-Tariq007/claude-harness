#!/usr/bin/env bash
# PreToolUse hook — blocks writes to protected paths and dangerous commands.
# This is the ONLY enforcement once permission prompts are off: hooks run in
# every permission mode, the settings.json deny-list does not.
# Exit 2 = block.
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
INPUT=$(cat)

FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
CMD=$(printf '%s'  "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

block() {
  echo "BLOCKED: $1" >&2
  echo "Do not attempt a workaround. Write REPORT.md explaining why this ticket cannot proceed, then stop." >&2
  exit 2
}

if [ -n "$CMD" ]; then
  case "$CMD" in
    *"git push --force"*|*"git push -f"*)  block "force push" ;;
    *"git reset --hard"*)                  block "hard reset" ;;
    *"git rebase"*)                        block "rebase (history rewrite)" ;;
    *"git branch -D"*)                     block "branch deletion" ;;
    *"rm -rf /"*|*"rm -rf ~"*)             block "recursive delete of a root path" ;;
    *"chmod 777"*)                         block "world-writable chmod" ;;
    *curl*|*wget*)
      case "$CMD" in
        *localhost*|*127.0.0.1*) ;;
        *) block "outbound network call ($CMD)" ;;
      esac ;;
    *sudo*)                                block "sudo" ;;
  esac
fi

[ -z "$FILE" ] && exit 0

case "$FILE" in
  /*) REL="${FILE#"$ROOT"/}" ;;
   *) REL="$FILE" ;;
esac

case "$REL" in
  .claude/*|CLAUDE.md|agent.config.json|scripts/hooks/*|.tickets/*/SPEC.md|.holdout/*)
    block "'$REL' is part of the agent harness and cannot be modified" ;;
esac

CONFIG="$ROOT/agent.config.json"
[ -f "$CONFIG" ] || exit 0

while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  case "$REL" in
    $pattern) block "'$REL' matches protected path '$pattern' in agent.config.json" ;;
  esac
done < <(jq -r '.policy.protected_paths[]?' "$CONFIG" 2>/dev/null)

exit 0
