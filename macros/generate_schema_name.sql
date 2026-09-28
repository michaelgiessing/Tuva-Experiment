{#
    This macro has been modified to work with the variables set in the dbt_project.yml file.
    See https://docs.getdbt.com/docs/building-a-dbt-project/building-models/using-custom-schemas for the original macro.
#}

{#
    claims_preprocessing is a single, monolithic schema in the upstream package
    (~200+ tables), which blows past Databricks Free Edition's 100-tables-per-schema
    cap. Split it by path prefix into a few sub-schemas that each stay under that cap.
#}
{% macro default__generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- set node_path = node.path | default('') -%}
    {%- set claims_preprocessing_schema_overrides = [
        ('claims_preprocessing/encounters/intermediate/', 'claims_preprocessing_encounters'),
        ('claims_preprocessing/service_category/', 'claims_preprocessing_service_category'),
        ('normalization/', 'claims_preprocessing_normalization'),
    ] -%}
    {%- set ns = namespace(override_schema=none) -%}
    {%- for prefix, schema_name in claims_preprocessing_schema_overrides -%}
        {%- if ns.override_schema is none and node_path.startswith(prefix) -%}
            {%- set ns.override_schema = schema_name -%}
        {%- endif -%}
    {%- endfor -%}

    {%- if ns.override_schema is not none -%}
        {{ ns.override_schema }}
    {%- elif custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}
{%- endmacro %}
