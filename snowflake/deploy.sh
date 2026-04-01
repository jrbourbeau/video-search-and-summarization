#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Deploy the NVIDIA Video Search and Summarization Blueprint on
# Snowflake Snowpark Container Services (SPCS).
#
# This script deploys the following services (in dependency order):
#   1. VSS_REDIS    - Redis message broker        (VSS_CPU_POOL)
#   2. VSS_PHOENIX  - Phoenix observability UI    (VSS_CPU_POOL)
#   3. VSS_VST      - Video Storage Toolkit       (VSS_GPU_POOL)
#   4. VSS_AGENT    - VSS Agent (AI reasoning)    (VSS_AGENT_POOL)
#   5. VSS_UI       - Next.js frontend            (VSS_CPU_POOL)
#
# Usage:
#   # Full deployment (setup + images + configs + services):
#   ./snowflake/deploy.sh --all
#
#   # Deploy services only (assumes setup, images, and configs are done):
#   ./snowflake/deploy.sh --services-only
#
#   # Tear down all services:
#   ./snowflake/deploy.sh --teardown
#
# Prerequisites:
#   - Snowflake CLI (snow) >= 3.0 installed and configured
#   - Docker installed (for --all mode)
#   - SNOWFLAKE_ACCOUNT set to your account identifier (e.g. myorg-myaccount)
#   - NGC_CLI_API_KEY set (for pulling NVIDIA images in --all mode)
#   - NVIDIA_API_KEY set (for NVIDIA inference API access)
#
# Environment variables:
#   SNOWFLAKE_ACCOUNT   - Required. Snowflake account identifier.
#   SNOW_CONN           - Snowflake CLI connection name (default: "default")
#   NGC_CLI_API_KEY     - Required for --all mode. NGC API key.
#   NVIDIA_API_KEY      - Required. Key for https://integrate.api.nvidia.com/
#                         (also stored as a Snowflake secret in setup.sql)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECS_DIR="${SCRIPT_DIR}/specs"

SNOW_CONN="${SNOW_CONN:-default}"
SNOW_CMD="snow sql --connection ${SNOW_CONN}"

DB="VSS_DB"
SCHEMA="VSS_SCHEMA"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
RUN_SETUP=false
RUN_IMAGES=false
RUN_CONFIGS=false
RUN_SERVICES=true
RUN_TEARDOWN=false

for arg in "$@"; do
    case "${arg}" in
        --all)           RUN_SETUP=true; RUN_IMAGES=true; RUN_CONFIGS=true; RUN_SERVICES=true ;;
        --services-only) RUN_SERVICES=true ;;
        --setup-only)    RUN_SETUP=true; RUN_SERVICES=false ;;
        --teardown)      RUN_TEARDOWN=true; RUN_SERVICES=false ;;
        *) echo "Unknown option: ${arg}"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo ""; echo ">>> $*"; }
sql() { ${SNOW_CMD} -q "$1" --format json 2>/dev/null; }
sql_scalar() {
    # Returns the first cell value of the first row from a SQL query
    sql "$1" | python3 -c "import sys,json; rows=json.load(sys.stdin); print(list(rows[0].values())[0] if rows else '')" 2>/dev/null || echo ""
}

# Get the ingress URL for a service endpoint
get_ingress_url() {
    local service="$1"
    local endpoint="${2:-api}"
    sql "SHOW ENDPOINTS IN SERVICE ${DB}.${SCHEMA}.${service}" | \
        python3 -c "
import sys, json
rows = json.load(sys.stdin)
for r in rows:
    name = r.get('name','').lower()
    if name == '${endpoint}':
        print(r.get('ingress_url',''))
        sys.exit(0)
" 2>/dev/null || echo ""
}

# Wait for a service to become READY
wait_for_service() {
    local service="$1"
    local timeout="${2:-300}"
    local elapsed=0
    echo -n "    Waiting for ${service} to become READY"
    while [[ $elapsed -lt $timeout ]]; do
        # SHOW SERVICES returns a status column; parse it via python3
        svc_status=$(snow sql \
            -q "SHOW SERVICES LIKE '${service}' IN SCHEMA ${DB}.${SCHEMA};" \
            --connection "${SNOW_CONN}" --format json 2>/dev/null | \
            python3 -c "
import sys, json
rows = json.load(sys.stdin)
if rows:
    print(rows[0].get('status', '').upper())
" 2>/dev/null || echo "")

        case "${svc_status}" in
            READY|RUNNING)
                echo " [${svc_status}]"
                return 0 ;;
            FAILED|SUSPENDED|DELETING)
                echo " [${svc_status}]"
                echo "  Service entered ${svc_status} state. Check logs with:"
                echo "  snow spcs service logs ${service} --connection ${SNOW_CONN}"
                return 1 ;;
        esac
        echo -n "."
        sleep 15
        elapsed=$((elapsed + 15))
    done
    echo " [TIMEOUT after ${timeout}s]"
    echo "  Check with: snow sql -q \"SHOW SERVICES LIKE '${service}'\" --connection ${SNOW_CONN}"
    return 1
}

