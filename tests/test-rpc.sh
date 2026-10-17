#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-scripts RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh <sharedfolder>
#
# Exercises all Scripts RPC methods: settings CRUD, script CRUD, doCheck/
# doRun background execution, importChanges/importExistingOne/
# importExistingFolder, git integration (init/diff), scheduled job CRUD,
# doJob execution, and the exec log list/view/delete cycle. Also covers
# input validation (script names, cron fields, log paths), argument quoting,
# cron % escaping and viewing non-text run logs.
#
# Prerequisites:
#   <sharedfolder> — name or UUID of an existing OMV shared folder to use as
#                    script storage for the duration of this run
#
# Find shared folders with:
#   omv-rpc -u admin ShareMgmt getList \
#     '{"start":0,"limit":25,"sortfield":null,"sortdir":null}'
#
# WARNING: This script temporarily points the plugin's "sharedfolderref"
# setting at <sharedfolder> and writes/deletes test script files there
# (all named omvtest_*). Original settings are restored on exit. If the
# shared folder has no ".git" directory yet, a git repo is initialized in
# it as part of the git-integration tests (and left in place afterwards);
# if it already has one, the destructive "git init" step is skipped so any
# existing history is untouched. Run on a test system or during a
# maintenance window.

set -uo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
    echo "Usage: $(basename "$0") <sharedfolder>" >&2
    echo "" >&2
    echo "  <sharedfolder>  name or UUID of an OMV shared folder" >&2
    echo "" >&2
    echo "  Find shared folders:" >&2
    echo "    omv-rpc -u admin ShareMgmt getList" \
         "'{\"start\":0,\"limit\":25,\"sortfield\":null,\"sortdir\":null}'" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root." >&2
    exit 1
fi

SF_REF="$1"

# ---------------------------------------------------------------------------
# Colours / counters  (display → stderr; $() captures only JSON)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0
declare -a FAILED_TESTS=()

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() { echo -e "  ${GREEN}PASS${NC}  $1" >&2; ((PASS++)) || true; }
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}
_skip() { echo -e "  ${YELLOW}SKIP${NC}  $1${2:+  ($2)}" >&2; ((SKIP++)) || true; }

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------

# Last successful RPC output. Never call assert_rpc inside a $() subshell —
# that would prevent PASS/FAIL counter updates from propagating back.
RPC_OUT=""
# Last bg task output (set by assert_rpc_bg).
BG_OUT=""

rpc() {
    local svc=$1 method=$2 params=${3:-'{}'}
    omv-rpc -u admin "$svc" "$method" "$params"
}

# Assert RPC succeeds. Optional 5th arg: grep pattern that must appear.
# Result JSON is available in $RPC_OUT after the call.
assert_rpc() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    RPC_OUT=""
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "$(echo "$out" | tail -3)"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in: ${out:0:300}"
        return 1
    fi
    _pass "$desc"
    RPC_OUT="$out"
    return 0
}

# Assert RPC fails (non-zero exit or output contains Exception).
assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded: ${out:0:200}"
        return 1
    fi
    _pass "$desc"
    return 0
}

# Call a bg method (doRun/doCheck/doJob/doGit/viewLog), wait for completion,
# report result. Optional 5th arg: grep pattern that must appear in output.
# Task output is always available in $BG_OUT after the call.
assert_rpc_bg() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local filename ec=0
    BG_OUT=""
    filename=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "Failed to start bg task: ${filename:0:200}"
        return 1
    fi
    filename=$(echo "$filename" | tr -d '"')

    # Poll with getOutput (not isRunning): isRunning deletes the status file
    # on completion, which would make a subsequent getOutput call fail.
    local timeout=60 elapsed=0 poll_ec=0 poll_out
    while [ $elapsed -lt $timeout ]; do
        poll_out=$(omv-rpc -u admin "Exec" "getOutput" \
            "{\"filename\":\"$filename\",\"pos\":0}" 2>&1)
        poll_ec=$?
        [ $poll_ec -ne 0 ] && break
        echo "$poll_out" | grep -q '"running":true\|"running": true' || break
        sleep 1; ((elapsed += 1)) || true
    done
    if [ $elapsed -ge $timeout ]; then
        _fail "$desc" "Bg task timed out after ${timeout}s"
        return 1
    fi
    if [ $poll_ec -ne 0 ]; then
        local err
        err=$(echo "$poll_out" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); e=d.get('error') or {}; print(e.get('message', str(d))[:300])" \
            2>/dev/null || echo "${poll_out:0:200}")
        _fail "$desc" "$err"
        return 1
    fi
    local content
    content=$(echo "$poll_out" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('output',''))" \
        2>/dev/null || echo "")
    BG_OUT="$content"
    if [ -n "$pattern" ] && ! echo "$content" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in output: ${content:0:300}"
        return 1
    fi
    _pass "$desc"
    return 0
}

# Assert that a string contains a fixed (non-regex) substring.
assert_contains() {
    local desc=$1 haystack=$2 needle=$3
    if grep -qF -- "$needle" <<<"$haystack"; then
        _pass "$desc"
    else
        _fail "$desc" "'$needle' not found in: ${haystack:0:300}"
    fi
}

