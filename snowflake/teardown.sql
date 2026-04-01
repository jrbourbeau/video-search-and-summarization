-- SPDX-FileCopyrightText: Copyright (c) 2025-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0
--
-- Tear down all Snowflake resources created for the VSS Blueprint.
-- WARNING: This drops all services, compute pools, stages, and the database.
--          All container data (video files, configs) will be lost.
--
-- Run with: snow sql -f snowflake/teardown.sql --connection <your-connection>

USE ROLE ACCOUNTADMIN;
USE DATABASE VSS_DB;
USE SCHEMA VSS_SCHEMA;

-- =============================================================================
-- DROP SERVICES (stop running containers)
-- =============================================================================
DROP SERVICE IF EXISTS VSS_DB.VSS_SCHEMA.VSS_UI;
DROP SERVICE IF EXISTS VSS_DB.VSS_SCHEMA.VSS_AGENT;
DROP SERVICE IF EXISTS VSS_DB.VSS_SCHEMA.VSS_VST;
DROP SERVICE IF EXISTS VSS_DB.VSS_SCHEMA.VSS_PHOENIX;
DROP SERVICE IF EXISTS VSS_DB.VSS_SCHEMA.VSS_REDIS;

-- =============================================================================
-- SUSPEND AND DROP COMPUTE POOLS
-- =============================================================================
ALTER COMPUTE POOL IF EXISTS VSS_CPU_POOL STOP ALL;
ALTER COMPUTE POOL IF EXISTS VSS_AGENT_POOL STOP ALL;
ALTER COMPUTE POOL IF EXISTS VSS_GPU_POOL STOP ALL;

DROP COMPUTE POOL IF EXISTS VSS_CPU_POOL;
DROP COMPUTE POOL IF EXISTS VSS_AGENT_POOL;
DROP COMPUTE POOL IF EXISTS VSS_GPU_POOL;

-- =============================================================================
-- DROP SECRETS
-- =============================================================================
DROP SECRET IF EXISTS VSS_DB.VSS_SCHEMA.NVIDIA_API_KEY;
DROP SECRET IF EXISTS VSS_DB.VSS_SCHEMA.NGC_CLI_API_KEY;

-- =============================================================================
-- DROP EXTERNAL ACCESS INTEGRATION AND NETWORK RULES
-- =============================================================================
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS VSS_NVIDIA_ACCESS;
DROP NETWORK RULE IF EXISTS VSS_DB.VSS_SCHEMA.VSS_NVIDIA_API_RULE;

-- =============================================================================
-- DROP STAGES (removes all uploaded config files)
-- =============================================================================
DROP STAGE IF EXISTS VSS_DB.VSS_SCHEMA.VSS_CONFIGS;
DROP STAGE IF EXISTS VSS_DB.VSS_SCHEMA.VSS_DATA;

-- =============================================================================
-- DROP IMAGE REPOSITORY
-- =============================================================================
DROP IMAGE REPOSITORY IF EXISTS VSS_DB.VSS_SCHEMA.VSS_IMAGES;

-- =============================================================================
-- DROP ROLE
-- =============================================================================
DROP ROLE IF EXISTS VSS_ROLE;

-- =============================================================================
-- DROP DATABASE (drops schema and all remaining objects)
-- =============================================================================
DROP DATABASE IF EXISTS VSS_DB;
