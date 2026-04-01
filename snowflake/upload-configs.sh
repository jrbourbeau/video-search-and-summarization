#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Upload VSS Blueprint configuration files to the @VSS_CONFIGS Snowflake stage.
# These files are mounted into service containers at runtime.
#
# Usage:
#   ./snowflake/upload-configs.sh
#
# Prerequisites:
#   - Snowflake CLI (snow) installed and configured
#   - setup.sql has been run (stage @VSS_CONFIGS must exist)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SNOW_CMD="${SNOW_CMD:-snow}"
SNOW_CONN="${SNOW_CONN:-default}"
STAGE="@VSS_DB.VSS_SCHEMA.VSS_CONFIGS"

# Helper: upload a file to the stage with a given target path
upload() {
    local local_path="$1"
    local stage_path="$2"
    echo "  Uploading: ${local_path} -> ${STAGE}/${stage_path}"
    ${SNOW_CMD} sql \
        -q "PUT file://${local_path} ${STAGE}/${stage_path} AUTO_COMPRESS=FALSE OVERWRITE=TRUE" \
        --connection "${SNOW_CONN}" > /dev/null
}

echo "=================================================="
echo "VSS Blueprint - Uploading Configs to @VSS_CONFIGS"
echo "=================================================="
echo ""

# ---------------------------------------------------------------------------
# VSS Agent config
# Source: deployments/developer-workflow/dev-profile-base/vss-agent/configs/config.yml
# Destination in container: /vss-agent/configs/config.yml
# ---------------------------------------------------------------------------
echo ">>> VSS Agent configuration..."
upload \
    "${REPO_ROOT}/deployments/developer-workflow/dev-profile-base/vss-agent/configs/config.yml" \
    "vss-agent/config.yml"

# ---------------------------------------------------------------------------
# VST configuration files
# Source: deployments/vst/developer/vst/configs/
# Destination in container: /home/vst/vst_release/configs/
# ---------------------------------------------------------------------------
echo ">>> VST configuration files..."
VST_CONFIGS="${REPO_ROOT}/deployments/vst/developer/vst/configs"

for cfg_file in \
    vst_config_redis.json \
    vst_config.json \
    vst_storage.json \
    adaptor_config.json \
    rtsp_streams.json \
    postgresql.conf \
    "nginx-vst.conf.template" \
    "nginx-vst.conf"; do

    if [[ -f "${VST_CONFIGS}/${cfg_file}" ]]; then
        upload "${VST_CONFIGS}/${cfg_file}" "vst/configs/${cfg_file}"
    else
        echo "  WARNING: ${cfg_file} not found at ${VST_CONFIGS}/${cfg_file}, skipping."
    fi
done

# Link the redis config as the active config (STREAM_TYPE=redis)
echo "  Copying vst_config_redis.json -> vst/configs/vst_config.json..."
${SNOW_CMD} sql \
    -q "COPY FILES INTO ${STAGE}/vst/configs/vst_config.json FROM ${STAGE}/vst/configs/vst_config_redis.json" \
    --connection "${SNOW_CONN}" > /dev/null 2>&1 || \
    upload "${VST_CONFIGS}/vst_config_redis.json" "vst/configs/vst_config.json"

# ---------------------------------------------------------------------------
# Static Envoy config for SPCS (replaces SDR-managed dynamic XDS config)
# ---------------------------------------------------------------------------
echo ">>> Static Envoy configuration for SPCS..."
upload \
    "${SCRIPT_DIR}/configs/envoy-spcs.yaml" \
    "vst/envoy-spcs.yaml"

# ---------------------------------------------------------------------------
# SDR streaming config (used by streamprocessing-ms)
# ---------------------------------------------------------------------------
SDR_CFG="${REPO_ROOT}/deployments/vst/developer/vst/sdr-streamprocessing/sdr-config"
if [[ -d "${SDR_CFG}" ]]; then
    echo ">>> SDR config files..."
    for f in "${SDR_CFG}"/*; do
        [[ -f "$f" ]] && upload "$f" "vst/sdr-config/$(basename "$f")"
    done
fi

echo ""
echo "=================================================="
echo "Config upload complete."
echo ""
echo "Verify with:"
echo "  snow sql -q 'LIST ${STAGE}' --connection ${SNOW_CONN}"
echo ""
echo "Next step: run ./snowflake/deploy.sh"
