-- SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0
--
-- Snowflake setup for NVIDIA Video Search and Summarization Blueprint
-- Run with: snow sql -f snowflake/setup.sql --connection <your-connection>
-- Or with SnowSQL: snowsql -f snowflake/setup.sql
--
-- Prerequisites:
--   - ACCOUNTADMIN role (or equivalent with CREATE DATABASE, CREATE COMPUTE POOL, etc.)
--   - Snowpark Container Services enabled in your account

USE ROLE ACCOUNTADMIN;

-- =============================================================================
-- DATABASE AND SCHEMA
-- =============================================================================
CREATE DATABASE IF NOT EXISTS VSS_DB;
CREATE SCHEMA IF NOT EXISTS VSS_DB.VSS_SCHEMA;
USE DATABASE VSS_DB;
USE SCHEMA VSS_SCHEMA;

-- =============================================================================
-- IMAGE REPOSITORY
-- All container images must be pushed here before deploying services.
-- Run: SHOW IMAGE REPOSITORIES; to get the registry hostname.
-- =============================================================================
CREATE IMAGE REPOSITORY IF NOT EXISTS VSS_DB.VSS_SCHEMA.VSS_IMAGES;

-- =============================================================================
-- COMPUTE POOLS
-- VSS_CPU_POOL: Redis, Phoenix, VSS UI
-- VSS_AGENT_POOL: VSS Agent (CPU-only, uses remote NVIDIA API for LLM/VLM)
-- VSS_GPU_POOL: VST (Video Storage Toolkit - requires GPU for video processing)
-- =============================================================================
CREATE COMPUTE POOL IF NOT EXISTS VSS_CPU_POOL
    MIN_NODES = 1
    MAX_NODES = 3
    INSTANCE_FAMILY = CPU_X64_L
    AUTO_RESUME = TRUE
    AUTO_SUSPEND_SECS = 300
    COMMENT = 'VSS Blueprint: Redis, Phoenix, VSS UI';

CREATE COMPUTE POOL IF NOT EXISTS VSS_AGENT_POOL
    MIN_NODES = 1
    MAX_NODES = 2
    INSTANCE_FAMILY = CPU_X64_XL
    AUTO_RESUME = TRUE
    AUTO_SUSPEND_SECS = 300
    COMMENT = 'VSS Blueprint: VSS Agent';

CREATE COMPUTE POOL IF NOT EXISTS VSS_GPU_POOL
    MIN_NODES = 1
    MAX_NODES = 1
    INSTANCE_FAMILY = GPU_NV_S
    AUTO_RESUME = TRUE
    AUTO_SUSPEND_SECS = 300
    COMMENT = 'VSS Blueprint: Video Storage Toolkit (VST)';

-- =============================================================================
-- STAGES
-- VSS_CONFIGS: Configuration files (agent YAML, VST configs, nginx configs)
-- VSS_DATA: Persistent data (optional; most services use ephemeral local storage)
-- =============================================================================
CREATE STAGE IF NOT EXISTS VSS_DB.VSS_SCHEMA.VSS_CONFIGS
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'VSS Blueprint: Service configuration files';

CREATE STAGE IF NOT EXISTS VSS_DB.VSS_SCHEMA.VSS_DATA
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'VSS Blueprint: Persistent data';

-- =============================================================================
-- NETWORK RULES (for external API access)
-- =============================================================================

-- NVIDIA API for remote LLM/VLM inference
CREATE OR REPLACE NETWORK RULE VSS_DB.VSS_SCHEMA.VSS_NVIDIA_API_RULE
    TYPE = HOST_PORT
    MODE = EGRESS
    VALUE_LIST = (
        'integrate.api.nvidia.com:443',
        'api.nvidia.com:443',
        'nvcr.io:443'
    );

-- =============================================================================
-- EXTERNAL ACCESS INTEGRATION
-- Required for VSS Agent to reach NVIDIA inference API
-- =============================================================================
CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS VSS_NVIDIA_ACCESS
    ALLOWED_NETWORK_RULES = (VSS_DB.VSS_SCHEMA.VSS_NVIDIA_API_RULE)
    ENABLED = TRUE
    COMMENT = 'VSS Blueprint: Access to NVIDIA API for remote LLM/VLM inference';

-- =============================================================================
-- SECRETS
-- Replace <YOUR_NVIDIA_API_KEY> with your actual key from https://build.nvidia.com/
-- Replace <YOUR_NGC_API_KEY> with your NGC key from https://ngc.nvidia.com/
-- =============================================================================
CREATE SECRET IF NOT EXISTS VSS_DB.VSS_SCHEMA.NVIDIA_API_KEY
    TYPE = GENERIC_STRING
    SECRET_STRING = '<YOUR_NVIDIA_API_KEY>'
    COMMENT = 'NVIDIA API key for remote LLM/VLM inference';

CREATE SECRET IF NOT EXISTS VSS_DB.VSS_SCHEMA.NGC_CLI_API_KEY
    TYPE = GENERIC_STRING
    SECRET_STRING = '<YOUR_NGC_API_KEY>'
    COMMENT = 'NGC API key for pulling NVIDIA container images';

-- =============================================================================
-- ROLE AND GRANTS
-- Creates a dedicated role for managing VSS services.
-- Assign this role to any users who need to manage VSS.
-- =============================================================================
CREATE ROLE IF NOT EXISTS VSS_ROLE;

GRANT USAGE ON DATABASE VSS_DB TO ROLE VSS_ROLE;
GRANT USAGE ON SCHEMA VSS_DB.VSS_SCHEMA TO ROLE VSS_ROLE;
GRANT ALL PRIVILEGES ON IMAGE REPOSITORY VSS_DB.VSS_SCHEMA.VSS_IMAGES TO ROLE VSS_ROLE;
GRANT READ, WRITE ON STAGE VSS_DB.VSS_SCHEMA.VSS_CONFIGS TO ROLE VSS_ROLE;
GRANT READ, WRITE ON STAGE VSS_DB.VSS_SCHEMA.VSS_DATA TO ROLE VSS_ROLE;
GRANT USAGE ON COMPUTE POOL VSS_CPU_POOL TO ROLE VSS_ROLE;
GRANT USAGE ON COMPUTE POOL VSS_AGENT_POOL TO ROLE VSS_ROLE;
GRANT USAGE ON COMPUTE POOL VSS_GPU_POOL TO ROLE VSS_ROLE;
GRANT USAGE ON EXTERNAL ACCESS INTEGRATION VSS_NVIDIA_ACCESS TO ROLE VSS_ROLE;
GRANT READ ON SECRET VSS_DB.VSS_SCHEMA.NVIDIA_API_KEY TO ROLE VSS_ROLE;
GRANT READ ON SECRET VSS_DB.VSS_SCHEMA.NGC_CLI_API_KEY TO ROLE VSS_ROLE;
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE VSS_ROLE;

-- Grant VSS_ROLE to SYSADMIN so service admins can manage it
GRANT ROLE VSS_ROLE TO ROLE SYSADMIN;

-- =============================================================================
-- VERIFY SETUP
-- =============================================================================
SHOW IMAGE REPOSITORIES IN SCHEMA VSS_DB.VSS_SCHEMA;
SHOW COMPUTE POOLS;
SHOW STAGES IN SCHEMA VSS_DB.VSS_SCHEMA;
SHOW EXTERNAL ACCESS INTEGRATIONS;
