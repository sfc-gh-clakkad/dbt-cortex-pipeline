# dbt-cortex-pipeline -- Battle Card

## What It Does

Builds dbt pipelines on Snowflake combining data models with Cortex AI services (Semantic Views, Search, Agents).

## Three Entry Scenarios

| Scenario | Starting Point | Key Action |
|---|---|---|
| **Net New** | No dbt project | Scaffold full medallion architecture |
| **Extension** | Existing dbt project | Add Cortex services on top |
| **DT Migration** | Dynamic Table pipeline | Convert DTs to `materialized='dynamic_table'`, add Cortex |

## Core Capabilities

### Data Modeling (Medallion)
- **Bronze**: Pass-through models; stream-based qualifying views for staged docs
- **Silver**: Incremental with joins, dedup, `AI_EXTRACT` enrichment
- **Gold**: Fact/dimension tables; `AI_PARSE_DOCUMENT` + `SPLIT_TEXT_MARKDOWN_HEADER` chunking

### Cortex AI Services
| Service | Purpose |
|---|---|
| **Semantic View** | Text-to-SQL via `dbt_semantic_view` package |
| **Cortex Search** | Vector search over chunks via dbt macro |
| **Cortex Agent** | Conversational AI (text2sql + search) via YAML spec + macro |
| **Snowflake Intelligence** | Optional agent registration (toggle-controlled) |

### Infrastructure
- **Schemas**: BRONZE_ZONE, SILVER_ZONE, GOLD_ZONE, DBT_PROJECT_DEPLOYMENTS
- **Task DAGs**: CRON refresh, stream-triggered docs, manual Cortex deploy
- **Deployment**: `snow dbt deploy` as Snowflake-native object

### Optional Features
| Feature | Toggle |
|---|---|
| **Iceberg tables** | `iceberg_enabled: true` — gold-layer Iceberg via `catalogs.yml` (dbt-snowflake 1.10+) |
| **Freshness DMFs** | `dmf_freshness_tables` var — macro + view + semantic view metric |
| **Snowflake Intelligence** | `toggle_si_agent_deployment: true` |

## Pre-Scenario Gates

1. External access integration (github.com, codeload.github.com, hub.getdbt.com)
2. Snowflake Intelligence toggle
3. Iceberg toggle (+ external volume, catalog integration, dbt version check)

## Key Guardrails

- **Semantic View syntax**: `table_alias.semantic_name AS physical_column` — semantic LEFT, physical RIGHT
- **Vars audit**: Every `var()`/`dbt.config.get()` must have a default in `dbt_project.yml`
- **`generate_schema_name`**: Must output clean schema names (no target prefix)
- **`READ_STAGE_FILE` UDF**: Must exist in `dbt_project_deployments` before agent deploy
- **Package pinning**: `dbt_semantic_view` version must be pinned
- **Document AI placement**: `AI_EXTRACT` in silver; `AI_PARSE_DOCUMENT` + chunking in gold
- **Deployment**: Must load `dbt-projects-on-snowflake` skill for any `snow dbt` command

## User Checkpoints

1. Semantic View structure
2. `snowflake.yml` configuration
3. Pre-deploy summary
4. Post-deploy confirmation
5. Stream creation permission (if document data)

## Bundled Assets

| Category | Files |
|---|---|
| **Templates** (7) | `example-agent-spec.yml`, `example-catalogs-yml.yml`, `example-dbt-project.yml`, `example-profiles.yml`, `example-snowflake-yml.yml`, `example-document-full-extracts.yml`, `example-document-question-extracts.yml` |
| **Scripts** (9) | `example_provision_objects.sql`, `example_read_stage_file.sql`, `example_create_cortex_agent.sql`, `example_create_document_search_sevice.sql`, `example_deploy_cortex_tasks.sql`, `example_document_full_extracts.sql`, `example_document_question_extracts.py`, `example_semantic_view.sql`, `example_attach_freshness_dmf.sql` |
| **Workflows** (7) | `net-new-patterns.md`, `extension-patterns.md`, `migration-patterns.md`, `semantic-view-patterns.md`, `cortex-agent-patterns.md`, `task-orchestration-patterns.md`, `conventions.md` |

## Relationship to `dbt-projects-on-snowflake`

This skill **designs + builds** the dbt project, then hands off to `dbt-projects-on-snowflake` for **deploy + operate** (`snow dbt deploy/execute`, task scheduling, monitoring).

| User Request | Skill |
|---|---|
| "Build dbt project with Cortex Agent" | `dbt-cortex-pipeline` |
| "Add semantic view to existing dbt project" | `dbt-cortex-pipeline` (Extension) |
| "Convert Dynamic Tables to dbt with Cortex" | `dbt-cortex-pipeline` (Migration) |
| "Deploy/run/schedule/debug dbt project" | `dbt-projects-on-snowflake` |

---

## What This Skill Does NOT Cover

- **Stored procedure migration** (SQL or Python/Snowpark) — extract SELECT logic manually, use Net New or Extension
- **Stream+Task reverse-engineering** — creates tasks for deployment, cannot reverse-engineer existing DAGs
- **Snowpipe migration**
- Standalone Cortex Agent without dbt (`cortex-agent` skill)
- Standalone semantic view SQL without dbt (`semantic-view` skill)
- Debugging existing dbt models
- Deploying already-built projects (`dbt-projects-on-snowflake` skill)
- Single AI function queries without pipeline (`cortex-ai-functions` skill)
