# %%
# SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# VSS Blueprint — Snowpark Container Services Deployment Notebook
#
# This file is structured as a Jupyter-style notebook (# %% cell markers).
# Import it into a Snowflake Notebook via: Notebooks > + Notebook > Import .ipynb
# (convert first with: jupytext --to notebook deploy_notebook.py)
#
# Prerequisites (run once outside Snowflake):
#   1. Push container images:  ./snowflake/push-images.sh
#      (requires Docker + NGC API key)
#
# Everything else — infrastructure setup, config staging, service deployment,
# status monitoring, and URL display — runs entirely inside this notebook.

# %% [markdown]
# # NVIDIA VSS Blueprint — Snowpark Container Services
#
# Deploys the [Video Search and Summarization Blueprint](https://github.com/NVIDIA-AI-Blueprints/video-search-and-summarization)
# on Snowflake Snowpark Container Services.
#
# **Run the cells top-to-bottom.** Each section is safe to re-run.
#
# **One prerequisite requires Docker (run once locally):**
# ```bash
# export SNOWFLAKE_ACCOUNT=myorg-myaccount
# export NGC_CLI_API_KEY=<your-ngc-key>
# ./snowflake/push-images.sh
# ```
#
# After that, this notebook handles everything: infrastructure, config uploads, service deployment.

# %% [markdown]
# ## 0 — Configuration
#
# Run this cell — it will prompt you for your NVIDIA API key without echoing it
# to the screen or storing it in the notebook output.

# %%
import getpass

# Prompts securely — input is not echoed and does not appear in cell output
NVIDIA_API_KEY = getpass.getpass("NVIDIA API key (https://build.nvidia.com/): ")

# Snowflake resource names — change only if you prefer different names
DB           = "VSS_DB"
SCHEMA       = "VSS_SCHEMA"
CPU_POOL     = "VSS_CPU_POOL"
AGENT_POOL   = "VSS_AGENT_POOL"
GPU_POOL     = "VSS_GPU_POOL"
STAGE        = f"@{DB}.{SCHEMA}.VSS_CONFIGS"
IMAGE_REPO   = f"{DB}.{SCHEMA}.VSS_IMAGES"

# GitHub branch to download configs from
REPO         = "NVIDIA-AI-Blueprints/video-search-and-summarization"
BRANCH       = "main"
RAW_BASE     = f"https://raw.githubusercontent.com/{REPO}/{BRANCH}"

assert NVIDIA_API_KEY, "NVIDIA_API_KEY must not be empty"
print("✓ Configuration loaded")

# %% [markdown]
# ## 1 — Snowflake Infrastructure
#
# Creates the database, compute pools, image repository, stage, network rules,
# External Access Integrations, and secrets. Safe to re-run.
#
# > **Note:** Run this cell as a role with `CREATE COMPUTE POOL` and
# > `CREATE EXTERNAL ACCESS INTEGRATION` privileges (e.g. `ACCOUNTADMIN` or `SYSADMIN`
# > if those privileges have been granted).

# %%
from snowflake.snowpark.context import get_active_session

session = get_active_session()

def sql(query: str):
    """Execute a SQL statement and collect results."""
    return session.sql(query).collect()

# Database & schema
sql(f"CREATE DATABASE IF NOT EXISTS {DB}")
sql(f"CREATE SCHEMA IF NOT EXISTS {DB}.{SCHEMA}")
sql(f"USE DATABASE {DB}")
sql(f"USE SCHEMA {SCHEMA}")
sql(f"CREATE IMAGE REPOSITORY IF NOT EXISTS {IMAGE_REPO}")

# Compute pools
for name, family, comment in [
    (CPU_POOL,   "CPU_X64_L",   "VSS: Redis, Phoenix, UI"),
    (AGENT_POOL, "CPU_X64_XL",  "VSS: Agent"),
    (GPU_POOL,   "GPU_NV_S",    "VSS: Video Storage Toolkit"),
]:
    sql(f"""
        CREATE COMPUTE POOL IF NOT EXISTS {name}
            MIN_NODES = 1 MAX_NODES = 3
            INSTANCE_FAMILY = {family}
            AUTO_RESUME = TRUE AUTO_SUSPEND_SECS = 300
            COMMENT = '{comment}'
    """)
    print(f"  ✓ Compute pool: {name} ({family})")

