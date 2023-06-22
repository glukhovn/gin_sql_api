# gin_sql_api
API for creating PostgreSQL GIN index opclasses using plain SQL or PL/XXX instead of C

## Opclass creation
To create a GIN operator class for type `foo` with storage type `entry_type` you need to:

1. Define opclass with your operators and generic support functions `gin_sql_xxx()` from this extension.
These support functions written in C will call your support functions written in SQL or PL/XXX.

```
CREATE OPERATOR CLASS foo_ops FOR TYPE foo USING gin AS
  STORAGE entry_type,
  FUNCTION 2 gin_sql_extract_value,
  FUNCTION 3 gin_sql_extract_query,
  FUNCTION 5 gin_sql_compare_partial,
  FUNCTION 6 gin_sql_triconsistent_expr,
  FUNCTION 7 gin_sql_options,
  OPERATOR 1 @@(foo, query_type_1),
  OPERATOR 2 @@@(foo, query_type_2),
  ...
;
```

2. Define your `extract_value()` support function for extracting entries from indexed value:
```
CREATE FUNCTION foo_ops_extract_value(indexed_value foo) RETURNS entry_type[] ...;
```

3. Define your `extract_query_N()` support functions for each operator #N:
```
CREATE FUNCTION foo_ops_extract_query_N(
  query query_type_N,
  OUT entries entry_type[],
  OUT partial_match partial_match_type_N[],
  OUT expr query_int,
  OUT recheck
) RETURNS RECORD ...;
```

 * `entries` argument is mandatory, other output arguments can be omitted or be NULL.
 * `partial_match_type` is an arbitrary type, elements of `partial_match` will be  passed to `compare_partial_N()`.
 * `expr` is a logical expression built on entry numbers (see [contrib/intarray](https://github.com/postgres/postgres/tree/master/contrib/intarray)).
 * `recheck` is a flag showing that index is lossy and original operator should be executed fot each row found by index.

4. (Optional) Define your `compare_partial_N()` support functions for each operator #N,
   if `extract_query_N()` returns non-NULL `partial_match[]`:
```
CREATE FUNCTION foo_ops_extract_query_N(
  index entry_type,
  query entry_type,
  partial_match partial_match_type_N
) RETURNS bool ...;
```
This is typically used for range queries.

If `partial_match[i]` is non-NULL, then GIN B-tree is scanned starting from `entries[i]`,
and `compare_partial_N()` is called for each found entry `index`.
Scan continues until `FALSE` is returned.

* `entries[i]` is passed as `query`.
* `partial_match[i]` is passed as `partial_match`, it can be used to pass upper bound and lower/upper bound's inclusion flags.

Return value:
 * `TRUE` -- `index` entry matches
 * `FALSE` -- `index` entry does not match, stop scan
 * `NULL` -- `index` entry does not match, continue scan

## Index creation
The opclass name, used as a prefix for support function names, should be passed to opclass as a parameter:
```
CREATE INDEX ON foo_tab USING gin (foo_column foo_ops(opclass_name = 'foo_ops'));
```

## Examples
See examples in regression file [sql/gin_sql_api.sql](https://github.com/glukhovn/gin_sql_api/blob/master/sql/gin_sql_api.sql).

## Issues/TODO
* Opclass parameter `opclass_schema` for specifying schema of support functions
* Passing of custom opclass parameters to support functions
