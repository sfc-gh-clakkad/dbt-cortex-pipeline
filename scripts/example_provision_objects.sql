
-- ============================================================================
-- Database-Level Object Provisioning
--
-- PURPOSE: Creates all database-level objects (schemas, stages, streams)
--          needed by the dbt project.
--
-- EXECUTION: Run with the role that should own these objects (session's
--            primary role). Ensure this role has CREATE DATABASE privileges
--            (or the database already exists).
--
-- Context variables are populated from the yaml file under src/sql/snowflake.yml
-- ============================================================================


-- ============================================================================
-- Create Database-Level Objects
-- ============================================================================

CREATE OR REPLACE DATABASE <% ctx.env.dbt_project_database %>;

-- ----- Schemas -----

CREATE OR REPLACE SCHEMA <% ctx.env.dbt_project_database %>.bronze_zone;

CREATE OR REPLACE SCHEMA <% ctx.env.dbt_project_database %>.silver_zone;
CREATE OR REPLACE SCHEMA <% ctx.env.dbt_project_database %>.gold_zone;
CREATE OR REPLACE SCHEMA <% ctx.env.dbt_project_database %>.dbt_project_deployments;

-- ----- Stages -----

CREATE OR REPLACE STAGE <% ctx.env.dbt_project_database %>.bronze_zone.csv_stage;

CREATE STAGE IF NOT EXISTS <% ctx.env.dbt_project_database %>.bronze_zone.documents
  DIRECTORY = (ENABLE = true)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

CREATE OR REPLACE STAGE <% ctx.env.dbt_project_database %>.gold_zone.agent_specs
  DIRECTORY = (ENABLE = true)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Stage for storing agent specification files with server-side encryption';

-- ----- Streams -----

CREATE OR REPLACE STREAM <% ctx.env.dbt_project_database %>.bronze_zone.documents_stream
  ON STAGE <% ctx.env.dbt_project_database %>.bronze_zone.documents;


PUT file://../cortex_agents/*.yml @<% ctx.env.dbt_project_database %>.gold_zone.agent_specs OVERWRITE=TRUE AUTO_COMPRESS=FALSE;