# Stage for config files
sql(f"CREATE STAGE IF NOT EXISTS {DB}.{SCHEMA}.VSS_CONFIGS DIRECTORY = (ENABLE = TRUE)")

# Network rule: NVIDIA inference API
sql(f"""
    CREATE OR REPLACE NETWORK RULE {DB}.{SCHEMA}.VSS_NVIDIA_API_RULE
        TYPE = HOST_PORT MODE = EGRESS
        VALUE_LIST = ('integrate.api.nvidia.com:443', 'api.nvidia.com:443')
""")

# Network rule: GitHub (to download config files in the next cell)
sql(f"""
    CREATE OR REPLACE NETWORK RULE {DB}.{SCHEMA}.VSS_GITHUB_RULE
        TYPE = HOST_PORT MODE = EGRESS
        VALUE_LIST = ('raw.githubusercontent.com:443')
""")

# External Access Integrations
sql(f"""
    CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS VSS_NVIDIA_ACCESS
        ALLOWED_NETWORK_RULES = ({DB}.{SCHEMA}.VSS_NVIDIA_API_RULE)
        ENABLED = TRUE
""")
sql(f"""
    CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS VSS_GITHUB_ACCESS
        ALLOWED_NETWORK_RULES = ({DB}.{SCHEMA}.VSS_GITHUB_RULE)
        ENABLED = TRUE
""")

# Secret for NVIDIA API key (used by the VSS Agent container)
sql(f"""
    CREATE OR REPLACE SECRET {DB}.{SCHEMA}.NVIDIA_API_KEY
        TYPE = GENERIC_STRING
        SECRET_STRING = '{NVIDIA_API_KEY}'
""")

sql("GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE SYSADMIN")

print("✓ Snowflake infrastructure ready")

# %% [markdown]
# ## 2 — Upload Configuration Files
#
# Downloads config files from GitHub and stages them in `@VSS_CONFIGS`.
# Service containers mount this stage at runtime.
#
# > **Requires the `VSS_GITHUB_ACCESS` External Access Integration to be attached
# > to this notebook.** Go to **Notebook settings → External access** and add
# > `VSS_GITHUB_ACCESS`, then re-run this cell.

# %%
import os
import tempfile
import urllib.request

def _put(content: str | bytes, stage_path: str):
    """Write content to a temp file and PUT it to the Snowflake stage."""
    mode = "w" if isinstance(content, str) else "wb"
    with tempfile.NamedTemporaryFile(mode=mode, suffix=".tmp", delete=False, encoding="utf-8" if mode == "w" else None) as f:
        f.write(content)
        tmp = f.name
    try:
        session.sql(
            f"PUT file://{tmp} {STAGE}/{stage_path} AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
        ).collect()
        print(f"  ✓ {stage_path}")
    finally:
        os.unlink(tmp)

def download(path: str) -> str:
    """Download a text file from the GitHub repo."""
    url = f"{RAW_BASE}/{path}"
    with urllib.request.urlopen(url, timeout=15) as r:
        return r.read().decode("utf-8")

# --- VSS Agent config ---
print("Uploading VSS Agent config...")
_put(
    download("deployments/developer-workflow/dev-profile-base/vss-agent/configs/config.yml"),
    "vss-agent/config.yml",
)

# --- VST configs ---
print("Uploading VST configs...")
vst_configs = [
    "deployments/vst/developer/vst/configs/vst_config_redis.json",
    "deployments/vst/developer/vst/configs/vst_storage.json",
    "deployments/vst/developer/vst/configs/adaptor_config.json",
    "deployments/vst/developer/vst/configs/rtsp_streams.json",
    "deployments/vst/developer/vst/configs/postgresql.conf",
    "deployments/vst/developer/vst/configs/nginx-vst.conf.template",
    "deployments/vst/developer/vst/configs/nginx-vst.conf",
]
for repo_path in vst_configs:
    filename = os.path.basename(repo_path)
    _put(download(repo_path), f"vst/configs/{filename}")