# Extract a JSON field value.
json_get() { echo "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$2',''))" 2>/dev/null; }
json_uuid() { json_get "$1" "uuid"; }

# Recover a UUID from a paginated list RPC by matching on a field value.
recover_uuid_from_list() {
    local svc=$1 method=$2 field=$3 value=$4
    omv-rpc -u admin "$svc" "$method" \
        '{"start":0,"limit":100,"sortfield":"name","sortdir":"ASC"}' 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('$field') == '$value':
        print(r['uuid'])
        break
" 2>/dev/null || echo ""
}

# Delete a named test object if it exists in a list RPC response.
purge_by_name() {
    local svc=$1 list_method=$2 list_params=$3 delete_method=$4 name=$5 field=${6:-name}
    local existing
    existing=$(omv-rpc -u admin "$svc" "$list_method" "$list_params" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('$field') == '$name':
        print(r['uuid'])
" 2>/dev/null || echo "")
    if [ -n "$existing" ]; then
        info "Pre-cleanup: removing leftover '$name' ($existing)"
        omv-rpc -u admin "$svc" "$delete_method" "{\"uuid\":\"$existing\"}" >/dev/null 2>&1 || true
    fi
}

# Create a script via setScript and track it for cleanup. Sets NEW_UUID.
create_script() {
    local name=$1 ext=$2 body=$3 testargs=${4:-}
    local params
    params=$(NAME="$name" EXT="$ext" BODY="$body" ARGS="$testargs" python3 -c "
import json, os
print(json.dumps({'name': os.environ['NAME'], 'ext': os.environ['EXT'],
                  'body': os.environ['BODY'], 'testargs': os.environ['ARGS']}))
")
    NEW_UUID=""
    assert_rpc "setScript (create $name.$ext)" "Scripts" "setScript" "$params" || return 1
    NEW_UUID=$(json_uuid "$RPC_OUT")
    [ -z "$NEW_UUID" ] && NEW_UUID=$(recover_uuid_from_list "Scripts" "getScriptList" "name" "$name")
    [ -n "$NEW_UUID" ] && EXTRA_UUIDS+=("$NEW_UUID")
    return 0
}

# Find the newest exec log row for a script file name; prints JSON or "".
find_log_row() {
    omv-rpc -u admin "Scripts" "getLogList" \
        '{"start":0,"limit":100,"sortfield":"start","sortdir":"DESC"}' 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
match = next((r for r in rows if r.get('script') == '$1'), None)
print(json.dumps(match) if match else '')
" 2>/dev/null || echo ""
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
SCRIPT_UUID=""
SCRIPT2_UUID=""
IMPORT_ONE_UUID=""
declare -a IMPORT_FOLDER_UUIDS=()
declare -a EXTRA_UUIDS=()
JOB_UUID=""
JOB2_UUID=""
CHECK_MARKER=""
ORIG_SETTINGS=""
IMPORT_TMPDIR=""
LOG_ID=""
LOG_FILE=""
LOG_RUNLOG=""

LIST_PARAMS='{"start":0,"limit":100,"sortfield":"name","sortdir":"ASC"}'
OMV_NEW_UUID=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit
# ---------------------------------------------------------------------------
cleanup() {
    section "Cleanup"

    if [ -n "$JOB_UUID" ]; then
        info "Deleting test job $JOB_UUID"
        omv-rpc -u admin "Scripts" "deleteJob" "{\"uuid\":\"$JOB_UUID\"}" >/dev/null 2>&1 || true
    fi
    if [ -n "$JOB2_UUID" ]; then
        info "Deleting test job $JOB2_UUID"
        omv-rpc -u admin "Scripts" "deleteJob" "{\"uuid\":\"$JOB2_UUID\"}" >/dev/null 2>&1 || true
    fi
    [ -n "$CHECK_MARKER" ] && rm -f "$CHECK_MARKER"
    for uuid in "$SCRIPT_UUID" "$SCRIPT2_UUID" "$IMPORT_ONE_UUID" "${IMPORT_FOLDER_UUIDS[@]}" "${EXTRA_UUIDS[@]}"; do
        if [ -n "$uuid" ]; then
            info "Deleting test script $uuid"
            omv-rpc -u admin "Scripts" "deleteScript" "{\"uuid\":\"$uuid\"}" >/dev/null 2>&1 || true
        fi
    done
    if [ -n "$IMPORT_TMPDIR" ] && [ -d "$IMPORT_TMPDIR" ]; then
        info "Removing temp import dir $IMPORT_TMPDIR"
        rm -rf "$IMPORT_TMPDIR" 2>/dev/null || true
    fi

    if [ -n "$ORIG_SETTINGS" ]; then
        info "Restoring original Scripts settings"
        omv-rpc -u admin "Scripts" "set" "$ORIG_SETTINGS" >/dev/null 2>&1 || true
    fi

    echo "" >&2
    info "Deploying pending config changes asynchronously (clears web UI banner)"
    nohup omv-salt deploy run --quiet --append-dirty >/dev/null 2>&1 &
}
trap cleanup EXIT

# ===========================================================================
section "Pre-flight"
# ===========================================================================

for cmd in omv-rpc python3; do
    if command -v "$cmd" &>/dev/null; then
        _pass "command available: $cmd"
    else
        echo -e "\n${RED}Required command '$cmd' not found — aborting.${NC}" >&2
        exit 1
    fi
done

if command -v omv-salt &>/dev/null; then
    _pass "command available: omv-salt"
else
    info "omv-salt not found — deploy-dependent tests may fail"
fi

if ! omv-rpc -u admin "Config" "isDirty" '{}' &>/dev/null; then
    echo -e "\n${RED}omv-rpc not functional — aborting.${NC}" >&2
    exit 1
fi
_pass "omv-rpc functional"

# Resolve shared folder — accept either a UUID or a name.
if echo "$SF_REF" | grep -qE \
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    SF_JSON=$(omv-rpc -u admin "ShareMgmt" "get" "{\"uuid\":\"$SF_REF\"}" 2>&1) \
        && SF_EC=0 || SF_EC=$?
    if [ $SF_EC -ne 0 ]; then
        echo -e "\n${RED}Shared folder UUID $SF_REF not found — aborting.${NC}" >&2
        exit 1
    fi
else
    SF_LIST=$(omv-rpc -u admin "ShareMgmt" "getList" \
        '{"start":0,"limit":null,"sortfield":null,"sortdir":null}' 2>/dev/null || echo '{"data":[]}')
    RESOLVED=$(echo "$SF_LIST" | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
for r in rows:
    if r.get('name') == '$SF_REF':
        print(r['uuid']); break
" 2>/dev/null || echo "")
    if [ -z "$RESOLVED" ]; then
        echo -e "\n${RED}No shared folder named '$SF_REF' found — aborting.${NC}" >&2
        exit 1
    fi
    SF_REF="$RESOLVED"
    SF_JSON=$(omv-rpc -u admin "ShareMgmt" "get" "{\"uuid\":\"$SF_REF\"}" 2>&1)
fi
SF_NAME=$(json_get "$SF_JSON" "name")
_pass "shared folder found: $SF_NAME ($SF_REF)"

SFPATH=$(omv-rpc -u admin "ShareMgmt" "getPath" "{\"uuid\":\"$SF_REF\"}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null)
SFPATH="${SFPATH%/}"
if [ -n "$SFPATH" ] && [ -d "$SFPATH" ]; then
    _pass "resolved shared folder path: $SFPATH"
else
    echo -e "\n${RED}Could not resolve filesystem path for shared folder — aborting.${NC}" >&2
    exit 1
fi

section "Configuration"
info "Shared folder : $SF_NAME  ($SF_REF)"
info "Path          : $SFPATH"

# ===========================================================================
section "Pre-cleanup"
# ===========================================================================
purge_by_name "Scripts" "getScriptList" "$LIST_PARAMS" "deleteScript" "omvtest_script"
purge_by_name "Scripts" "getScriptList" "$LIST_PARAMS" "deleteScript" "omvtest_script_delete"
purge_by_name "Scripts" "getScriptList" "$LIST_PARAMS" "deleteScript" "omvtest_import_one"
purge_by_name "Scripts" "getScriptList" "$LIST_PARAMS" "deleteScript" "omvtest_import_sh"
purge_by_name "Scripts" "getScriptList" "$LIST_PARAMS" "deleteScript" "omvtest_import_py"
purge_by_name "Scripts" "getScriptList" "$LIST_PARAMS" "deleteScript" "omvtest_import_php"
purge_by_name "Scripts" "getScriptList" "$LIST_PARAMS" "deleteScript" "omvtest_import_json"
purge_by_name "Scripts" "getScriptList" "$LIST_PARAMS" "deleteScript" "omvtest_args"
purge_by_name "Scripts" "getScriptList" "$LIST_PARAMS" "deleteScript" "omvtest_check_conf"
purge_by_name "Scripts" "getScriptList" "$LIST_PARAMS" "deleteScript" "omvtest_json"
JOB_LIST_PARAMS='{"start":0,"limit":100,"sortfield":"execution","sortdir":"ASC"}'
purge_by_name "Scripts" "getJobList" "$JOB_LIST_PARAMS" "deleteJob" "omvtest_job" "comment"
purge_by_name "Scripts" "getJobList" "$JOB_LIST_PARAMS" "deleteJob" "omvtest_cronpct 50%" "comment"

# ===========================================================================
section "Settings"
# ===========================================================================

assert_rpc "get settings" "Scripts" "get" '{}' '"sharedfolderref"'
ORIG_SETTINGS="$RPC_OUT"

SET_PARAMS=$(echo "$ORIG_SETTINGS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['sharedfolderref'] = '$SF_REF'
print(json.dumps(d))
")
assert_rpc "set settings (point sharedfolderref at test folder)" "Scripts" "set" "$SET_PARAMS" \
    "$SF_REF"

assert_rpc "get settings reflects sharedfolderref" "Scripts" "get" '{}' "$SF_REF"

assert_rpc_fails "set settings (missing required field)" "Scripts" "set" '{"sharedfolderref":""}'

# ===========================================================================
section "Git integration — init (skipped if a repo already exists)"
# ===========================================================================

if [ -d "$SFPATH/.git" ]; then
    _skip "doGit init" "a .git repo already exists in $SFPATH — not touching existing history"
else
    assert_rpc_bg "doGit init" "Scripts" "doGit" '{"uuid":"","command":"init"}' "Done"
    if [ -d "$SFPATH/.git" ]; then
        _pass "doGit init created .git directory"
    else
        _fail "doGit init created .git directory" ".git missing after init"
    fi
fi

# ===========================================================================
section "Scripts — CRUD"
# ===========================================================================

assert_rpc "getScriptList" "Scripts" "getScriptList" "$LIST_PARAMS" '"total"'
assert_rpc "enumerateScripts" "Scripts" "enumerateScripts" '{}'

CREATE_BODY='#!/bin/bash
echo "hello from omvtest"
exit 0'
CREATE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'name': 'omvtest_script',
    'ext': 'sh',
    'body': '''$CREATE_BODY''',
    'testargs': ''
}))
")
assert_rpc "setScript (create)" "Scripts" "setScript" "$CREATE_PARAMS"
SCRIPT_UUID=$(json_uuid "$RPC_OUT")
if [ -z "$SCRIPT_UUID" ]; then
    SCRIPT_UUID=$(recover_uuid_from_list "Scripts" "getScriptList" "name" "omvtest_script")
    [ -n "$SCRIPT_UUID" ] && info "Recovered uuid from DB: $SCRIPT_UUID"
fi
info "Created script uuid=$SCRIPT_UUID"

if [ -n "$SCRIPT_UUID" ]; then
    assert_rpc "getScript" "Scripts" "getScript" "{\"uuid\":\"$SCRIPT_UUID\"}" "hello from omvtest"

    if [ -f "$SFPATH/omvtest_script.sh" ]; then
        _pass "setScript wrote file to shared folder"
        PERMS=$(stat -c '%a' "$SFPATH/omvtest_script.sh" 2>/dev/null)
        info "File perms: $PERMS"
    else
        _fail "setScript wrote file to shared folder" "$SFPATH/omvtest_script.sh missing"
    fi

    UPDATE_BODY='#!/bin/bash
echo "hello from omvtest - updated"
exit 0'
    UPDATE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$SCRIPT_UUID',
    'name': 'omvtest_script',
    'ext': 'sh',
    'body': '''$UPDATE_BODY''',
    'testargs': ''
}))
")
    assert_rpc "setScript (update)" "Scripts" "setScript" "$UPDATE_PARAMS" "updated"
