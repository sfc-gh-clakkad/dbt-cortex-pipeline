---
name: dbt-cortex-pipeline
description: >
  Build dbt pipelines on Snowflake with Cortex AI (Semantic Views, Search, Agents).
  Trigger on: dbt with cortex, dbt semantic view/agent, dbt AI pipeline,
  AI_PARSE_DOCUMENT, AI_EXTRACT, cortex search/analyst, convert dynamic tables
  to dbt, scaffold dbt with agent, dbt for structured+unstructured data,
  dbt with iceberg.
  NOT for: standalone cortex agent/semantic view without dbt, debugging dbt models,
  deploying existing dbt projects, single AI function queries, or migrating
  stored procedures/Stream+Task/Snowpipe (only Dynamic Table migration supported).
---

# dbt + Cortex AI Pipeline Skill

## Execution Mode

When running as a subagent or delegated task, minimize file reads:
- Use inline patterns from this file first — they contain all model templates, semantic view syntax, search macro, and validation rules
- Only read reference files when you need exact copy-paste artifacts (see Read Policy below)
- Do NOT read workflow docs (`references/workflows/`) — their content is inlined here

## Cortex Service Creation — Mandatory Copy Rule

**HARD RULE — NO EXCEPTIONS:**
When creating Cortex AI service macros, agent specs, or DDL, you MUST:
1. **Read the corresponding reference file** from the Reference File Read Policy table BEFORE writing any code
2. **Use the reference file as the structural template** — adapt placeholders to the user's domain but do NOT restructure, reorder, or rewrite the pattern
3. **Preserve the exact macro signature, statement flow, and DDL syntax** from the reference

**Prohibited behaviors:**
- Writing `CREATE AGENT`, `CREATE CORTEX SEARCH SERVICE`, `ALTER AGENT`, or any Cortex service DDL from memory or general knowledge
- Changing the macro parameter list, statement execution order, or Jinja patterns (e.g., `call statement` / `load_result` / `run_query` flow)
- Substituting different Snowflake SQL patterns that achieve the same result but differ structurally from the reference
- Inventing DDL clauses, parameters, or syntax not present in the reference files

**If the reference file read fails**, stop and inform the user that the reference file is required. Do NOT proceed by improvising.

## Prerequisites

- Snowflake account with permissions for databases, schemas, tables, views, stages, tasks, UDFs
- `snow` CLI installed and configured
- External access integration for egress to `github.com`, `codeload.github.com`, `hub.getdbt.com`

## Pre-Scenario Step: External Access Integration

**STOP AND ASK** the user for the integration name. Wait for their response before continuing. If none exists, provide the creation SQL below and ask them to confirm it was created before moving on.

```sql
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE NETWORK RULE CONTROL_TOWER.NETWORK.GITHUB_DBT_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('github.com:443', 'hub.getdbt.com:443', 'codeload.github.com:443');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION GITHUB_DBT_ACCESS_INTEGRATION
  ALLOWED_NETWORK_RULES = (CONTROL_TOWER.NETWORK.GITHUB_DBT_NETWORK_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = ()
  ENABLED = TRUE
  COMMENT = 'Access to github.com and hub.getdbt.com';
```

Verify `snow` CLI version supports `--external-access-integration` (`snow --version`).

## Pre-Scenario Step: Snowflake Intelligence Toggle

**STOP AND ASK** the user: "Will this pipeline use Snowflake Intelligence? If yes, provide the SI object name."

- **If yes**: Record SI object name. Set `toggle_si_agent_deployment: true`, `snowflake_intelligence_object: '<name>'`.
- **If no** (default): `toggle_si_agent_deployment: false`.

## Pre-Scenario Step: Iceberg Table Format Toggle

**STOP AND ASK** the user: "Will this pipeline use Iceberg table format? If yes, I'll need the external volume name, catalog integration name, and confirmation that dbt-snowflake 1.10+ is installed."

- **If yes**: Collect:
  - **External volume** (must exist). Example:

    ```sql
    CREATE OR REPLACE EXTERNAL VOLUME MY_EXTERNAL_VOLUME
      STORAGE_LOCATIONS = (
        (
          NAME = 'my-s3-location'
          STORAGE_BASE_URL = 's3://<bucket>/<path>/'
          STORAGE_PROVIDER = 'S3'
          STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<account_id>:role/<role_name>'
        )
      );
    ```

  - **Catalog integration** (must exist). Example:

    ```sql
    CREATE OR REPLACE CATALOG INTEGRATION MY_ICEBERG_CATALOG_INT
      CATALOG_SOURCE = SNOWFLAKE
      TABLE_FORMAT = ICEBERG
      ENABLED = TRUE;
    ```

  - **dbt version check** — dbt-snowflake **1.10+** required: `pip show dbt-snowflake | grep Version`

  Set `iceberg_enabled: true`, `iceberg_catalog_name: '<name>'`.

- **If no** (default): `iceberg_enabled: false`, `iceberg_catalog_name: ''`.