# Copy the redis config as the active VST config
_put(download("deployments/vst/developer/vst/configs/vst_config_redis.json"), "vst/configs/vst_config.json")

# --- Static Envoy config for SPCS (replaces SDR-managed XDS config) ---
print("Uploading Envoy static config...")
_put(download("snowflake/configs/envoy-spcs.yaml"), "vst/envoy-spcs.yaml")

print("\n✓ All configs staged")

# %% [markdown]
# ## 3 — Service Helpers
#
# Defines the functions used by the service deployment cells.

# %%
import json
import time
import textwrap

def _get_spec(spec_name: str, **subs) -> str:
    """Download a spec from @VSS_CONFIGS, apply substitutions, return YAML string."""
    local = f"/tmp/{spec_name}.yaml"
    session.file.get(f"{STAGE}/specs/{spec_name}.yaml", "/tmp/")
    with open(local) as f:
        content = f.read()
    os.unlink(local)
    for placeholder, value in subs.items():
        content = content.replace(placeholder, value)
    return content

def _upload_spec(spec_name: str, content: str) -> str:
    """Upload a rendered spec to @VSS_CONFIGS/specs/ and return the stage path."""
    stage_path = f"specs/{spec_name}.yaml"
    _put(content, stage_path)
    return f"{STAGE}/{stage_path}"

def create_service(name: str, pool: str, spec: str):
    """Create an SPCS service from an inline YAML spec string."""
    sql(f"""
        CREATE SERVICE IF NOT EXISTS {DB}.{SCHEMA}.{name}
        IN COMPUTE POOL {pool}
        FROM SPECIFICATION $$
{textwrap.indent(spec, "        ")}
        $$
        EXTERNAL_ACCESS_INTEGRATIONS = (VSS_NVIDIA_ACCESS)
        MIN_INSTANCES = 1
        MAX_INSTANCES = 1
    """)
    print(f"  Service {name} created (or already exists)")

def wait_for_service(name: str, timeout: int = 600) -> bool:
    """Poll until the service is READY/RUNNING or times out."""
    print(f"  Waiting for {name}", end="", flush=True)
    elapsed = 0
    while elapsed < timeout:
        rows = session.sql(
            f"SHOW SERVICES LIKE '{name}' IN SCHEMA {DB}.{SCHEMA}"
        ).collect()
        if rows:
            status = rows[0]["status"].upper()
            if status in ("READY", "RUNNING"):
                print(f" [{status}]")
                return True
            if status in ("FAILED", "DELETING", "SUSPENDED"):
                print(f" [{status}]")
                print(f"  ✗ Service entered {status}. Check logs:")
                print(f"    CALL SYSTEM$GET_SERVICE_LOGS('{DB}.{SCHEMA}.{name}', 0, '<container>', 50);")
                return False
        print(".", end="", flush=True)
        time.sleep(15)
        elapsed += 15
    print(" [TIMEOUT]")
    return False

def get_endpoint_url(service: str, endpoint: str = "api") -> str:
    """Return the public ingress URL for a named service endpoint."""
    rows = session.sql(
        f"SHOW ENDPOINTS IN SERVICE {DB}.{SCHEMA}.{service}"
    ).collect()
    for row in rows:
        if row["name"].lower() == endpoint.lower():
            return row.get("ingress_url", "")
    return ""

# DNS suffix for inter-service communication
# Format: <service-slug>.<schema-slug>.<db-slug>.snowflakecomputing.internal
_db_slug     = DB.lower().replace("_", "-")
_schema_slug = SCHEMA.lower().replace("_", "-")
DNS_SUFFIX   = f"{_schema_slug}.{_db_slug}.snowflakecomputing.internal"

def internal_url(service_name: str, port: int, scheme: str = "http") -> str:
    slug = service_name.lower().replace("_", "-")
    return f"{scheme}://{slug}.{DNS_SUFFIX}:{port}"

print("✓ Helper functions defined")
print(f"  DNS suffix: {DNS_SUFFIX}")

# %% [markdown]
# ## 4 — Upload SPCS Specs
#
# Downloads the service spec YAML files from GitHub (they were created in the
# `snowflake/specs/` directory of this repo) and stages them in `@VSS_CONFIGS/specs/`.
# The deployment cells below will read, substitute placeholders, and deploy from these.