else
    _skip "getScript" "no script uuid"
    _skip "setScript wrote file to shared folder" "no script uuid"
    _skip "setScript (update)" "no script uuid"
fi

assert_rpc_fails "setScript (missing name)" "Scripts" "setScript" \
    '{"ext":"sh","body":"echo test","testargs":""}'

assert_rpc_fails "getScript (bad uuid)" "Scripts" "getScript" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# --- Second throwaway script, used only for the deleteScript happy path -----
DELETE_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'name': 'omvtest_script_delete',
    'ext': 'sh',
    'body': '#!/bin/bash\necho throwaway',
    'testargs': ''
}))
")
assert_rpc "setScript (create throwaway for delete test)" "Scripts" "setScript" "$DELETE_PARAMS"
SCRIPT2_UUID=$(json_uuid "$RPC_OUT")
if [ -z "$SCRIPT2_UUID" ]; then
    SCRIPT2_UUID=$(recover_uuid_from_list "Scripts" "getScriptList" "name" "omvtest_script_delete")
fi
if [ -n "$SCRIPT2_UUID" ]; then
    assert_rpc "deleteScript" "Scripts" "deleteScript" "{\"uuid\":\"$SCRIPT2_UUID\"}"
    if [ ! -f "$SFPATH/omvtest_script_delete.sh" ]; then
        _pass "deleteScript removed file from shared folder"
    else
        _fail "deleteScript removed file from shared folder" "file still present"
    fi
    SCRIPT2_UUID=""
