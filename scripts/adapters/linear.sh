#!/usr/bin/env bash
# Linear adapter. Requires: curl, jq, gh (for PR creation only)
# Env: LINEAR_API_KEY
set -euo pipefail
: "${LINEAR_API_KEY:?set LINEAR_API_KEY}"
API="https://api.linear.app/graphql"

gql() { curl -sS -X POST "$API" -H "Authorization: $LINEAR_API_KEY" \
        -H "Content-Type: application/json" -d "$1"; }

case "${1:-}" in
  fetch)
    Q=$(jq -n --arg id "$2" '{query:"query($id:String!){issue(id:$id){identifier title description}}",variables:{id:$id}}')
    gql "$Q" | jq -r '"# [" + .data.issue.identifier + "] " + .data.issue.title + "\n\n" + (.data.issue.description // "")'
    ;;
  comment)
    BODY=$(cat "$3")
    Q=$(jq -n --arg id "$2" --arg b "$BODY" '{query:"mutation($id:String!,$b:String!){commentCreate(input:{issueId:$id,body:$b}){success}}",variables:{id:$id,b:$b}}')
    gql "$Q" > /dev/null
    ;;
  open_pr)
    gh pr create --head "$3" --base "$5" --title "[agent] $2" --body-file "$4"
    ;;
  list_ready)
    Q=$(jq -n --arg l "$2" '{query:"query($l:String!){issues(filter:{labels:{name:{eq:$l}},state:{type:{neq:\"completed\"}}}){nodes{identifier}}}",variables:{l:$l}}')
    gql "$Q" | jq -r '.data.issues.nodes[].identifier'
    ;;
  *) echo "unknown action: ${1:-}" >&2; exit 1 ;;
esac