# %%
print("Uploading SPCS spec files...")
for spec in ["redis", "phoenix", "vst", "vss-agent", "vss-ui"]:
    _put(download(f"snowflake/specs/{spec}.yaml"), f"specs/{spec}.yaml")
print("✓ Spec files staged")

# %% [markdown]
# ## 5 — Deploy Redis

# %%
redis_spec = _get_spec("redis")
create_service("VSS_REDIS", CPU_POOL, redis_spec)
wait_for_service("VSS_REDIS", timeout=120)

REDIS_URL = internal_url("VSS_REDIS", 6379)
print(f"\n  Redis internal: {REDIS_URL}")

# %% [markdown]
# ## 6 — Deploy Phoenix

# %%
phoenix_spec = _get_spec("phoenix")
create_service("VSS_PHOENIX", CPU_POOL, phoenix_spec)
wait_for_service("VSS_PHOENIX", timeout=180)

PHOENIX_INTERNAL = internal_url("VSS_PHOENIX", 6006)
PHOENIX_PUBLIC   = get_endpoint_url("VSS_PHOENIX", "ui")
print(f"\n  Phoenix internal: {PHOENIX_INTERNAL}")
print(f"  Phoenix public:   https://{PHOENIX_PUBLIC}")

# %% [markdown]
# ## 7 — Deploy VST (Video Storage Toolkit)
#
# Deploys a multi-container service (postgres + sensor-ms + streamprocessing-ms +
# envoy-proxy + nginx-ingress + vst-mcp) on the GPU compute pool.
# This may take 3–5 minutes for the GPU node to provision.

# %%
vst_spec = _get_spec(
    "vst",
    REDIS_DNS_PLACEHOLDER=f"vss-redis.{DNS_SUFFIX}",
)
create_service("VSS_VST", GPU_POOL, vst_spec)
wait_for_service("VSS_VST", timeout=300)

VST_INTERNAL    = internal_url("VSS_VST", 30888)
VST_MCP_URL     = internal_url("VSS_VST", 8001)
VST_PUBLIC      = get_endpoint_url("VSS_VST", "api")
print(f"\n  VST internal:  {VST_INTERNAL}")
print(f"  VST MCP:       {VST_MCP_URL}")
print(f"  VST public:    https://{VST_PUBLIC}")

# %% [markdown]
# ## 8 — Deploy VSS Agent
#
# The agent uses **remote NVIDIA API** for LLM/VLM inference — no GPU needed here.
# After the service is READY, its own public URL is retrieved and the service is
# updated so report download links point to the correct external address.

# %%
# First pass: create with a placeholder for the agent's own URL
agent_spec_v1 = _get_spec(
    "vss-agent",
    VST_INTERNAL_URL_PLACEHOLDER  = VST_INTERNAL,
    VST_EXTERNAL_URL_PLACEHOLDER  = f"https://{VST_PUBLIC}",
    VST_MCP_URL_PLACEHOLDER       = VST_MCP_URL,
    PHOENIX_ENDPOINT_PLACEHOLDER  = PHOENIX_INTERNAL,
    AGENT_EXTERNAL_URL_PLACEHOLDER= "PENDING",
)
create_service("VSS_AGENT", AGENT_POOL, agent_spec_v1)
wait_for_service("VSS_AGENT", timeout=600)

AGENT_INTERNAL = internal_url("VSS_AGENT", 8000)
AGENT_PUBLIC   = get_endpoint_url("VSS_AGENT", "api")
print(f"\n  Agent internal: {AGENT_INTERNAL}")
print(f"  Agent public:   https://{AGENT_PUBLIC}")