# Create a service from a spec file, substituting placeholders with actual values
create_service() {
    local service_name="$1"
    local spec_file="$2"
    local compute_pool="$3"
    shift 3
    # Remaining args are SED substitutions: "s/PLACEHOLDER/value/g"
    local subs=("$@")

    local spec_content
    spec_content=$(cat "${spec_file}")

    for sub in "${subs[@]}"; do
        spec_content=$(echo "${spec_content}" | sed "${sub}")
    done

    # Write substituted spec to a temp file
    local tmp_spec
    tmp_spec=$(mktemp /tmp/vss-spec-XXXXXX.yaml)
    echo "${spec_content}" > "${tmp_spec}"

    # Write the CREATE SERVICE SQL to a temp file to avoid shell quoting issues
    local tmp_sql
    tmp_sql=$(mktemp /tmp/vss-create-svc-XXXXXX.sql)
    cat > "${tmp_sql}" <<ENDSQL
CREATE SERVICE IF NOT EXISTS ${DB}.${SCHEMA}.${service_name}
IN COMPUTE POOL ${compute_pool}
FROM SPECIFICATION \$\$
$(cat "${tmp_spec}")
\$\$
EXTERNAL_ACCESS_INTEGRATIONS = (VSS_NVIDIA_ACCESS)
MIN_INSTANCES = 1
MAX_INSTANCES = 1;
ENDSQL

    snow sql -f "${tmp_sql}" --connection "${SNOW_CONN}" || {
        echo "  WARNING: Service creation may have failed. Check Snowflake for details."
    }
    rm -f "${tmp_sql}"

    rm -f "${tmp_spec}"
}

# ---------------------------------------------------------------------------
# TEARDOWN
# ---------------------------------------------------------------------------
if [[ "${RUN_TEARDOWN}" == "true" ]]; then
    log "Tearing down all VSS services..."
    for svc in VSS_UI VSS_AGENT VSS_VST VSS_PHOENIX VSS_REDIS; do
        echo "  Dropping service: ${svc}"
        sql "DROP SERVICE IF EXISTS ${DB}.${SCHEMA}.${svc}" > /dev/null 2>&1 || true
    done
    log "Services dropped. To remove compute pools and other resources, run:"
    echo "  snow sql -f snowflake/teardown.sql --connection ${SNOW_CONN}"
    exit 0
fi

# ---------------------------------------------------------------------------
# VALIDATE REQUIRED ENVIRONMENT
# ---------------------------------------------------------------------------
if [[ -z "${SNOWFLAKE_ACCOUNT:-}" ]]; then
    echo "ERROR: SNOWFLAKE_ACCOUNT is not set."
    echo "  Set it to your Snowflake account identifier (e.g. myorg-myaccount)"
    exit 1
fi

echo "=================================================="
echo "VSS Blueprint - Snowpark Container Services Deploy"
echo "=================================================="
echo "  Account:    ${SNOWFLAKE_ACCOUNT}"
echo "  Connection: ${SNOW_CONN}"
echo "  Database:   ${DB}.${SCHEMA}"
echo ""

# ---------------------------------------------------------------------------
# STEP 1: Snowflake Infrastructure Setup
# ---------------------------------------------------------------------------
if [[ "${RUN_SETUP}" == "true" ]]; then
    log "Running setup.sql (database, compute pools, stages, secrets)..."
    snow sql -f "${SCRIPT_DIR}/setup.sql" --connection "${SNOW_CONN}"

    # Update the NVIDIA_API_KEY secret with the actual value
    if [[ -n "${NVIDIA_API_KEY:-}" ]]; then
        sql "ALTER SECRET ${DB}.${SCHEMA}.NVIDIA_API_KEY SET SECRET_STRING = '${NVIDIA_API_KEY}'" > /dev/null
        echo "  NVIDIA_API_KEY secret updated."
    else
        echo "  WARNING: NVIDIA_API_KEY env var not set."
        echo "  Update the secret manually in Snowflake:"
        echo "    ALTER SECRET VSS_DB.VSS_SCHEMA.NVIDIA_API_KEY SET SECRET_STRING = '<your-key>';"
    fi
