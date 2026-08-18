#!/usr/bin/env bash
# GitHub Issues adapter. Requires: gh (authenticated), jq
# Env: none extra
set -euo pipefail

case "${1:-}" in
  fetch)
    gh issue view "$2" --json number,title,body,labels \
      | jq -r '"# [" + (.number|tostring) + "] " + .title + "\n\n" + .body'
    ;;
  comment)
    gh issue comment "$2" --body-file "$3"
    ;;
  open_pr)
    # $2=ticket  $3=branch  $4=body file  $5=base
    gh pr create --head "$3" --base "$5" \
      --title "[agent] #$2" --body-file "$4"
    ;;
  list_ready)
    gh issue list --label "$2" --state open --json number --jq '.[].number'
    ;;
  *) echo "unknown action: ${1:-}" >&2; exit 1 ;;
esac
