#!/usr/bin/env bash
# PreToolUse hook — blocks writes to protected paths.
#
# This is the LAST line of defence. When Claude runs with permissions bypassed,
# the deny-list in settings.json is not consulted; this hook still is. Hooks run
# regardless of permission mode, which is why protection lives here and not only
# in settings.json.
#
# Exit 2 = block the tool call.
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

# ---- 1. Destructive or exfiltrating shell commands -------------------------
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
        *localhost*|*127.0.0.1*) ;;        # local API calls are fine
        *) block "outbound network call ($CMD)" ;;
      esac ;;
    *sudo*)                                block "sudo" ;;
  esac
fi

# ---- 1b. File writes performed via Bash -----------------------------------
# Bash tool calls carry no .tool_input.file_path, so section 3/4 below never sees
# them. Without this, `sed -i`, `cat >`, `tee` etc. bypass every protected path.
# Shell is arbitrary, so this is best-effort; run-ticket.sh performs a definitive
# post-run diff check that cannot be evaded.
if [ -n "$CMD" ]; then
  # Does the command look like it writes to a file at all?
  if printf '%s' "$CMD" | grep -qE '(^|[^>])>>?[[:space:]]*[^ &|]|(^|[[:space:]])(sed[[:space:]]+-i|perl[[:space:]]+-i|tee|truncate|dd[[:space:]]|install[[:space:]]|cp[[:space:]]|mv[[:space:]]|ln[[:space:]]|touch[[:space:]]|chmod[[:space:]]|chown[[:space:]])'; then

    check_protected_token() {
      tok="$1"
      tok="${tok#./}"
      case "$tok" in
        .claude/*|CLAUDE.md|agent.config.json|scripts/hooks/*|.tickets/*/SPEC.md|.holdout/*)
          block "shell command would write to harness file '$tok'" ;;
      esac
      if [ -f "$ROOT/agent.config.json" ]; then
        while IFS= read -r pat; do
          [ -z "$pat" ] && continue
          # shellcheck disable=SC2254
          case "$tok" in
            $pat) block "shell command would write to protected path '$tok' (matches '$pat')" ;;
          esac
        done < <(jq -r '.policy.protected_paths[]?' "$ROOT/agent.config.json" 2>/dev/null)
      fi
    }

    # Inspect every whitespace-separated token that looks like a path.
    for tok in $CMD; do
      case "$tok" in
        -*|'>'|'>>'|'|'|'&&') continue ;;
      esac
      case "$tok" in
        */*|*.*) check_protected_token "${tok#*>}" ;;
      esac
    done
  fi

  # Interpreters can write anything; deny inline scripts that name a protected path.
  case "$CMD" in
    *python*-c*|*python3*-c*|*node*-e*|*ruby*-e*|*perl*-e*)
      for tok in $CMD; do
        case "$tok" in
          */*|*.*) check_protected_token 2>/dev/null "$tok" || true ;;
        esac
      done ;;
  esac
fi

[ -z "$FILE" ] && exit 0

# ---- 2. Normalise to a repo-relative path ----------------------------------
case "$FILE" in
  /*) REL="${FILE#"$ROOT"/}" ;;
   *) REL="$FILE" ;;
esac

# ---- 3. Harness self-protection --------------------------------------------
# The agent must never edit its own instructions, config, hooks, or the spec.
case "$REL" in
  .claude/*|CLAUDE.md|agent.config.json|scripts/hooks/*|.tickets/*/SPEC.md|.holdout/*)
    block "'$REL' is part of the agent harness and cannot be modified" ;;
esac

# ---- 4. Project protected paths from agent.config.json ---------------------
CONFIG="$ROOT/agent.config.json"
[ -f "$CONFIG" ] || exit 0

while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  # shellcheck disable=SC2254
  case "$REL" in
    $pattern) block "'$REL' matches protected path '$pattern' in agent.config.json" ;;
  esac
done < <(jq -r '.policy.protected_paths[]?' "$CONFIG" 2>/dev/null)

exit 0