else
    _skip "deleteScript" "no throwaway script uuid"
fi

assert_rpc_fails "deleteScript (bad uuid)" "Scripts" "deleteScript" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ===========================================================================
section "Scripts — doCheck / doRun (background execution)"
# ===========================================================================

if [ -n "$SCRIPT_UUID" ]; then
    assert_rpc_bg "doCheck (shellcheck)" "Scripts" "doCheck" "{\"uuid\":\"$SCRIPT_UUID\"}" "shellcheck"
    assert_rpc_bg "doRun" "Scripts" "doRun" "{\"uuid\":\"$SCRIPT_UUID\"}" "hello from omvtest"
else
    _skip "doCheck (shellcheck)" "no script uuid"
    _skip "doRun" "no script uuid"
fi

assert_rpc_fails "doRun (bad uuid)" "Scripts" "doRun" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ===========================================================================
section "Scripts — name validation, argument quoting, checker safety"
# ===========================================================================

assert_rpc_fails "setScript rejects name with spaces" "Scripts" "setScript" \
    '{"name":"omvtest bad name","ext":"sh","body":"echo x","testargs":""}'
assert_rpc_fails "setScript rejects path traversal in name" "Scripts" "setScript" \
    '{"name":"../omvtest_escape","ext":"sh","body":"echo x","testargs":""}'
