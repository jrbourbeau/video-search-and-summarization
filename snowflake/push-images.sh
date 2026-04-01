#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Pull container images from their source registries and push them to the
# Snowflake image registry for use with Snowpark Container Services.
#
# Usage:
#   ./snowflake/push-images.sh
#
# Prerequisites:
#   - docker (v27.2+) installed and running
#   - NGC API key exported as NGC_CLI_API_KEY (for NVIDIA images)
#   - Snowflake CLI (snow) installed and configured
#   - SNOWFLAKE_REGISTRY set (run setup.sql first, then: SHOW IMAGE REPOSITORIES)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these if your Snowflake objects use different names
# ---------------------------------------------------------------------------
SNOWFLAKE_ACCOUNT="${SNOWFLAKE_ACCOUNT:-}"       # e.g. myorg-myaccount
SNOWFLAKE_DB="${SNOWFLAKE_DB:-VSS_DB}"
SNOWFLAKE_SCHEMA="${SNOWFLAKE_SCHEMA:-VSS_SCHEMA}"
SNOWFLAKE_REPO="${SNOWFLAKE_REPO:-VSS_IMAGES}"
NGC_CLI_API_KEY="${NGC_CLI_API_KEY:-}"

# ---------------------------------------------------------------------------
# Validate required environment variables
# ---------------------------------------------------------------------------
if [[ -z "${SNOWFLAKE_ACCOUNT}" ]]; then
    echo "ERROR: SNOWFLAKE_ACCOUNT is not set."
    echo "  Set it to your Snowflake account identifier, e.g. myorg-myaccount"
    exit 1
fi

if [[ -z "${NGC_CLI_API_KEY}" ]]; then
    echo "ERROR: NGC_CLI_API_KEY is not set."
    echo "  Get your NGC API key from https://ngc.nvidia.com/"
    exit 1
fi

# Snowflake registry URL format: <org>-<account>.registry.snowflakecomputing.com
REGISTRY="${SNOWFLAKE_ACCOUNT}.registry.snowflakecomputing.com"
REPO_PREFIX="${REGISTRY}/${SNOWFLAKE_DB,,}/${SNOWFLAKE_SCHEMA,,}/${SNOWFLAKE_REPO,,}"

echo "=================================================="
echo "VSS Blueprint - Snowflake Image Registry Push"
echo "=================================================="
echo "  Registry:  ${REGISTRY}"
echo "  Repo path: ${REPO_PREFIX}"
echo ""

# ---------------------------------------------------------------------------
# Login to source registries
# ---------------------------------------------------------------------------
echo ">>> Logging in to NVIDIA Container Registry (nvcr.io)..."
echo "${NGC_CLI_API_KEY}" | docker login nvcr.io --username=\$oauthtoken --password-stdin

echo ">>> Logging in to Snowflake image registry..."
snow spcs image-registry login --connection default 2>/dev/null || \
    docker login "${REGISTRY}" --username snowflake --password "$(snow sql -q "SELECT SYSTEM\$GET_SNOWFLAKE_TOKEN()" --format json | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['SYSTEM\$GET_SNOWFLAKE_TOKEN()'])")"

# ---------------------------------------------------------------------------
# Image list: (source_image, target_tag)
# ---------------------------------------------------------------------------
declare -A IMAGES=(
    # Public images (no auth required)
    ["redis:8.2.2-alpine"]="redis:8.2.2-alpine"
    ["arizephoenix/phoenix:version-8.12.1"]="phoenix:version-8.12.1"
    ["postgres:17.6-alpine"]="postgres:17.6-alpine"

    # NVIDIA Container Registry images (requires NGC API key)
    ["nvcr.io/nvidia/vss-core/vss-agent:3.1.0"]="vss-agent:3.1.0"
    ["nvcr.io/nvidia/vss-core/vss-agent-ui:3.1.0"]="vss-agent-ui:3.1.0"
    ["nvcr.io/nvidia/vss-core/vss-vios-sensor:3.1.0"]="vss-vios-sensor:3.1.0"
    ["nvcr.io/nvidia/vss-core/vss-vios-streamprocessing:3.1.0"]="vss-vios-streamprocessing:3.1.0"
    ["nvcr.io/nvidia/vss-core/vss-vios-ingress:3.1.0"]="vss-vios-ingress:3.1.0"
    ["nvcr.io/nvidia/vss-core/vss-vios-mcp:3.1.0"]="vss-vios-mcp:3.1.0"
    ["nvcr.io/nvidia/vss-core/envoy-proxy:3.1.0"]="envoy-proxy:3.1.0"
)

# ---------------------------------------------------------------------------
# Pull and push each image
# ---------------------------------------------------------------------------
echo ""
echo ">>> Pulling and pushing ${#IMAGES[@]} images..."
echo ""

FAILED=()

for source_image in "${!IMAGES[@]}"; do
    target_tag="${IMAGES[$source_image]}"
    target_image="${REPO_PREFIX}/${target_tag}"

    echo "--- ${source_image}"
    echo "    -> ${target_image}"

    if docker pull "${source_image}"; then
        docker tag "${source_image}" "${target_image}"
        if docker push "${target_image}"; then
            echo "    [OK]"
        else
            echo "    [FAILED to push]"
            FAILED+=("${source_image}")
        fi
    else
        echo "    [FAILED to pull]"
        FAILED+=("${source_image}")
    fi
    echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "=================================================="
    echo "WARNING: The following images failed to push:"
    for img in "${FAILED[@]}"; do
        echo "  - ${img}"
    done
    echo "Check your NGC API key and network connectivity."
    exit 1
else
    echo "=================================================="
    echo "All images pushed successfully to:"
    echo "  ${REPO_PREFIX}"
    echo ""
    echo "Next step: run ./snowflake/deploy.sh"
fi
