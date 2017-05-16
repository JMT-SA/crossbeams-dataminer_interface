# TODO

* DM: option to open in new window when running. (switch in GUI)
* Add the ability to design pivots (pg crosstab queries).
* Provide separate interface for running crosstabs.
* Pivot:
   - prepare qry as per dm
   - Declare which columns can be used as values
   - Declare which can be columns and provide the SQL to get the set
   - Declare which can be row names
   - At runtime, the user uses param as usual to shape the query
   - User chooses row name, column and value. If only one of any declared, use it.
   - Run the column query to get possible columns
   - Use column values as column captions and downcase for query field names
   - Assemble the crosstab and run it.

## Crosstab yml structure

The YAML file for a crosstab report will be a superset of a dataminer YAML report.
The crosstab *could* point to the report definition, but the dependency would likely become problematic over time.

~~~yml
---
  query: as per dm
  columns: as per dm
  crosstab:
    row_columns:
    - col1
    - col2
    column_columns:
    - col3:
      sql: select col from table
      apply_report_where_clause: false
    - col4:
      sql: select col from table
      apply_report_where_clause: false
    value_columns:
    - col5:
      data_type: integer
    - col6:
      data_type: numeric
    chosen_settings:
      rows: col2
      col: col3
      value: col6
      apply_report_where_clause: false
~~~

hs = {crosstab: {row_columns: ['organization_code', 'commodity_code', 'marketing_variety_code', 'fg_code_old'], column_columns: [{'grade_code' => {sql: 'SELECT DISTINCT grade_code FROM grades ORDER BY 1', apply_report_where_clause: false}}], value_columns: [{'pallet_count' => {data_type: :integer}}]}}


## Example crosstab queries

Single column for row name:
~~~sql
SELECT * FROM crosstab(
'SELECT organization_code,
grade_code,
COUNT(pallet_number)
FROM vwonstock_pallets
WHERE build_status = ''FULL''
  AND packed_by = ''KROMCO''
  AND load_number IS NULL
GROUP BY organization_code, grade_code
ORDER BY organization_code, grade_code',
'SELECT DISTINCT grade_code FROM grades ORDER BY 1')
AS (
organization_code character varying,
g_1 integer,
g_1A integer,
g_1B integer,
g_1L integer,
g_1R integer,
g_1X integer,
g_1Y integer,
g_1Z integer,
g_2 integer,
g_2A integer,
g_2L integer,
g_P integer,
g_RSA1 integer,
g_SA integer,
g_SF integer
);
~~~

YML:
* dataminer_query_file ( or query in crosstab file)...
* column_values query
* possible columns for row names
* possible columns for values (aggregates need to be named....)
* Tricks required: change grouping for aggregates etc.

Several columns for row name - packed and unpacked via an Array
**NB** Postgresql arrays start at 1, not 0.
~~~sql
SELECT row_name[1] AS organization_code, row_name[2] AS commodity_code, row_name[3] AS marketing_variety_code, row_name[4] AS fg_code_old, g_1,
g_1A,
g_1B,
g_1L,
g_1R,
g_1X,
g_1Y,
g_1Z,
g_2,
g_2A,
g_2L,
g_P,
g_RSA1,
g_SA,
g_SF
 FROM crosstab(
'SELECT ARRAY[organization_code, commodity_code, marketing_variety_code, fg_code_old] AS row_name,
grade_code,
COUNT(pallet_number)
FROM vwonstock_pallets
WHERE build_status = ''FULL''
  AND packed_by = ''KROMCO''
  AND load_number IS NULL
GROUP BY organization_code, grade_code, commodity_code, marketing_variety_code, fg_code_old, grade_code
ORDER BY organization_code, grade_code, commodity_code, marketing_variety_code, fg_code_old, grade_code',

'SELECT DISTINCT grade_code FROM grades ORDER BY 1')
AS (
row_name character varying[],
g_1 integer,
g_1A integer,
g_1B integer,
g_1L integer,
g_1R integer,
g_1X integer,
g_1Y integer,
g_1Z integer,
g_2 integer,
g_2A integer,
g_2L integer,
g_P integer,
g_RSA1 integer,
g_SA integer,
g_SF integer
);
~~~

Array, with column query constrained by WHERE clause:
~~~sql
SELECT row_name[1] AS organization_code, row_name[2] AS commodity_code, row_name[3] AS marketing_variety_code, row_name[4] AS fg_code_old,
g_1A,
g_1L,
g_1Y,
g_2A,
g_2L,
g_SA
 FROM crosstab(
'SELECT ARRAY[organization_code, commodity_code, marketing_variety_code, fg_code_old] AS row_name,
grade_code,
COUNT(pallet_number)
FROM vwonstock_pallets
WHERE build_status = ''FULL''
  AND packed_by = ''KROMCO''
  AND load_number IS NULL
GROUP BY organization_code, grade_code, commodity_code, marketing_variety_code, fg_code_old, grade_code
ORDER BY organization_code, grade_code, commodity_code, marketing_variety_code, fg_code_old, grade_code',

'SELECT DISTINCT grade_code FROM vwonstock_pallets WHERE build_status = ''FULL'' AND packed_by = ''KROMCO'' AND load_number IS NULL ORDER BY 1')
AS (
row_name varchar[],
g_1A integer,
g_1L integer,
g_1Y integer,
g_2A integer,
g_2L integer,
g_SA integer
);
~~~

