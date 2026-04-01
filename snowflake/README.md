# VSS Blueprint — Snowpark Container Services Deployment

This directory contains everything needed to deploy the [NVIDIA Video Search and Summarization Blueprint](https://github.com/NVIDIA-AI-Blueprints/video-search-and-summarization) on [Snowflake Snowpark Container Services (SPCS)](https://docs.snowflake.com/en/developer-guide/snowpark-container-services/overview).

## Architecture

The deployment runs five SPCS services:

```
┌─────────────────────────────────────────────────────────────┐
│                     Snowflake SPCS                          │
│                                                             │
│  VSS_UI (CPU_X64_L)          VSS_PHOENIX (CPU_X64_L)        │
│  ┌─────────────────┐         ┌──────────────────────┐       │
│  │  Next.js UI     │         │  Phoenix Tracing UI  │       │
│  │  port 3000      │         │  port 6006           │       │
│  └────────┬────────┘         └──────────────────────┘       │
│           │ WebSocket/HTTP                                   │
│  VSS_AGENT (CPU_X64_XL)                                      │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  VSS Agent (FastAPI + LangGraph)  port 8000         │    │
│  │  └─ Remote LLM: integrate.api.nvidia.com            │    │
│  │  └─ Remote VLM: integrate.api.nvidia.com            │    │
│  └──────────────────────┬──────────────────────────────┘    │
│                         │                                   │
│  VSS_VST (GPU_NV_S)      │        VSS_REDIS (CPU_X64_L)     │
│  ┌──────────────────┐   │        ┌─────────────────────┐   │
│  │  postgres        │   │        │  Redis 8.2          │   │
│  │  sensor-ms ──────┼───┘        │  port 6379          │   │
│  │  streamproc-ms   │            └─────────────────────┘   │
│  │  envoy-proxy     │                                       │
│  │  nginx (30888) ──┼── public endpoint                    │
│  │  vst-mcp (8001)  │                                       │
│  └──────────────────┘                                       │
└─────────────────────────────────────────────────────────────┘
```

LLM and VLM inference is handled by [NVIDIA's hosted API](https://build.nvidia.com/) — no GPU is needed for the AI reasoning layer.

## Prerequisites

| Requirement | Notes |
|---|---|
| Snowflake account with SPCS enabled | Contact Snowflake support to enable SPCS if not active |
| `ACCOUNTADMIN` role (for initial setup) | Required to create compute pools and external access integrations |
| [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/installation/installation) (`snow`) ≥ 3.0 | `pip install snowflake-cli-labs` |
| Docker ≥ 27.2 | For pulling and pushing container images |
| [NGC API key](https://ngc.nvidia.com/) | For pulling NVIDIA container images from `nvcr.io` |
| [NVIDIA API key](https://build.nvidia.com/) | For remote LLM/VLM inference at `integrate.api.nvidia.com` |

## Quick Start

### 1. Configure your Snowflake CLI connection

```bash
snow connection add
# Follow the prompts to add your account, username, and authentication
snow connection test --connection default
```

### 2. Set required environment variables

```bash
export SNOWFLAKE_ACCOUNT=myorg-myaccount   # Your Snowflake account identifier
export NGC_CLI_API_KEY=<your-ngc-key>      # From https://ngc.nvidia.com/
export NVIDIA_API_KEY=<your-nvidia-key>    # From https://build.nvidia.com/
export SNOW_CONN=default                   # Your snow CLI connection name
```

### 3. Deploy

```bash
# From the repo root
./snowflake/deploy.sh --all
```

This runs all four steps (setup → push images → upload configs → deploy services) sequentially. Total time is approximately 20–40 minutes, mostly waiting for NVIDIA images to pull and for SPCS nodes to provision.

After completion the script prints the public URLs:

```
==================================================
VSS Blueprint deployed successfully!
==================================================

  UI (frontend):    https://<hash>-myorg-myaccount.snowflakecomputing.app
  Agent API:        https://<hash>-myorg-myaccount.snowflakecomputing.app
  VST API:          https://<hash>-myorg-myaccount.snowflakecomputing.app/vst
  Phoenix (traces): https://<hash>-myorg-myaccount.snowflakecomputing.app
```

Open the UI URL in your browser to start using the blueprint.

## Step-by-Step Deployment

If you need more control, run each step individually:

```bash
# 1. Create Snowflake objects (database, compute pools, image registry, stages, secrets)
snow sql -f snowflake/setup.sql --connection default

# 2. Update the NVIDIA API key secret
snow sql -q "ALTER SECRET VSS_DB.VSS_SCHEMA.NVIDIA_API_KEY SET SECRET_STRING = '$NVIDIA_API_KEY'" \
    --connection default

# 3. Push all container images to the Snowflake image registry
SNOWFLAKE_ACCOUNT=$SNOWFLAKE_ACCOUNT NGC_CLI_API_KEY=$NGC_CLI_API_KEY \
    ./snowflake/push-images.sh

# 4. Upload config files (agent YAML, VST configs, nginx templates, envoy config)
SNOW_CONN=default ./snowflake/upload-configs.sh

# 5. Deploy services only (skips steps 1–4)
./snowflake/deploy.sh --services-only
```

## File Reference

```
snowflake/
├── setup.sql              # Snowflake objects: database, schema, compute pools,
│                          #   image repository, stages, network rules, EAI, secrets, role
├── teardown.sql           # Drop all resources created by setup.sql
├── push-images.sh         # Pull images from nvcr.io/Docker Hub, push to Snowflake registry
├── upload-configs.sh      # Upload config files to @VSS_CONFIGS stage
├── deploy.sh              # Orchestrate end-to-end deployment
├── configs/
│   └── envoy-spcs.yaml    # Static Envoy proxy config for SPCS
│                          #   (replaces the SDR-managed dynamic XDS config)
└── specs/
    ├── redis.yaml         # Redis message broker (VSS_CPU_POOL)
    ├── phoenix.yaml       # Phoenix observability (VSS_CPU_POOL)
    ├── vst.yaml           # Video Storage Toolkit — multi-container pod (VSS_GPU_POOL):
    │                      #   postgres, sensor-ms, streamprocessing-ms,
    │                      #   envoy-proxy, nginx-ingress, vst-mcp
    ├── vss-agent.yaml     # VSS Agent — FastAPI + LangGraph (VSS_AGENT_POOL)
    └── vss-ui.yaml        # Next.js frontend (VSS_CPU_POOL)
```

## Compute Pools

| Pool | Instance Type | Used By | Est. Cost |
|---|---|---|---|
| `VSS_CPU_POOL` | `CPU_X64_L` | Redis, Phoenix, VSS UI | ~$1/hr |
| `VSS_AGENT_POOL` | `CPU_X64_XL` | VSS Agent | ~$2/hr |
| `VSS_GPU_POOL` | `GPU_NV_S` (T4) | VST (video processing) | ~$3/hr |

Suspend pools when not in use:

```bash
snow sql -q "ALTER COMPUTE POOL VSS_CPU_POOL SUSPEND"   --connection default
snow sql -q "ALTER COMPUTE POOL VSS_AGENT_POOL SUSPEND" --connection default
snow sql -q "ALTER COMPUTE POOL VSS_GPU_POOL SUSPEND"   --connection default
```

## Monitoring

```bash
# Show all VSS services and their status
snow sql -q "SHOW SERVICES IN SCHEMA VSS_DB.VSS_SCHEMA" --connection default

# Show public endpoints
snow sql -q "SHOW ENDPOINTS IN SERVICE VSS_DB.VSS_SCHEMA.VSS_UI"    --connection default
snow sql -q "SHOW ENDPOINTS IN SERVICE VSS_DB.VSS_SCHEMA.VSS_AGENT" --connection default
snow sql -q "SHOW ENDPOINTS IN SERVICE VSS_DB.VSS_SCHEMA.VSS_VST"   --connection default

# Tail logs
snow spcs service logs VSS_AGENT --container-name vss-agent  --connection default
snow spcs service logs VSS_VST   --container-name sensor-ms  --connection default
snow spcs service logs VSS_VST   --container-name vst-ingress --connection default
```

## Teardown

```bash
# Drop services only (keeps compute pools, stages, and images)
./snowflake/deploy.sh --teardown

# Drop everything (irreversible — deletes all data)
snow sql -f snowflake/teardown.sql --connection default
```

## Adaptation Notes

### What changes relative to the Docker Compose deployment

| Original | SPCS adaptation |
|---|---|
| `network_mode: host` | Bridge networking; inter-service communication via SPCS DNS (`<svc>.<schema>.<db>.snowflakecomputing.internal`) |
| Local filesystem mounts for configs | Config files uploaded to `@VSS_CONFIGS` stage and mounted as volumes |
| Local LLM/VLM (`LLM_MODE=local_shared`) | Remote NVIDIA API (`LLM_MODE=remote`, `LLM_BASE_URL=https://integrate.api.nvidia.com`) |
| `sdr-streamprocessing` (mounts `/var/run/docker.sock`) | **Omitted** — Docker socket access is not available in SPCS. SDR is only needed for live RTSP camera stream routing, not for file upload workflows. |
| Dynamic Envoy XDS config (driven by SDR) | Static Envoy config in `configs/envoy-spcs.yaml` routing directly to `streamprocessing-ms` |

### Enabling additional profiles

The `dev-profile-base` (video upload + Q&A + report generation) is deployed by default. To enable other profiles (search, alerts, long video summarization), update the agent config file at `deployments/developer-workflow/dev-profile-<name>/vss-agent/configs/config.yml` and re-run `upload-configs.sh`, then restart the VSS_AGENT service:

```bash
SNOW_CONN=default ./snowflake/upload-configs.sh
snow sql -q "ALTER SERVICE VSS_DB.VSS_SCHEMA.VSS_AGENT SUSPEND" --connection default
snow sql -q "ALTER SERVICE VSS_DB.VSS_SCHEMA.VSS_AGENT RESUME"  --connection default
```

For the search profile, Elasticsearch must also be deployed (not included in this setup). Add a `VSS_ELASTICSEARCH` service using the `elasticsearch` image from `nvcr.io/nvidia/vss-core/` and update the agent's `ELASTIC_SEARCH_ENDPOINT` environment variable.
