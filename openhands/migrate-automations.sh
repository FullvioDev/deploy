#!/usr/bin/env bash
# Bulk export OpenHands automations from one Agent Canvas and import them into another.
#
# Usage:
#   ./migrate-automations.sh export   # dump every automation on SRC into ./export/<slug>.automation.json
#   ./migrate-automations.sh transform  # copy export/ -> import/ with curipack -> curipet renames applied
#   ./migrate-automations.sh import   # POST every file in ./import/ to DST (created disabled)
#
# Required env (set on the machine you run this from, e.g. your laptop or srv4):
#   SRC_HOST=http://srv4-noble-app02:8001   SRC_KEY=<session/automation API key on srv4>
#   DST_HOST=http://srv2-noble-usr01:8001   DST_KEY=<session/automation API key on srv2>
# Optional:
#   FROM=curipack TO=curipet   (text replacements applied in transform; also REPO_FROM / REPO_TO for the git repo path)
set -euo pipefail

cmd="${1:-}"
FROM="${FROM:-curipack}"
TO="${TO:-curipet}"
REPO_FROM="${REPO_FROM:-$FROM}"
REPO_TO="${REPO_TO:-$TO}"
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl; need jq

api() { # api <host> <key> <method> <path> [json-body]
  local host="$1" key="$2" method="$3" path="$4" body="${5:-}"
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "$host$path" -H "X-Session-API-Key: $key" -H "Content-Type: application/json" -d "$body"
  else
    curl -fsS -X "$method" "$host$path" -H "X-Session-API-Key: $key"
  fi
}

case "$cmd" in
  export)
    : "${SRC_HOST:?}" "${SRC_KEY:?}"
    mkdir -p export
    # list may be a bare array or {items:[...]} / {automations:[...]}
    ids=$(api "$SRC_HOST" "$SRC_KEY" GET "/api/automation/v1?limit=500" \
      | jq -r 'if type=="array" then . else (.items // .automations // .results) end | .[].id')
    n=0
    for id in $ids; do
      a=$(api "$SRC_HOST" "$SRC_KEY" GET "/api/automation/v1/$id")
      slug=$(echo "$a" | jq -r '.name' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')
      # Wrap in the same versioned envelope the UI export uses; keep raw too in case fields live under preset_metadata.
      echo "$a" | jq '{version:1, kind:"automation", spec:{
          name:.name, prompt:(.prompt // .preset_metadata.prompt), trigger:.trigger, enabled:.enabled,
          timeout:.timeout,
          repos:(.repos // .repository // .preset_metadata.repos // .preset_metadata.repository),
          plugins:(.plugins // .preset_metadata.plugins), model:(.model // .llm_profile),
          notification:.notification }, raw:.}' > "export/$slug.automation.json"
      n=$((n+1)); echo "exported $slug"
    done
    echo "done: $n automations in ./export"
    ;;
  transform)
    mkdir -p import
    for f in export/*.automation.json; do
      out="import/$(basename "$f" | sed "s/$FROM/$TO/g")"
      sed -e "s/$REPO_FROM/$REPO_TO/g" -e "s/$FROM/$TO/g" -e "s/${FROM^}/${TO^}/g" -e "s/${FROM^^}/${TO^^}/g" "$f" \
        | jq '.spec.enabled=false' > "$out"
      echo "wrote $out"
    done
    echo "review ./import before importing (prompts, repos, model names)"
    ;;
  import)
    : "${DST_HOST:?}" "${DST_KEY:?}"
    for f in import/*.automation.json; do
      spec=$(jq '.spec' "$f")
      if [ "$(echo "$spec" | jq '.plugins // [] | length')" -gt 0 ]; then path=/api/automation/v1/preset/plugin; else path=/api/automation/v1/preset/prompt; fi
      body=$(echo "$spec" | jq 'del(.model, .notification, .enabled) | with_entries(select(.value != null))')
      id=$(api "$DST_HOST" "$DST_KEY" POST "$path" "$body" | jq -r '.id')
      api "$DST_HOST" "$DST_KEY" PATCH "/api/automation/v1/$id" '{"enabled": false}' >/dev/null
      echo "imported $(basename "$f") -> $id (disabled)"
    done
    ;;
  *) echo "usage: $0 export|transform|import" >&2; exit 1 ;;
esac