fi

# ---------------------------------------------------------------------------
# STEP 2: Push images to Snowflake registry
# ---------------------------------------------------------------------------
if [[ "${RUN_IMAGES}" == "true" ]]; then
    log "Pushing container images to Snowflake registry..."
    SNOWFLAKE_ACCOUNT="${SNOWFLAKE_ACCOUNT}" \
    NGC_CLI_API_KEY="${NGC_CLI_API_KEY:-}" \
        "${SCRIPT_DIR}/push-images.sh"
fi

# ---------------------------------------------------------------------------
# STEP 3: Upload config files to @VSS_CONFIGS stage
# ---------------------------------------------------------------------------
if [[ "${RUN_CONFIGS}" == "true" ]]; then
    log "Uploading config files to @VSS_CONFIGS stage..."
    SNOW_CONN="${SNOW_CONN}" "${SCRIPT_DIR}/upload-configs.sh"
fi

# ---------------------------------------------------------------------------
# STEP 4: Deploy services
# ---------------------------------------------------------------------------
if [[ "${RUN_SERVICES}" == "false" ]]; then
    log "Skipping service deployment (--setup-only mode)."
    exit 0
fi

# Internal DNS base for inter-service communication
DNS_BASE="${DB,,}-${SCHEMA,,}".snowflakecomputing.internal
# Actually in SPCS the format is: <service>.<schema>.<db>.snowflakecomputing.internal
# with underscores converted to hyphens
DNS_SUFFIX="${SCHEMA//_/-}.${DB//_/-}.snowflakecomputing.internal"

# --- 4a. Redis ---
log "Deploying VSS_REDIS (Redis message broker)..."
create_service "VSS_REDIS" "${SPECS_DIR}/redis.yaml" "VSS_CPU_POOL"
wait_for_service "VSS_REDIS" 120

REDIS_DNS="vss-redis.${DNS_SUFFIX}"
echo "  Redis internal DNS: ${REDIS_DNS}:6379"

# --- 4b. Phoenix ---
log "Deploying VSS_PHOENIX (Phoenix observability)..."
create_service "VSS_PHOENIX" "${SPECS_DIR}/phoenix.yaml" "VSS_CPU_POOL"
wait_for_service "VSS_PHOENIX" 180

PHOENIX_DNS="vss-phoenix.${DNS_SUFFIX}"
PHOENIX_INTERNAL="http://${PHOENIX_DNS}:6006"
PHOENIX_PUBLIC=$(get_ingress_url "VSS_PHOENIX" "ui")
echo "  Phoenix internal: ${PHOENIX_INTERNAL}"
echo "  Phoenix public:   ${PHOENIX_PUBLIC}"

# --- 4c. VST (Video Storage Toolkit) ---
log "Deploying VSS_VST (Video Storage Toolkit - requires GPU pool)..."
create_service "VSS_VST" "${SPECS_DIR}/vst.yaml" "VSS_GPU_POOL" \
    "s|REDIS_DNS_PLACEHOLDER|${REDIS_DNS}|g"
wait_for_service "VSS_VST" 300

VST_DNS="vss-vst.${DNS_SUFFIX}"
VST_INTERNAL="http://${VST_DNS}:30888"
VST_MCP_INTERNAL="http://${VST_DNS}:8001"
VST_PUBLIC=$(get_ingress_url "VSS_VST" "api")
echo "  VST internal:     ${VST_INTERNAL}"
echo "  VST MCP internal: ${VST_MCP_INTERNAL}"
echo "  VST public:       ${VST_PUBLIC}"

# --- 4d. VSS Agent ---
log "Deploying VSS_AGENT (VSS Agent - uses remote NVIDIA API for LLM/VLM)..."

# Create the agent service with internal DNS names (no public URL needed yet for most vars)
create_service "VSS_AGENT" "${SPECS_DIR}/vss-agent.yaml" "VSS_AGENT_POOL" \
    "s|VST_INTERNAL_URL_PLACEHOLDER|${VST_INTERNAL}|g" \
    "s|VST_EXTERNAL_URL_PLACEHOLDER|https://${VST_PUBLIC}|g" \
    "s|VST_MCP_URL_PLACEHOLDER|${VST_MCP_INTERNAL}|g" \
    "s|PHOENIX_ENDPOINT_PLACEHOLDER|${PHOENIX_INTERNAL}|g" \
    "s|AGENT_EXTERNAL_URL_PLACEHOLDER|PENDING|g"