## Pre-Scenario Confirmation Gate

**HARD GATE — DO NOT PROCEED PAST THIS POINT WITHOUT USER CONFIRMATION.**

Before entering any scenario, you MUST:

1. **Present a summary of all collected inputs** to the user in a structured format:

   ```
   === Confirmed Inputs ===
   External Access Integration: <name or "needs creation">
   Snowflake Intelligence: <enabled/disabled> [object name if enabled]
   Iceberg Table Format: <enabled/disabled> [ext volume, catalog integration, dbt version if enabled]
   Detected Scenario: <Net New / Extension / Migration>
   ```

2. **Ask the user to explicitly confirm** these inputs are correct before proceeding.

3. **If any input is missing or unclear**, ask for it now. Do NOT assume defaults without stating them and getting confirmation.

4. **Do NOT begin any scenario step** (scaffolding, model creation, etc.) until the user replies with confirmation.

**Why this matters:** Incorrect inputs propagate through the entire pipeline — wrong integration names break deployment, wrong Iceberg settings produce invalid configs, wrong scenario selection wastes all downstream work.

## Scenario Detection

| Scenario           | Workflow                                                     |
| ------------------ | ------------------------------------------------------------ |
| **Net New** — No existing dbt project        | [Scenario 1](#scenario-1-net-new)                      |
| **Extension** — Existing dbt project in a local repo      | [Scenario 2](#scenario-2-extension)                    |
| **Migration (DT)** — Existing Dynamic Table pipeline | [Scenario 3](#scenario-3-dynamic-table-migration)      |

If unclear, ask the user which applies.

### Unsupported Migration Types — Early Exit

If the user's request involves migrating any of these, **stop and inform them**:

| Source Object | Signals | Action |
|---|---|---|
| **SQL Stored Procedures** | "stored procedure", "sproc", "CALL", "SHOW PROCEDURES" | Not covered. Suggest extracting SELECT logic from INSERT/MERGE/CREATE TABLE AS, then use Net New or Extension. |
| **Python/Snowpark Procedures** | "python procedure", "session.table()", "save_as_table()" | Not covered. Suggest manual conversion, then use this skill for Cortex AI layer. |
| **Stream+Task pipelines** | "stream and task pipeline" as orchestration source | This skill creates tasks for deployment but cannot reverse-engineer existing Stream+Task DAGs. |
| **Snowpipe** | "snowpipe", "CREATE PIPE", "auto_ingest" | Not covered. |

Do NOT improvise migration workflows for unsupported types — no patterns exist in reference files.

---

## Scenario 1: Net New

> **GATE — BLOCKED UNTIL CONFIRMED:** Do NOT execute any step below until:
> 1. All pre-scenario steps are complete
> 2. The Pre-Scenario Confirmation Gate summary has been presented to the user
> 3. The user has explicitly confirmed the inputs
>
> If you have not done this, STOP NOW and go back to the Pre-Scenario Confirmation Gate.

### Step 1: Gather Data Source Context

Collect:
- **Tables/views**: names, schemas, databases, columns. Run `SHOW TABLES`/`DESCRIBE TABLE` if user points to a schema.
- **Relationships**: PKs, FKs, join patterns.
- **Staged files**: PDFs/docs on a Snowflake stage? Path and formats?
- **Unstructured text columns**: If no staged files, ask if any source column has free text (descriptions, notes, etc.). Record table+column.
- **Business questions**: What should the Cortex Agent answer? Informs semantic view design.

Read any requirements documents the user provides.

**Cortex Search eligibility:**

| Signal | Search? | Action |
|---|---|---|
| Staged files (PDF, DOCX, etc.) | Yes | Build doc processing pipeline + search service |
| No files, but unstructured text column | Yes | Surface column through gold model + search service |
| No unstructured data | No | Agent uses `cortex_analyst_text_to_sql` only |

### Step 2: Scaffold the dbt Project

Create these files (use `references/templates/` for full examples if needed):

1. **dbt_project.yml** — from `references/templates/example-dbt-project.yml`. Configure medallion zones, `vars` for stage paths/doc parsing.
2. **profiles.yml** — from `references/templates/example-profiles.yml`. No `password` or `env_var()`. Use the user's current role and warehouse (from `SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE()`) as defaults rather than placeholder values.
3. **packages.yml** — from `references/templates/example-packages.yml`. Must include `Snowflake-Labs/dbt_semantic_view`, pinned.
4. **macros/generate_schema_name.sql**:
   ```sql
   {% macro generate_schema_name(custom_schema_name, node) -%}
     {%- set default_schema = target.schema -%}
     {%- if custom_schema_name is none -%}{{ default_schema }}
     {%- else -%}{{ custom_schema_name | trim }}{%- endif -%}
   {%- endmacro %}
   ```
5. **models/sources.yml** — standard dbt sources.
6. **catalogs.yml** (if Iceberg) — from `references/templates/example-catalogs-yml.yml`. Add `+catalog` to gold-zone config.

**Vars audit:** Every `var()`/`dbt.config.get()` must have a default in `dbt_project.yml`. Known vars:

| var name | default | used by |
|---|---|---|
| `docs_stage_path` | `'@<DATABASE>.<SCHEMA>.DOCUMENTS'` | `document_full_extracts.sql`, `document_question_extracts.py` |
| `supported_doc_formats` | `['pdf', 'docx', ...]` | `v_qualify_new_documents` (bronze) |
| `parse_mode` | `"LAYOUT"` | `document_full_extracts.sql` |
| `page_split` | `true` | `document_full_extracts.sql` |
| `max_chunk_size` | `500` | `document_full_extracts.sql` |
| `max_chunk_depth` | `5` | `document_full_extracts.sql` |
| `snowflake_intelligence_object` | `'SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT'` | `create_cortex_agent.sql` |
| `toggle_si_agent_deployment` | `false` | `create_cortex_agent.sql` |
| `dmf_freshness_tables` | `[]` (populate with all gold-zone table names) | `data_freshness_checks.sql`, `attach_freshness_dmf` macro |
| `iceberg_enabled` | `false` | gold-zone model configs, `catalogs.yml` generation |
| `iceberg_catalog_name` | `''` | gold-zone `+catalog` config |

If no unstructured documents, remove doc-related vars (`docs_stage_path`, `supported_doc_formats`, `parse_mode`, `page_split`, `max_chunk_size`, `max_chunk_depth`).

### Step 3: Create Bronze-Layer Models

One model per source table. `materialized: table`, tagged `['daily']`.

```sql
-- models/bronze_zone/<entity>.sql
{{ config(materialized='table', description='Raw <entity> data', tags=['daily']) }}
SELECT column_1, column_2, column_n
FROM {{ source('<source_name>', '<TABLE_NAME>') }}
```

For document stage data, verify stream exists (`SHOW STREAMS IN SCHEMA <DB>.<SCHEMA>;`).
If missing, ask permission then create:
```sql
ALTER STAGE IF EXISTS <DB>.<SCHEMA>.<STAGE> SET DIRECTORY = (ENABLE = TRUE);
ALTER STAGE <DB>.<SCHEMA>.<STAGE> REFRESH;
CREATE STREAM IF NOT EXISTS <DB>.<SCHEMA>.<STREAM> ON STAGE <DB>.<SCHEMA>.<STAGE>;
```

Then create qualifying view (bronze, `materialized: view`, tagged `document_processing`) filtering by `supported_doc_formats` var, `METADATA$ACTION != 'DELETE'`, `size > 0`.

**CHECKPOINT:** Ask permission before creating a stream.

### Step 4: Create Silver-Layer Models

Joins, dedup, AI enrichment. Tag `['daily']` or `['document_processing']`.

```sql
-- models/silver_zone/enriched_<entity>.sql
{{ config(materialized='incremental', incremental_strategy='merge', unique_key='<pk>',
          merge_update_columns=['updated_at', '<other_cols>'], tags=['daily']) }}
SELECT a.<pk>, a.col1, b.lookup_val,
       DATEDIFF('hour', a.created_at, a.resolved_at) AS resolution_hours
FROM {{ ref('<bronze_model>') }} a
LEFT JOIN {{ ref('<other_model>') }} b ON a.fk = b.pk
{% if is_incremental() %}
WHERE a.updated_at > (SELECT COALESCE(MAX(updated_at), DATEADD('day', -1, CURRENT_TIMESTAMP())) FROM {{ this }})
{% endif %}
```

For documents: use `AI_EXTRACT` here (not `AI_PARSE_DOCUMENT` — that's gold).
Python model template: `scripts/example_document_question_extracts.py`. Schema YAML: `references/templates/example-document-question-extracts.yml`.

### Step 5: Create Gold-Layer Models

Business-ready tables. `materialized: table`, tagged `['daily']`.

```sql
-- models/gold_zone/<entity>.sql
{{ config(materialized='table', tags=['daily']) }}
SELECT e.<pk>, e.dimension_1, e.measure_1,
       CASE WHEN e.status = 'resolved' THEN 'closed' ELSE e.status END AS normalized_status,
       e.created_at, e.updated_at
FROM {{ ref('<silver_model>') }} e
```

- For documents: `AI_PARSE_DOCUMENT` + `SPLIT_TEXT_MARKDOWN_HEADER` chunking model (`incremental`, append-only, tagged `document_processing`). See `scripts/example_document_full_extracts.sql` for exact SQL.
- **Freshness**: Create `attach_freshness_dmf` macro (from `scripts/example_attach_freshness_dmf.sql`), plus this view:
  ```sql
  -- models/gold_zone/data_freshness_checks.sql
  {{ config(materialized='view', tags=['data_freshness_checks']) }}
  SELECT SCHEDULED_TIME, MEASUREMENT_TIME, TABLE_DATABASE, TABLE_SCHEMA,
         TABLE_NAME, METRIC_NAME, VALUE
  FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
  WHERE UPPER(TABLE_NAME) IN ({{ var('dmf_freshness_tables') }})
    AND UPPER(METRIC_NAME) LIKE '%FRESHNESS%'
  ORDER BY MEASUREMENT_TIME DESC
  ```
  Apply freshness as post-hook: `{{ config(post_hook="{{ attach_freshness_dmf(schedule='TRIGGER_ON_CHANGES') }}") }}`
- **Iceberg** (if enabled): `+catalog` at gold-zone level handles it — no per-model config needed.

### Step 6: Create the Semantic View

Build `models/semantic_views/<view_name>.sql` over gold zone tables. Requires `Snowflake-Labs/dbt_semantic_view`.

**CRITICAL:** Syntax is `table_alias.semantic_name AS physical_column` — semantic on LEFT, physical on RIGHT. Reversing breaks Cortex Analyst.

Rules:
- Use `{{ ref() }}` for all table references; use the alias consistently across clauses
- Relationship naming: `<child>_to_<parent>`
- Add SYNONYMS only on the primary table when multiple tables share a dimension
- FACTS = raw numeric columns; METRICS = computed expressions
- Use COMMENT to list valid values for fixed-value columns

Minimal example:
```sql
{{ config(materialized='semantic_view') }}
TABLES(
  orders as {{ ref('orders') }} PRIMARY KEY(order_id) COMMENT = 'Customer orders'
  , customers as {{ ref('customers') }} PRIMARY KEY(customer_id) COMMENT = 'Customer directory'
)
RELATIONSHIPS (
  orders_to_customers AS orders (customer_id) REFERENCES customers (customer_id)
)
FACTS (
  orders.total_amount AS total_amount COMMENT = 'Order total in USD'
)
METRICS (
  data_freshness_summary AS data_freshness_checks.table_name || ' last updated '
    || data_freshness_checks.value || ' seconds ago'
    WITH SYNONYMS = ('data freshness', 'last updated')
)
DIMENSIONS (
  orders.status AS status WITH SYNONYMS = ('order status') COMMENT = 'Valid values: pending, shipped, delivered'
  , customers.plan_tier AS plan_tier WITH SYNONYMS = ('plan', 'subscription') COMMENT = 'Valid values: free, starter, pro, enterprise'
)
```

Include `data_freshness_checks` in `TABLES()` and add freshness summary metric. See `scripts/example_semantic_view.sql` for a larger multi-table example.

**CHECKPOINT:** Present semantic view to user for review.

### Step 7: Create Cortex Search Macro (if applicable)

> **GATE — MANDATORY READ:** Before writing ANY search service code, you MUST read `scripts/example_create_document_search_sevice.sql`. Use its exact macro structure. Adapt only the model name in `{{ ref() }}`, the `ATTRIBUTES` list, and the `SELECT` columns to match the user's schema. Do NOT write the macro from memory.

Driven by Cortex Search eligibility from Step 1.

- **Staged files**: Doc processing models (Steps 3-5) produce chunk column. Use it as `search_column`.
- **Unstructured text column**: Ensure gold model surfaces it. Create search service macro.
- **No unstructured data**: Skip this step.

Macro template (`macros/create_cortex_search_service.sql`):
```sql
{% macro create_document_search_service(service_name, search_wh, search_column, target_lag, embedding_model) %}
{% set sql %}
    CREATE OR REPLACE CORTEX SEARCH SERVICE {{ target.database }}.GOLD_ZONE.{{ service_name }}
      ON {{ search_column }}
      ATTRIBUTES RELATIVE_PATH, EXTENSION
      WAREHOUSE = {{ search_wh }}
      TARGET_LAG = '{{ target_lag }}'
      EMBEDDING_MODEL = '{{ embedding_model }}'
    AS (
      SELECT CHUNK, RELATIVE_PATH, EXTENSION
      FROM {{ ref('<your_chunk_model>') }}
    );
{% endset %}
{% do run_query(sql) %}
{% endmacro %}
```

Customize `ATTRIBUTES` (add `CATEGORY` etc.) and `AS (SELECT ...)` source for your chunked model.

**POST-STEP VALIDATION — Search Macro:** Before proceeding, verify:
- [ ] You read `scripts/example_create_document_search_sevice.sql` before writing the macro
- [ ] The macro signature matches the reference: `create_document_search_service(service_name, search_wh, search_column, target_lag, embedding_model)`
- [ ] The DDL uses `CREATE OR REPLACE CORTEX SEARCH SERVICE` with `ON`, `ATTRIBUTES`, `WAREHOUSE`, `TARGET_LAG`, `EMBEDDING_MODEL`, and `AS (SELECT ...)` — no invented clauses
- [ ] The macro uses `{% set sql %}...{% endset %}` then `{% do run_query(sql) %}` — not a different execution pattern

### Step 8: Create Cortex Agent Macro + Spec

> **GATE — MANDATORY READ:** Before writing ANY agent macro or spec code:
> 1. Read `scripts/example_create_cortex_agent.sql` — use its exact macro structure
> 2. Read `references/templates/example-agent-spec.yml` — use its exact YAML structure
>
> Do NOT write these artifacts from memory. The macro uses a specific `call statement` / `load_result` / `run_query` flow and a `$$` delimiter pattern that MUST be preserved exactly.

1. Ensure `READ_STAGE_FILE` UDF exists in `dbt_project_deployments` (create from `scripts/example_read_stage_file.sql` if missing).
2. Create `macros/create_cortex_agent.sql` — idempotent create/alter macro. Copy from `scripts/example_create_cortex_agent.sql`. **Indentation gotcha:** `{{ agent_spec['data'][0][0] }}` must start at column 0 (no leading whitespace) inside `$$` delimiters — Jinja indentation breaks YAML parsing.
3. Create `cortex_agents/<agent_name>.yml` from `references/templates/example-agent-spec.yml`. Customize:
   - `models.orchestration` — LLM model name
   - `instructions.orchestration` — role, tool selection logic, domain context, boundaries
   - `tools` — include `cortex_analyst_text_to_sql`; add `cortex_search` only if search service exists
   - `tool_resources` — fully qualified semantic view and search service names

**Instruction writing tips:**
- Explicit tool selection: list question patterns and which tool handles them
- Valid filter values: if semantic view has fixed values, list them
- Multi-tool workflows: spell out the sequence when both tools needed
- Boundaries: state what the agent cannot do
- Domain context: entity types, categories, lifecycle states, metrics

**Stage the spec:**
```sql
CREATE STAGE IF NOT EXISTS <DATABASE>.gold_zone.agent_specs;
PUT file://<local_path>/cortex_agents/<spec>.yml @<DATABASE>.gold_zone.agent_specs/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
```

When no document data: omit `cortex_search` tool entry, its `tool_resources` entry, and search-related instructions from the spec.

**POST-STEP VALIDATION — Agent Macro + Spec:** Before proceeding, verify:
- [ ] You read `scripts/example_create_cortex_agent.sql` and `references/templates/example-agent-spec.yml` before writing
- [ ] The macro uses the exact `call statement('agent_spec_builder')` → `load_result('agent_spec_builder')` → `call statement('agent_exists')` → `load_result('agent_exists')` → `set cortex_agent_ddl` → `run_query(cortex_agent_ddl)` flow
- [ ] `{{ agent_spec['data'][0][0] }}` starts at column 0 (no leading whitespace) inside `$$` delimiters
- [ ] The agent spec YAML follows the structure from `example-agent-spec.yml`: `models`, `orchestration.budget`, `instructions.response`, `instructions.orchestration`, `tools[]`, `tool_resources`
- [ ] `tools[].tool_spec.name` entries match `tool_resources` keys exactly
- [ ] No Cortex DDL syntax was invented (e.g., no made-up clauses or parameters)

### Step 9: Create Schema YAML Files

One `.yml` per model: description, columns, tests (`not_null`, `unique`, `accepted_values`).

### Step 10: Deploy

**CHECKPOINT:** Confirm readiness. Summarize models, macros, Cortex services.
**You MUST now proceed to [Final Step](#final-step-all-scenarios-generate-deployment-sql).** The pipeline is not complete until the infrastructure SQL is generated and the user is guided through dbt project deployment.

---

## Scenario 2: Extension

> **GATE — BLOCKED UNTIL CONFIRMED:** Do NOT execute any step below until:
> 1. All pre-scenario steps are complete
> 2. The Pre-Scenario Confirmation Gate summary has been presented to the user
> 3. The user has explicitly confirmed the inputs
>
> If you have not done this, STOP NOW and go back to the Pre-Scenario Confirmation Gate.

### Step 1: Explore the Existing Project

Use `fdbt` to explore:
```
fdbt info                     # Project name, version, profile
fdbt list                     # All models with materializations
fdbt lineage <model> -u       # Upstream deps
fdbt tests coverage           # Test coverage
```

Read `dbt_project.yml`, `packages.yml`, `macros/`, scan `models/`.

Identify: top data layer, naming conventions, materializations, text/chunk models, schema layout.

**Top-layer detection:**

| Convention | Directory |
|---|---|
| Medallion | `gold_zone/`, `gold/` |
| dbt best practice | `marts/` |
| Presentation | `presentation/`, `analytics/`, `reporting/` |

**Text chunk detection** — scan for chunk-like columns: `chunk`, `text_chunk`, `content_chunk`, `extract`, `body`, `text_content`, `document_text`, `page_text` → Cortex Search candidates.

### Step 2: Identify Top-Layer Models

Find the most refined models (gold/marts/analytics). Read SQL to understand columns, joins, relationships — these feed the semantic view.

**Infer FACTS** from column patterns: `*_amount`, `*_total`, `*_count`, `*_qty`, `*_hours`, `*_duration`, `*_rate`, `*_score`, `revenue`, `cost`, `price`, `profit`.

**Infer DIMENSIONS** from: `*_id`, `*_key`, `*_name`, `*_type`, `*_category` (+SYNONYMS), `*_status`, `*_state` (+SYNONYMS), `*_date`, `*_at`, `*_timestamp` (+temporal SYNONYMS), `*_flag`, `is_*`, `has_*`.

**Infer RELATIONSHIPS** from joins: `LEFT JOIN` → `many_to_one`. Format: `a_to_b AS table_a (fk_col) REFERENCES table_b (pk_col)`.

### Step 3: Add Prerequisites

1. Create/update `packages.yml` from `references/templates/example-packages.yml`. Must include `Snowflake-Labs/dbt_semantic_view`, pinned.
2. Add `semantic_views` section to `dbt_project.yml`.
3. Ensure `generate_schema_name` macro produces clean names (see Scenario 1 Step 2 for template).

**Vars audit:** Same as Scenario 1 Step 2 — cross-reference all `var()` calls.

**Preserve existing conventions:**

| Aspect | Rule |
|---|---|
| Naming | Follow existing prefix pattern (`stg_`, `int_`, `fct_`, `dim_`) |
| Materialization | Keep existing strategy |
| Tags | Use existing vocabulary |
| Schema files | Match existing `.yml` pattern |

Also add: `attach_freshness_dmf` macro, `data_freshness_checks` view, `dmf_freshness_tables` var (see Scenario 1 Step 5).

If Iceberg enabled: create `catalogs.yml`, add `+catalog` to gold-zone config.

### Step 4: Create the Semantic View

Same as Scenario 1 Step 6, referencing top-layer models from Step 2.

**CRITICAL:** `table_alias.semantic_name AS physical_column` — semantic LEFT, physical RIGHT.

**CHECKPOINT:** Present to user for review.

### Step 5: Create Cortex Search Macro (if applicable)

> **GATE — MANDATORY READ:** Same as Scenario 1 Step 7. You MUST read `scripts/example_create_document_search_sevice.sql` before writing any search service code. Do NOT write from memory.

Same eligibility logic as Scenario 1 Step 7, but inspect existing models for chunk columns.

### Step 6: Create Cortex Agent Macro + Spec

> **GATE — MANDATORY READ:** Same as Scenario 1 Step 8. You MUST read `scripts/example_create_cortex_agent.sql` and `references/templates/example-agent-spec.yml` before writing any agent code. Do NOT write from memory.

Same as Scenario 1 Step 8. Infer domain context from existing models.

### Step 7: Deploy

**CHECKPOINT:** Confirm readiness.
**You MUST now proceed to [Final Step](#final-step-all-scenarios-generate-deployment-sql).** The pipeline is not complete until the infrastructure SQL is generated and the user is guided through dbt project deployment.

---

## Scenario 3: Dynamic Table Migration

> **GATE — BLOCKED UNTIL CONFIRMED:** Do NOT execute any step below until:
> 1. All pre-scenario steps are complete
> 2. The Pre-Scenario Confirmation Gate summary has been presented to the user
> 3. The user has explicitly confirmed the inputs
>
> If you have not done this, STOP NOW and go back to the Pre-Scenario Confirmation Gate.

### Step 1: Discover Dynamic Tables

See `references/workflows/migration-patterns.md`.

Ask if SQL is in a local repo. If not, query Snowflake:

```sql
SHOW DYNAMIC TABLES IN SCHEMA <database>.<schema>;
SELECT GET_DDL('DYNAMIC_TABLE', '<database>.<schema>.<table_name>');
```

Capture: table name, SQL body, TARGET_LAG, upstream dependencies.

### Step 2: Map Lineage DAG

- No DT refs in FROM → **bronze**
- Transforms other DTs → **silver**
- Terminal/leaf nodes → **gold**

Use `DYNAMIC_TABLE_GRAPH_HISTORY()` if available.

### Step 3: Scaffold dbt Project

Same as Scenario 1 Step 2.

### Step 4: Convert Each DT to a dbt Model

Lift-and-shift with `materialized='dynamic_table'`. Per DT:
1. Place in appropriate zone
2. Replace hardcoded refs with `ref()`/`source()`
3. `config(materialized='dynamic_table', target_lag='<original>', snowflake_warehouse='<wh>')`
4. Add `-- Migrated from: DT_<original_name>` comment

See `migration-patterns.md` for config reference and `on_configuration_change` options.

**Iceberg:** Gold-zone DTs pick up `+catalog` from `dbt_project.yml` automatically.
**Freshness:** DMFs apply to `dynamic_table` same as `table`/`incremental`. Include gold-zone DT names in `dmf_freshness_tables`.

### Steps 5-8: Cortex Services + Deploy

> **GATE — MANDATORY READ:** Before creating Cortex services, you MUST read the reference files:
> - `scripts/example_create_document_search_sevice.sql` (for search macro)
> - `scripts/example_create_cortex_agent.sql` (for agent macro)
> - `references/templates/example-agent-spec.yml` (for agent spec YAML)
>
> Do NOT write these artifacts from memory. Use the exact structural patterns from the reference files.

Follow Scenario 1 Steps 6-10. All checkpoints apply. See `task-orchestration-patterns.md` for scheduling.
**You MUST then proceed to [Final Step](#final-step-all-scenarios-generate-deployment-sql).** The pipeline is not complete until the infrastructure SQL is generated and the user is guided through dbt project deployment.

---

## Final Step (All Scenarios): Generate Deployment SQL

> **GATE — MANDATORY COMPLETION:** This section MUST be completed. Do NOT stop after scaffolding code — the agent must generate the infrastructure SQL file and guide the user through dbt project deployment.
>
> **Do NOT skip any substep.** Generate the infrastructure deployment file, then guide the user through dbt project deployment with the `dbt-projects-on-snowflake` skill.

### 1. Configure `snowflake.yml`

> **GATE — MANDATORY READ:** Read `references/templates/example-snowflake-yml.yml` before writing. Use its exact structure.

From `references/templates/example-snowflake-yml.yml`. Populate database, warehouse, role. Use the user's current role and warehouse (from `SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE()`) as defaults for `dbt_pipeline_wh` and any role references rather than placeholder values.

**CHECKPOINT:** Present `snowflake.yml` for review. Wait for user confirmation before continuing.

### 2. Generate the Deployment SQL File

> **GATE — MANDATORY READ:** Read `scripts/example_provision_objects.sql`, `scripts/example_read_stage_file.sql`, `references/workflows/task-orchestration-patterns.md`, and `scripts/example_deploy_cortex_tasks.sql` before generating. Use the exact patterns from these reference files.

Generate a `deploy.sql` file containing all SQL required to provision Snowflake infrastructure for the pipeline. This file does **NOT** include dbt project creation — that is handled separately via `snow dbt deploy` (see Step 4 below). The file MUST include the following sections **in this order**, each separated by a section header comment:

#### Section 1: Header & Privileges

Include a block comment at the top documenting:
- Purpose of the file
- Required privileges for the executing role:
  - `CREATE DATABASE` (or ownership of an existing database)
  - `CREATE SCHEMA` on the target database
  - `CREATE STAGE`, `CREATE STREAM` on target schemas
  - `CREATE FUNCTION` on `DBT_PROJECT_DEPLOYMENTS` schema
  - `CREATE TASK` on `DBT_PROJECT_DEPLOYMENTS` schema
  - `USAGE` on the warehouse
  - `USAGE` on the external access integration
- Execution instructions: `snow sql -f deploy.sql` (via Snowflake CLI) or paste into a Snowflake worksheet
- Note that the executing role will own all created objects

#### Section 2: Database & Schema Provisioning

Generate from the pattern in `scripts/example_provision_objects.sql`:
- `CREATE OR REPLACE DATABASE`
- `CREATE OR REPLACE SCHEMA` for BRONZE_ZONE, SILVER_ZONE, GOLD_ZONE, DBT_PROJECT_DEPLOYMENTS
- Stage definitions (csv_stage, documents, agent_specs)
- Stream definition (documents_stream)

#### Section 3: READ_STAGE_FILE UDF

Generate from `scripts/example_read_stage_file.sql`:
- `CREATE OR REPLACE FUNCTION` in the `DBT_PROJECT_DEPLOYMENTS` schema
- Use fully qualified name: `<DATABASE>.DBT_PROJECT_DEPLOYMENTS.READ_STAGE_FILE`

#### Section 4: Upload Agent Spec

- `PUT` command to upload agent spec YAML to the agent_specs stage

#### Section 5: Task DAGs

Generate from patterns in `references/workflows/task-orchestration-patterns.md` and `scripts/example_deploy_cortex_tasks.sql`. Include up to 3 DAGs:

1. **DAG 1: Scheduled Refresh** — CRON → compile → `run --select tag:daily`
2. **DAG 2: Stream-Triggered Docs** (if documents) — `SYSTEM$STREAM_HAS_DATA` → `run --select tag:document_processing`
3. **DAG 3: Manual Cortex Deploy** — `EXECUTE TASK root_deploy_cortex` → semantic view + search + agent in parallel

Parameterize using `snowflake.yml` env vars (via `<% ctx.env.* %>` templating).

#### Section 6: Task Lifecycle — Resume

Do **NOT** include `ALTER TASK ... RESUME` statements in `deploy.sql`. Tasks should be created in a suspended state. The user will resume them manually when ready. Add a comment block reminding the user how to resume tasks in child-first order, for example:
```sql
-- NOTE: Tasks are created in SUSPENDED state. To activate, resume in child-first order:
-- ALTER TASK <child_task> RESUME;
-- ALTER TASK <root_task> RESUME;
```

#### Section 7: Verification Queries (commented out)

Include commented-out verification queries the user can run after execution:
```sql
-- SHOW SCHEMAS IN DATABASE <DATABASE>;
-- SHOW STAGES IN SCHEMA <DATABASE>.BRONZE_ZONE;
-- SHOW FUNCTIONS LIKE 'READ_STAGE_FILE' IN SCHEMA <DATABASE>.DBT_PROJECT_DEPLOYMENTS;
-- SHOW TASKS IN SCHEMA <DATABASE>.DBT_PROJECT_DEPLOYMENTS;
```

If Iceberg is enabled, also include:
```sql
-- SHOW EXTERNAL VOLUMES LIKE '<name>';
-- SHOW CATALOG INTEGRATIONS LIKE '<name>';
```

### 3. Present Infrastructure SQL to User (Step 1 of 2)

**CHECKPOINT:** Present the generated `deploy.sql` file for review. This file provisions all Snowflake infrastructure objects — it does **NOT** create the dbt project itself. The dbt project deployment is a separate step (Step 2 below).

Alongside the file, provide:

1. **Execution instructions:**
   - Via Snowflake CLI: `snow sql -f deploy.sql`
   - Via Snowflake worksheet: paste and run in order
   - Ensure the session role has the privileges listed in the file header

2. **Pre-execution checklist:**
   - [ ] `snowflake.yml` was created and reviewed
   - [ ] The executing role has the required privileges (see file header)
   - [ ] External access integration exists (if using Cortex services)
   - [ ] External volume and catalog integration exist (if Iceberg enabled)

3. **Post-execution verification:**
   - Uncomment and run the verification queries in Section 7
   - Confirm `SHOW TASKS` shows all tasks in a `started` state

**Wait for the user to confirm `deploy.sql` executed successfully before proceeding to Step 2.**

### 4. Deploy dbt Project to Snowflake (Step 2 of 2)

> **GATE — BLOCKED UNTIL STEP 1 CONFIRMED:** Do NOT proceed until the user confirms `deploy.sql` ran successfully.

After the infrastructure is provisioned, guide the user to deploy the dbt project using the **`dbt-projects-on-snowflake`** skill. This skill handles project validation, upload via `snow dbt deploy`, and verification.

**Instructions to the user:**

Present the following deployment summary and ask them to proceed:

```
=== dbt Project Deployment ===
Project path: <path_to_dbt_project>
Target database: <DATABASE>
Target schema: DBT_PROJECT_DEPLOYMENTS
External access integration: <INTEGRATION_NAME>

To deploy, run:
  snow dbt deploy <project_name> \
    --source <path_to_dbt_project> \
    --database <DATABASE> \
    --schema DBT_PROJECT_DEPLOYMENTS \
    --external-access-integration <INTEGRATION_NAME>

To verify:
  snow dbt list --in schema DBT_PROJECT_DEPLOYMENTS --database <DATABASE>
```

**If the user needs help with deployment** (e.g., profiles.yml issues, version management, external access setup), invoke the `dbt-projects-on-snowflake` skill which provides guided workflows for:
- Validating `profiles.yml` (no `env_var()` or `password` fields)
- Handling external access integration requirements
- Deploying and verifying the project
- Managing project versions

**Post-deployment verification:**
```sql
SHOW DBT PROJECTS IN SCHEMA <DATABASE>.DBT_PROJECT_DEPLOYMENTS;
SHOW VERSIONS IN DBT PROJECT <DATABASE>.DBT_PROJECT_DEPLOYMENTS.<project_name>;
```

Wait for user confirmation that the dbt project is deployed before marking the pipeline complete.

---

## Reference File Read Policy

Read ONLY when you need exact syntax not available inline above:

| When you need... | Read this file |
|---|---|
| Agent spec YAML template | `references/templates/example-agent-spec.yml` |
| Agent macro (full Jinja) | `scripts/example_create_cortex_agent.sql` |
| Python AI_EXTRACT model | `scripts/example_document_question_extracts.py` |
| Document chunking SQL | `scripts/example_document_full_extracts.sql` |
| Task DAG SQL | `scripts/example_deploy_cortex_tasks.sql` |
| Database provisioning script | `scripts/example_provision_objects.sql` |
| READ_STAGE_FILE UDF | `scripts/example_read_stage_file.sql` |
| packages.yml template | `references/templates/example-packages.yml` |
| dbt_project.yml template | `references/templates/example-dbt-project.yml` |
| profiles.yml template | `references/templates/example-profiles.yml` |
| catalogs.yml template | `references/templates/example-catalogs-yml.yml` |
| Schema YAML examples | `references/templates/example-document-full-extracts.yml`, `example-document-question-extracts.yml` |
| snowflake.yml template | `references/templates/example-snowflake-yml.yml` |
| DT migration patterns | `references/workflows/migration-patterns.md` (Scenario 3 only) |
| Task orchestration patterns | `references/workflows/task-orchestration-patterns.md` (deploy step only) |