if [ ! -e "$SFPATH/../omvtest_escape.sh" ]; then
    _pass "setScript did not write outside the shared folder"
else
    _fail "setScript did not write outside the shared folder" "$SFPATH/../omvtest_escape.sh exists"
    rm -f "$SFPATH/../omvtest_escape.sh"
fi

# testargs must reach the script tokenized the way sh would (as cron does).
ARGS_BODY='#!/bin/bash
for a in "$@"; do echo "[$a]"; done'
if create_script "omvtest_args" "sh" "$ARGS_BODY" "\"a b\" 'c d' e\\ f \"x\\\"y\" g\"h i\""; then
    assert_rpc_bg "doRun with quoted testargs" "Scripts" "doRun" "{\"uuid\":\"$NEW_UUID\"}"
    assert_contains "testargs: double-quoted arg kept whole" "$BG_OUT" "[a b]"
    assert_contains "testargs: single-quoted arg kept whole" "$BG_OUT" "[c d]"
    assert_contains "testargs: backslash-escaped space" "$BG_OUT" "[e f]"
    assert_contains "testargs: escaped quote inside double quotes" "$BG_OUT" '[x"y]'
    assert_contains "testargs: adjacent pieces join into one arg" "$BG_OUT" "[gh i]"
fi

# doCheck must never execute a file type it has no checker for.
CHECK_MARKER=$(mktemp -u /tmp/omvtest_check_marker.XXXXXX)
if create_script "omvtest_check_conf" "conf" "#!/bin/sh
touch $CHECK_MARKER"; then
    assert_rpc_bg "doCheck on .conf reports no checker" "Scripts" "doCheck" \
        "{\"uuid\":\"$NEW_UUID\"}" "No checker available"
    if [ ! -e "$CHECK_MARKER" ]; then
        _pass "doCheck on .conf did not execute the file"
    else
        _fail "doCheck on .conf did not execute the file" "$CHECK_MARKER was created"
    fi
fi

# ===========================================================================
section "Scripts — importChanges (external edit picked up from disk)"
# ===========================================================================

if [ -n "$SCRIPT_UUID" ] && [ -f "$SFPATH/omvtest_script.sh" ]; then
    printf '#!/bin/bash\necho "edited externally"\nexit 0\n' > "$SFPATH/omvtest_script.sh"
    assert_rpc "importChanges" "Scripts" "importChanges" "{\"uuid\":\"$SCRIPT_UUID\"}" "edited externally"
else
    _skip "importChanges" "no script file to edit"
fi

# ===========================================================================
section "Scripts — importExistingOne / importExistingFolder"
# ===========================================================================

IMPORT_TMPDIR=$(mktemp -d /tmp/omvtest_scripts_import.XXXXXX)

printf '#!/bin/bash\necho "imported one"\n' > "$IMPORT_TMPDIR/omvtest_import_one.sh"
assert_rpc "importExistingOne" "Scripts" "importExistingOne" \
    "{\"path\":\"$IMPORT_TMPDIR/omvtest_import_one.sh\"}"
IMPORT_ONE_UUID=$(recover_uuid_from_list "Scripts" "getScriptList" "name" "omvtest_import_one")
if [ -n "$IMPORT_ONE_UUID" ]; then
    _pass "importExistingOne — script present in getScriptList"
else
    _fail "importExistingOne — script present in getScriptList" "omvtest_import_one not found"
fi
if [ -f "$SFPATH/omvtest_import_one.sh" ]; then
    _pass "importExistingOne — file written to shared folder without manual apply"
else
    _fail "importExistingOne — file written to shared folder without manual apply" \
        "$SFPATH/omvtest_import_one.sh missing"
fi

printf '#!/bin/bash\necho "bad name"\n' > "$IMPORT_TMPDIR/omvtest bad name.sh"
assert_rpc_fails "importExistingOne rejects invalid file name" "Scripts" "importExistingOne" \
    "{\"path\":\"$IMPORT_TMPDIR/omvtest bad name.sh\"}"

assert_rpc_fails "importExistingOne (not a file)" "Scripts" "importExistingOne" \
    "{\"path\":\"$IMPORT_TMPDIR/does_not_exist.sh\"}"

