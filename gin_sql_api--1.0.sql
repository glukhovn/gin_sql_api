/* contrib/gin_sql/gin_sql_api--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION gin_sql_api" to load this file. \quit

CREATE FUNCTION gin_sql_extract_value("any", internal, internal)
RETURNS internal
AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION gin_sql_extract_query("any", internal, int2, internal, internal, internal, internal)
RETURNS internal
AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION gin_sql_triconsistent(internal, int2, "any", integer, internal, internal, internal)
RETURNS int32
AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION gin_sql_triconsistent_expr(internal, int2, query_int, integer, internal, internal, internal)
RETURNS int32
AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION gin_sql_compare_partial("any", "any", int2, internal)
RETURNS int4
AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION gin_sql_options(internal)
RETURNS void
AS 'MODULE_PATHNAME' LANGUAGE C;