# Second pass: update the service with its own public URL so report URLs resolve correctly
print("\n  Updating agent with its own public URL...")
agent_spec_v2 = _get_spec(
    "vss-agent",
    VST_INTERNAL_URL_PLACEHOLDER  = VST_INTERNAL,
    VST_EXTERNAL_URL_PLACEHOLDER  = f"https://{VST_PUBLIC}",
    VST_MCP_URL_PLACEHOLDER       = VST_MCP_URL,
    PHOENIX_ENDPOINT_PLACEHOLDER  = PHOENIX_INTERNAL,
    AGENT_EXTERNAL_URL_PLACEHOLDER= AGENT_PUBLIC,
)
agent_spec_path = _upload_spec("vss-agent-final", agent_spec_v2)
session.sql(f"""
    ALTER SERVICE {DB}.{SCHEMA}.VSS_AGENT FROM SPECIFICATION $$
{textwrap.indent(agent_spec_v2, "    ")}
    $$
""").collect()
print("  ✓ Agent updated")

# %% [markdown]
# ## 9 — Deploy VSS UI

# %%
ui_spec = _get_spec(
    "vss-ui",
    AGENT_EXTERNAL_URL_PLACEHOLDER = AGENT_PUBLIC,
    VST_EXTERNAL_URL_PLACEHOLDER   = VST_PUBLIC,
)
create_service("VSS_UI", CPU_POOL, ui_spec)
wait_for_service("VSS_UI", timeout=300)

UI_PUBLIC = get_endpoint_url("VSS_UI", "ui")
print(f"\n  UI public: https://{UI_PUBLIC}")

# %% [markdown]
# ## 10 — Deployment Summary

# %%
from IPython.display import display, HTML

summary = f"""
<table style="font-family:monospace;border-collapse:collapse;width:100%">
<tr style="background:#1a1a2e;color:#e0e0e0">
  <th style="padding:8px 12px;text-align:left">Service</th>
  <th style="padding:8px 12px;text-align:left">URL</th>
</tr>
<tr style="background:#16213e;color:#e0e0e0">
  <td style="padding:8px 12px">VSS UI (frontend)</td>
  <td style="padding:8px 12px"><a href="https://{UI_PUBLIC}" style="color:#76b900">https://{UI_PUBLIC}</a></td>
</tr>
<tr style="background:#0f3460;color:#e0e0e0">
  <td style="padding:8px 12px">VSS Agent API</td>
  <td style="padding:8px 12px"><a href="https://{AGENT_PUBLIC}/health" style="color:#76b900">https://{AGENT_PUBLIC}</a></td>
</tr>
<tr style="background:#16213e;color:#e0e0e0">
  <td style="padding:8px 12px">VST API</td>
  <td style="padding:8px 12px"><a href="https://{VST_PUBLIC}/vst" style="color:#76b900">https://{VST_PUBLIC}/vst</a></td>
</tr>
<tr style="background:#0f3460;color:#e0e0e0">
  <td style="padding:8px 12px">Phoenix (traces)</td>
  <td style="padding:8px 12px"><a href="https://{PHOENIX_PUBLIC}" style="color:#76b900">https://{PHOENIX_PUBLIC}</a></td>
</tr>
</table>

<p style="margin-top:12px;font-family:sans-serif">
  <strong>Getting started:</strong>
  Open the UI link, go to <em>Video Management</em>, upload a video, then ask questions in the <em>Chat</em> tab.
</p>
"""
display(HTML(summary))

# %% [markdown]
# ## Useful Operations
#
# **Suspend compute pools when not in use (saves cost):**
# ```python
# for pool in [CPU_POOL, AGENT_POOL, GPU_POOL]:
#     session.sql(f"ALTER COMPUTE POOL {pool} SUSPEND").collect()
# ```
#
# **Resume:**
# ```python
# for pool in [CPU_POOL, AGENT_POOL, GPU_POOL]:
#     session.sql(f"ALTER COMPUTE POOL {pool} RESUME").collect()
# ```
#
# **View service logs:**
# ```python
# logs = session.sql(
#     f"CALL SYSTEM$GET_SERVICE_LOGS('{DB}.{SCHEMA}.VSS_AGENT', 0, 'vss-agent', 100)"
# ).collect()
# print(logs[0][0])
# ```
#
# **Tear down all services:**
# ```python
# for svc in ["VSS_UI", "VSS_AGENT", "VSS_VST", "VSS_PHOENIX", "VSS_REDIS"]:
#     session.sql(f"DROP SERVICE IF EXISTS {DB}.{SCHEMA}.{svc}").collect()
#     print(f"Dropped {svc}")
# ```