mkdir -p "$IMPORT_TMPDIR/folder"
printf '#!/bin/bash\necho "imported sh"\n' > "$IMPORT_TMPDIR/folder/omvtest_import_sh.sh"
printf '#!/usr/bin/env python3\nprint("imported py")\n' > "$IMPORT_TMPDIR/folder/omvtest_import_py.py"
printf '<?php\necho "imported php";\n' > "$IMPORT_TMPDIR/folder/omvtest_import_php.php"
printf '{"imported": "json"}\n' > "$IMPORT_TMPDIR/folder/omvtest_import_json.json"
printf '#!/bin/bash\necho "skip me"\n' > "$IMPORT_TMPDIR/folder/omvtest skipped name.sh"
assert_rpc "importExistingFolder" "Scripts" "importExistingFolder" \
    "{\"path\":\"$IMPORT_TMPDIR/folder\"}"
for n in omvtest_import_sh omvtest_import_py omvtest_import_php omvtest_import_json; do
    u=$(recover_uuid_from_list "Scripts" "getScriptList" "name" "$n")
    if [ -n "$u" ]; then
        _pass "importExistingFolder — $n present in getScriptList"
        IMPORT_FOLDER_UUIDS+=("$u")
    else
        _fail "importExistingFolder — $n present in getScriptList" "not found"
    fi
done
for f in omvtest_import_php.php omvtest_import_json.json; do
    if [ -f "$SFPATH/$f" ]; then
        _pass "importExistingFolder — $f written with its own extension"
    else
        _fail "importExistingFolder — $f written with its own extension" "$SFPATH/$f missing"
    fi
done
SKIPPED=$(recover_uuid_from_list "Scripts" "getScriptList" "name" "omvtest skipped name")
if [ -z "$SKIPPED" ]; then
    _pass "importExistingFolder — skipped file with invalid name"
else
    _fail "importExistingFolder — skipped file with invalid name" "imported as $SKIPPED"
    IMPORT_FOLDER_UUIDS+=("$SKIPPED")
fi

# ===========================================================================
section "addUrl — scheme validation (no network access required)"
# ===========================================================================

assert_rpc_fails "addUrl rejects ftp:// scheme (SSRF protection)" "Scripts" "addUrl" \
    '{"url":"ftp://example.com/script.sh","name":"omvtest_url_ftp"}'
assert_rpc_fails "addUrl rejects file:// scheme (SSRF protection)" "Scripts" "addUrl" \
    '{"url":"file:///etc/passwd","name":"omvtest_url_file"}'
assert_rpc_fails "addUrl (missing url param)" "Scripts" "addUrl" \
    '{"name":"omvtest_url_missing"}'
info "Happy-path download test skipped — no network access assumed"

# ===========================================================================
section "Git integration — diff"
# ===========================================================================

if [ -d "$SFPATH/.git" ] && [ -n "$SCRIPT_UUID" ]; then
    assert_rpc_bg "doGit diff" "Scripts" "doGit" \
        "{\"uuid\":\"$SCRIPT_UUID\",\"command\":\"diff\"}" "omvtest_script.sh"
else
    _skip "doGit diff" "no git repo or no script uuid"
fi

assert_rpc_fails "doGit rejects unknown command" "Scripts" "doGit" \
    '{"uuid":"","command":"bogus"}'

# ===========================================================================
section "Jobs — CRUD"
# ===========================================================================

assert_rpc "getJobList" "Scripts" "getJobList" "$JOB_LIST_PARAMS" '"total"'

