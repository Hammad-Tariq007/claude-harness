#!/usr/bin/env bash
# Jira adapter. Requires: curl, jq, gh (for PR creation only)
# Env: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN
set -euo pipefail
: "${JIRA_BASE_URL:?set JIRA_BASE_URL}" "${JIRA_EMAIL:?}" "${JIRA_API_TOKEN:?}"
AUTH="-u ${JIRA_EMAIL}:${JIRA_API_TOKEN}"

case "${1:-}" in
  fetch)
    # shellcheck disable=SC2086
    curl -sS $AUTH -H "Accept: application/json" \
      "$JIRA_BASE_URL/rest/api/3/issue/$2?fields=summary,description" \
      | jq -r '"# [" + .key + "] " + .fields.summary + "\n\n" +
               ( [ .fields.description.content[]?.content[]?.text? ] | map(select(.)) | join("\n") )'
    ;;
  comment)
    BODY=$(jq -Rs '{body:{type:"doc",version:1,content:[{type:"paragraph",content:[{type:"text",text:.}]}]}}' < "$3")
    # shellcheck disable=SC2086
    curl -sS $AUTH -X POST -H "Content-Type: application/json" \
      "$JIRA_BASE_URL/rest/api/3/issue/$2/comment" -d "$BODY" > /dev/null
    ;;
  open_pr)
    gh pr create --head "$3" --base "$5" --title "[agent] $2" --body-file "$4"
    ;;
  list_ready)
    # shellcheck disable=SC2086
    curl -sS $AUTH -G "$JIRA_BASE_URL/rest/api/3/search" \
      --data-urlencode "jql=labels = \"$2\" AND statusCategory != Done" \
      | jq -r '.issues[].key'
    ;;
  *) echo "unknown action: ${1:-}" >&2; exit 1 ;;
esac
