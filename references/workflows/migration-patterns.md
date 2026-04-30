# Migration Patterns

Dynamic Table → dbt migration patterns.

## Dynamic Table Discovery

```sql
SHOW DYNAMIC TABLES IN SCHEMA <database>.<schema>;
SELECT GET_DDL('DYNAMIC_TABLE', '<database>.<schema>.<table_name>');

-- Refresh config and dependencies
SELECT name, target_lag, refresh_mode, scheduling_state, text AS transformation_sql
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_GRAPH_HISTORY())
WHERE schema_name = '<SCHEMA>';
```

## Parse DDL — Extract per DT:

1. **Table name** → dbt model name
2. **SELECT body** → model SQL
3. **TARGET_LAG** → `target_lag` config
4. **WAREHOUSE** → `snowflake_warehouse` config
5. **Source references** → `ref()`/`source()` candidates

## `dynamic_table` Materialization

Lift-and-shift: keep SELECT + refresh semantics, replace hardcoded refs.

Original:
```sql
CREATE OR REPLACE DYNAMIC TABLE DB.SCHEMA.DT_USER_SESSIONS
  TARGET_LAG = '1 hour'
  WAREHOUSE = my_wh
AS
SELECT session_id, user_id, MIN(timestamp) AS session_start,
       MAX(timestamp) AS session_end, COUNT(*) AS event_count
FROM DB.SCHEMA.DT_RAW_EVENTS
GROUP BY session_id, user_id;
```

Converted:
```sql
-- models/silver_zone/user_sessions.sql
{{ config(materialized='dynamic_table', target_lag='1 hour', snowflake_warehouse='my_wh') }}
-- Migrated from: DT_USER_SESSIONS

SELECT session_id, user_id, MIN(timestamp) AS session_start,
       MAX(timestamp) AS session_end, COUNT(*) AS event_count
FROM {{ ref('raw_events') }}
GROUP BY session_id, user_id
```

### Config Reference

| Key | Description |
|---|---|
| `target_lag` | From original DT (`'1 hour'`, `'1 day'`, `'downstream'`) |
| `snowflake_warehouse` | From original DT |
| `on_configuration_change` | `'apply'` (ALTER in place), `'continue'` (warn, safe default), `'fail'` (error on drift) |

## Zone Mapping

| Level | Zone |
|---|---|
| Level 0 (base tables, no DT deps) | bronze_zone |
| Level 1+ (transforms DTs) | silver_zone |
| Terminal (no downstream DTs) | gold_zone |

If only 2 levels deep, skip silver → bronze → gold.

### TARGET_LAG by Zone

| Zone | Typical | Rationale |
|---|---|---|
| Bronze | `'downstream'` | Refresh on demand |
| Silver | `'downstream'` | Refresh when gold needs it |
| Gold | Original lag | Business refresh SLA |

## Reference Replacement

| Original | Replacement |
|---|---|
| `DB.SCHEMA.DT_<name>` | `{{ ref('<model_name>') }}` |
| `DB.SCHEMA.<base_table>` | `{{ source('<source_name>', '<table>') }}` |

## Text Chunk Detection

Look for DTs calling `SPLIT_TEXT_MARKDOWN_HEADER`, `SPLIT_TEXT_RECURSIVE_CHARACTER`, or producing chunk-like columns → Cortex Search candidates.

## When NOT to Use `dynamic_table`

- Semantic Views → `materialized='semantic_view'`
- User wants to stop using DTs → `table` with tag-based orchestration