if [ -n "$SCRIPT_UUID" ]; then
    JOB_PARAMS=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$OMV_NEW_UUID',
    'enable': False,
    'script': '$SCRIPT_UUID',
    'args': '',
    'sendemail': False,
    'emailonerror': False,
    'comment': 'omvtest_job',
    'execution': 'weekly',
    'minute': ['0'], 'everynminute': False,
    'hour': ['2'], 'everynhour': False,
    'dayofmonth': ['*'], 'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['*']
}))
")
    assert_rpc "setJob (create)" "Scripts" "setJob" "$JOB_PARAMS"
    JOB_UUID=$(json_uuid "$RPC_OUT")
    if [ -z "$JOB_UUID" ]; then
        JOB_UUID=$(recover_uuid_from_list "Scripts" "getJobList" "comment" "omvtest_job")
    fi
    info "Created job uuid=$JOB_UUID"

    if [ -n "$JOB_UUID" ]; then
        assert_rpc "getJob" "Scripts" "getJob" "{\"uuid\":\"$JOB_UUID\"}"
        JOB="$RPC_OUT"

        MIN_OK=$(echo "$JOB" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('minute')==['0'])" 2>/dev/null)
        if [ "$MIN_OK" = "True" ]; then
            _pass "getJob — minute round-trips as array"
        else
            _fail "getJob — minute round-trips as array" "got: $(json_get "$JOB" minute)"
        fi

        UPDATE_JOB=$(python3 -c "
import json
print(json.dumps({
    'uuid': '$JOB_UUID',
    'enable': False,
    'script': '$SCRIPT_UUID',
    'args': '',
    'sendemail': False,
    'emailonerror': False,
    'comment': 'omvtest_job',
    'execution': 'daily',
    'minute': ['0'], 'everynminute': False,
    'hour': ['3'], 'everynhour': False,
    'dayofmonth': ['*'], 'everyndayofmonth': False,
    'month': ['*'],
    'dayofweek': ['*']
}))
")
        assert_rpc "setJob (update execution/hour)" "Scripts" "setJob" "$UPDATE_JOB" 'daily'

        assert_rpc_bg "doJob" "Scripts" "doJob" "{\"uuid\":\"$JOB_UUID\"}"

        assert_rpc "deleteJob" "Scripts" "deleteJob" "{\"uuid\":\"$JOB_UUID\"}"
        JOB_UUID=""
    else
        _skip "getJob" "no job uuid"
        _skip "getJob — minute round-trips as array" "no job uuid"
        _skip "setJob (update execution/hour)" "no job uuid"
        _skip "doJob" "no job uuid"
        _skip "deleteJob" "no job uuid"
    fi
else
    _skip "setJob (create)" "no script uuid for script ref"
fi

MISSING_SCRIPT_JOB=$(python3 -c "
import json, uuid
print(json.dumps({
    'uuid': str(uuid.uuid4()),
    'enable': False, 'script': '', 'args': '',
    'sendemail': False, 'emailonerror': False, 'comment': '',
    'execution': 'daily',
    'minute': ['0'], 'everynminute': False,
    'hour': ['2'], 'everynhour': False,
    'dayofmonth': ['*'], 'everyndayofmonth': False,
    'month': ['*'], 'dayofweek': ['*']
}))
")
assert_rpc_fails "setJob (missing script ref)" "Scripts" "setJob" "$MISSING_SCRIPT_JOB"

if [ -n "$SCRIPT_UUID" ]; then
    # job_params <minute> <hour> <enable> <args> <comment> <execution> [sendemail]
    job_params() {
        python3 -c "
import json, sys
m, h, en, args, comment, ex = sys.argv[1:7]
mail = len(sys.argv) > 7 and sys.argv[7] == 'true'
print(json.dumps({
    'uuid': '$OMV_NEW_UUID', 'enable': en == 'true', 'script': '$SCRIPT_UUID',
    'args': args, 'sendemail': mail, 'emailonerror': False, 'comment': comment,
    'execution': ex,
    'minute': [m], 'everynminute': False, 'hour': [h], 'everynhour': False,
    'dayofmonth': ['*'], 'everyndayofmonth': False, 'month': ['*'], 'dayofweek': ['*']
}))" "$@"
    }
    assert_rpc_fails "setJob rejects minute 99" "Scripts" "setJob" \
        "$(job_params 99 2 false '' omvtest_bad exactly)"
    assert_rpc_fails "setJob rejects hour 24" "Scripts" "setJob" \
        "$(job_params 0 24 false '' omvtest_bad exactly)"

    # An enabled job is written to cron; % must be escaped there or cron
    # treats it as a newline. Yearly so it will not actually fire; email on
    # so the comment is written into the mail subject.
    if assert_rpc "setJob (enabled, % in args and comment)" "Scripts" "setJob" \
            "$(job_params 0 0 true '--date=%F' 'omvtest_cronpct 50%' yearly true)"; then
        JOB2_UUID=$(json_uuid "$RPC_OUT")
        assert_rpc "applyChanges (scripts)" "Config" "applyChanges" \
            '{"modules":["scripts"],"force":true}'
        CRON=$(cat /etc/cron.d/omv-scripts-jobs 2>/dev/null)
        assert_contains "cron line escapes % in args" "$CRON" '--date=\%F'
        assert_contains "cron line escapes % in comment" "$CRON" 'omvtest_cronpct 50\%'
        if [ -n "$JOB2_UUID" ]; then
            assert_rpc "deleteJob (cron % job)" "Scripts" "deleteJob" "{\"uuid\":\"$JOB2_UUID\"}"
            JOB2_UUID=""
        fi
    fi
fi

assert_rpc_fails "deleteJob (bad uuid)" "Scripts" "deleteJob" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

assert_rpc_fails "doJob (bad uuid)" "Scripts" "doJob" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

# ===========================================================================
section "Exec log — list, view, delete"
# ===========================================================================
# doRun/doJob above ran omv-scripts-exec-wrapper against omvtest_script.sh,
# which appends a row to the tracker CSV. Find one of those rows and drive
# viewLog/deleteLog against it.

LOG_LIST_PARAMS='{"start":0,"limit":100,"sortfield":"start","sortdir":"DESC"}'
assert_rpc "getLogList" "Scripts" "getLogList" "$LOG_LIST_PARAMS" '"total"'

LOG_ROW=$(echo "$RPC_OUT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
match = next((r for r in rows if r.get('script') == 'omvtest_script.sh'), None)
print(json.dumps(match) if match else '')
" 2>/dev/null || echo "")

if [ -n "$LOG_ROW" ]; then
    _pass "getLogList — contains entry for omvtest_script.sh"
    LOG_ID=$(json_get "$LOG_ROW" "id")
    LOG_FILE=$(json_get "$LOG_ROW" "logfile")
    LOG_RUNLOG=$(json_get "$LOG_ROW" "runlog")

    assert_rpc_bg "viewLog" "Scripts" "viewLog" "{\"runlog\":\"$LOG_RUNLOG\"}"

    DELETE_LOG_PARAMS=$(python3 -c "
import json
print(json.dumps({'id': '$LOG_ID', 'logfile': '$LOG_FILE', 'runlog': '$LOG_RUNLOG'}))
")
    assert_rpc "deleteLog" "Scripts" "deleteLog" "$DELETE_LOG_PARAMS"

    STILL_PRESENT=$(omv-rpc -u admin "Scripts" "getLogList" "$LOG_LIST_PARAMS" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = d.get('data', d) if isinstance(d, dict) else d
print(any(r.get('id') == '$LOG_ID' for r in rows))
" 2>/dev/null || echo "True")
    if [ "$STILL_PRESENT" = "False" ]; then
        _pass "deleteLog — row removed from getLogList"
    else
        _fail "deleteLog — row removed from getLogList" "id $LOG_ID still present"
    fi
    if [ ! -f "$LOG_RUNLOG" ]; then
        _pass "deleteLog — run log file removed"
    else
        _fail "deleteLog — run log file removed" "$LOG_RUNLOG still exists"
    fi
    LOG_ID=""
else
    _skip "getLogList — contains entry for omvtest_script.sh" "no matching row (doRun/doJob may not have logged yet)"
    _skip "viewLog" "no log row"
    _skip "deleteLog" "no log row"
    _skip "deleteLog — row removed from getLogList" "no log row"
    _skip "deleteLog — run log file removed" "no log row"
fi

# ===========================================================================
section "Exec log — path/id validation and non-text output"
# ===========================================================================

assert_rpc_fails "viewLog rejects runlog outside log dir" "Scripts" "viewLog" \
    '{"runlog":"/etc/passwd"}'
assert_rpc_fails "viewLog rejects ../ traversal" "Scripts" "viewLog" \
    '{"runlog":"/var/log/omv-scripts-exec-tracker/../../../etc/passwd"}'

VICTIM=$(mktemp /tmp/omvtest_victim.XXXXXX)
assert_rpc_fails "deleteLog rejects runlog outside log dir" "Scripts" "deleteLog" \
    "{\"id\":\"00000000-0000-0000-0000-000000000000\",\"logfile\":\"/var/log/omv-scripts-exec-tracker.log\",\"runlog\":\"$VICTIM\"}"
if [ -f "$VICTIM" ]; then
    _pass "deleteLog left file outside log dir alone"
else
    _fail "deleteLog left file outside log dir alone" "$VICTIM was deleted"
fi
rm -f "$VICTIM"
assert_rpc_fails "deleteLog rejects logfile that is not a tracker csv" "Scripts" "deleteLog" \
    '{"id":"00000000-0000-0000-0000-000000000000","logfile":"/etc/passwd","runlog":"/var/log/omv-scripts-exec-tracker/x.log"}'
assert_rpc_fails "deleteLog rejects non-uuid id" "Scripts" "deleteLog" \
    "{\"id\":\"x'; touch /tmp/omvtest_pwned; '\",\"logfile\":\"/var/log/omv-scripts-exec-tracker.log\",\"runlog\":\"/var/log/omv-scripts-exec-tracker/x.log\"}"
if [ ! -e /tmp/omvtest_pwned ]; then
    _pass "deleteLog id was not passed to the shell"
else
    _fail "deleteLog id was not passed to the shell" "/tmp/omvtest_pwned created"
    rm -f /tmp/omvtest_pwned
fi

# A run log holding JSON is not text/* to libmagic; viewLog must still show it.
if create_script "omvtest_json" "sh" '#!/bin/sh
echo "{\"omvtest\": [1, 2, 3]}"'; then
    assert_rpc_bg "doRun (script printing JSON)" "Scripts" "doRun" "{\"uuid\":\"$NEW_UUID\"}"
    JSON_ROW=$(find_log_row "omvtest_json.sh")
    if [ -n "$JSON_ROW" ]; then
        JSON_RUNLOG=$(json_get "$JSON_ROW" "runlog")
        assert_rpc_bg "viewLog on JSON run log" "Scripts" "viewLog" \
            "{\"runlog\":\"$JSON_RUNLOG\"}" "omvtest"
        omv-rpc -u admin "Scripts" "deleteLog" "$(python3 -c "
import json
print(json.dumps({'id': '$(json_get "$JSON_ROW" id)', 'logfile': '$(json_get "$JSON_ROW" logfile)', 'runlog': '$JSON_RUNLOG'}))
")" >/dev/null 2>&1 || true
    else
        _skip "viewLog on JSON run log" "no log row for omvtest_json.sh"
    fi
fi

# ===========================================================================
# Summary
# ===========================================================================
section "Summary"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  ${GREEN}PASS${NC}: $PASS   ${RED}FAIL${NC}: $FAIL   ${YELLOW}SKIP${NC}: $SKIP   (of $TOTAL)" >&2
if [ $FAIL -gt 0 ]; then
    echo -e "\n${RED}${BOLD}Failed tests:${NC}" >&2
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "  ${RED}✗${NC} $t" >&2
    done
    exit 1
fi
exit 0
