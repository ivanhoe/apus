#!/bin/bash
# Deterministic preflight for ExampleApp demo recordings.
# Runs build/deploy, validates MCP availability, and smoke-checks critical tools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build-and-run.sh"
BASE_URL="${APUS_BASE_URL:-http://127.0.0.1:9847}"
MCP_URL="$BASE_URL/mcp"
QUICK_MODE="${1:-}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ Missing dependency: $cmd"
    exit 1
  fi
}

wait_for_200() {
  local url="$1"
  local max_attempts="${2:-30}"
  local attempt
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    local code
    code="$(curl --connect-timeout 2 --max-time 5 -s -o /dev/null -w '%{http_code}' "$url" || true)"
    if [[ "$code" == "200" ]]; then
      echo "✅ Server ready: $url"
      return 0
    fi
    sleep 1
  done
  echo "❌ Timed out waiting for $url"
  return 1
}

mcp_post() {
  local payload="$1"
  curl --connect-timeout 2 --max-time 10 -sS -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

mcp_check_call() {
  local label="$1"
  local payload="$2"

  local response
  response="$(mcp_post "$payload")"

  local is_error
  is_error="$(printf '%s' "$response" | jq -r '.result.isError // false')"
  local text
  text="$(printf '%s' "$response" | jq -r '.result.content[0].text // ""' | tr '\n' ' ')"

  if [[ "$is_error" == "true" ]]; then
    echo "❌ $label failed"
    echo "   ${text:0:220}"
    return 1
  fi

  echo "✅ $label"
  if [[ -n "$text" ]]; then
    echo "   ${text:0:220}"
  fi
}

check_tools_present() {
  local response
  response="$(mcp_post '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')"

  local required_tools=(
    get_diagnostics
    get_logs
    get_view_hierarchy
    get_network_history
    read_project_file
    hot_reload
    execute_action
    ui_interact
  )

  local missing=0
  local tool
  for tool in "${required_tools[@]}"; do
    if ! printf '%s' "$response" | jq -e --arg tool "$tool" '.result.tools[]?.name | select(. == $tool)' >/dev/null; then
      echo "❌ Missing MCP tool: $tool"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    return 1
  fi

  echo "✅ Required MCP tools are available"
}

main() {
  require_cmd curl
  require_cmd jq

  if [[ "$QUICK_MODE" == "--quick" ]]; then
    echo "⚡ Quick mode: skipping compile, deploying existing build"
    "$BUILD_SCRIPT" --deploy
  else
    echo "🔨 Full mode: build + deploy"
    "$BUILD_SCRIPT" --build
    "$BUILD_SCRIPT" --deploy
  fi

  wait_for_200 "$BASE_URL/"
  wait_for_200 "$MCP_URL"

  check_tools_present

  mcp_check_call "execute_action(simulate_crash_log)" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"execute_action","arguments":{"name":"simulate_crash_log"}}}'
  sleep 1
  mcp_check_call "get_logs(count=20)" \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_logs","arguments":{"count":20}}}'
  mcp_check_call "get_diagnostics" \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_diagnostics","arguments":{}}}'
  mcp_check_call "get_view_hierarchy(format=json)" \
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_view_hierarchy","arguments":{"format":"json"}}}'
  mcp_check_call "get_network_history(count=20)" \
    '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_network_history","arguments":{"count":20}}}'
  mcp_check_call "read_project_file(ContentView.swift)" \
    '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_project_file","arguments":{"file_path":"Sources/ContentView.swift","start_line":1,"end_line":20}}}'

  echo
  echo "🎬 Demo preflight passed."
  echo "Next for deterministic network demo:"
  echo "1) In app, tap 'Local 200 (/)' and 'Local 404 (Error)'."
  echo "2) Ask: 'What API calls failed recently?'"
}

main