wait_for_service "VSS_AGENT" 600

AGENT_DNS="vss-agent.${DNS_SUFFIX}"
AGENT_PUBLIC=$(get_ingress_url "VSS_AGENT" "api")
echo "  Agent internal: http://${AGENT_DNS}:8000"
echo "  Agent public:   ${AGENT_PUBLIC}"

# Update the agent service with its own public URL (needed for report URL generation)
log "Updating VSS_AGENT with its public URL..."
TMP_AGENT_SPEC=$(mktemp /tmp/vss-agent-final-XXXXXX.yaml)
TMP_AGENT_SQL=$(mktemp /tmp/vss-agent-alter-XXXXXX.sql)

sed \
    -e "s|VST_INTERNAL_URL_PLACEHOLDER|${VST_INTERNAL}|g" \
    -e "s|VST_EXTERNAL_URL_PLACEHOLDER|https://${VST_PUBLIC}|g" \
    -e "s|VST_MCP_URL_PLACEHOLDER|${VST_MCP_INTERNAL}|g" \
    -e "s|PHOENIX_ENDPOINT_PLACEHOLDER|${PHOENIX_INTERNAL}|g" \
    -e "s|AGENT_EXTERNAL_URL_PLACEHOLDER|${AGENT_PUBLIC}|g" \
    "${SPECS_DIR}/vss-agent.yaml" > "${TMP_AGENT_SPEC}"

cat > "${TMP_AGENT_SQL}" <<ENDSQL
ALTER SERVICE ${DB}.${SCHEMA}.VSS_AGENT FROM SPECIFICATION \$\$
$(cat "${TMP_AGENT_SPEC}")
\$\$;
ENDSQL

snow sql -f "${TMP_AGENT_SQL}" --connection "${SNOW_CONN}" || \
    echo "  (ALTER SERVICE failed - agent will use 'PENDING' as its own base URL for reports)"
rm -f "${TMP_AGENT_SPEC}" "${TMP_AGENT_SQL}"

# --- 4e. VSS UI ---
log "Deploying VSS_UI (Next.js frontend)..."
create_service "VSS_UI" "${SPECS_DIR}/vss-ui.yaml" "VSS_CPU_POOL" \
    "s|AGENT_EXTERNAL_URL_PLACEHOLDER|${AGENT_PUBLIC}|g" \
    "s|VST_EXTERNAL_URL_PLACEHOLDER|${VST_PUBLIC}|g"

wait_for_service "VSS_UI" 300

UI_PUBLIC=$(get_ingress_url "VSS_UI" "ui")
echo "  UI public: ${UI_PUBLIC}"

# ---------------------------------------------------------------------------
# DONE — Print summary
# ---------------------------------------------------------------------------
echo ""
echo "=================================================="
echo "VSS Blueprint deployed successfully!"
echo "=================================================="
echo ""
echo "  UI (frontend):    https://${UI_PUBLIC}"
echo "  Agent API:        https://${AGENT_PUBLIC}"
echo "  VST API:          https://${VST_PUBLIC}/vst"
echo "  Phoenix (traces): ${PHOENIX_PUBLIC}"
echo ""
echo "  Getting started:"
echo "  1. Open the UI URL in your browser"
echo "  2. Upload a video file using the Video Management tab"
echo "  3. Ask questions about the video in the Chat tab"
echo ""
echo "  Monitor services:"
echo "  snow sql -q \"SHOW SERVICES IN SCHEMA ${DB}.${SCHEMA}\" --connection ${SNOW_CONN}"
echo ""
echo "  View logs:"
echo "  snow spcs service logs VSS_AGENT --connection ${SNOW_CONN} --container-name vss-agent"
echo "  snow spcs service logs VSS_VST   --connection ${SNOW_CONN} --container-name sensor-ms"
echo ""
echo "  Suspend compute pools when not in use to save cost:"
echo "  snow sql -q \"ALTER COMPUTE POOL VSS_CPU_POOL SUSPEND\"   --connection ${SNOW_CONN}"
echo "  snow sql -q \"ALTER COMPUTE POOL VSS_AGENT_POOL SUSPEND\" --connection ${SNOW_CONN}"
echo "  snow sql -q \"ALTER COMPUTE POOL VSS_GPU_POOL SUSPEND\"   --connection ${SNOW_CONN}"
echo ""
echo "  Teardown:"
echo "  ./snowflake/deploy.sh --teardown --connection ${SNOW_CONN}"
