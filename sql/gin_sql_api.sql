CREATE EXTENSION gin_sql_api CASCADE;

-- Example 1. Opclass for prefix search in text[]

-- Support function for indexing
CREATE FUNCTION text_array_ops_extract_value(val text[]) RETURNS text[]
AS 'SELECT val' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

-- Support functions for operator #1 `anyarray && anyarray`
CREATE FUNCTION text_array_ops_extract_query_1(query text[]) RETURNS text[]
AS 'SELECT query' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION text_array_ops_consistent_1(bool[], text[]) RETURNS bool
AS 'SELECT TRUE' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

-- Implementation of ^@|(text[], text)  (any element starts with prefix)
CREATE FUNCTION starts_with_inv(prefix text, str text) RETURNS bool
AS 'SELECT str ^@ prefix' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR @^ (FUNCTION = starts_with_inv, LEFTARG = text, RIGHTARG = text);

-- Avoid inlining using plpgsql
CREATE FUNCTION text_array_any_starts_with(arr text[], prefix text) RETURNS bool
AS 'BEGIN RETURN prefix @^ ANY(arr); END' LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR ^@| (FUNCTION = text_array_any_starts_with, LEFTARG = text[], RIGHTARG = text);

-- Implementation of ^@||(text[], text[])  (any element starts with any prefix)
CREATE FUNCTION text_array_any_starts_with_any(arr text[], prefixes text[]) RETURNS bool
AS 'SELECT bool_or(prefix @^ ANY(arr)) FROM unnest(prefixes) prefix' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

--CREATE FUNCTION text_array_any_starts_with_any(arr text[], prefixes text[]) RETURNS bool
--AS 'BEGIN RETURN bool_or(prefix @^ ANY(arr)) FROM unnest(prefixes) prefix; END' LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR ^@|| (FUNCTION = text_array_any_starts_with_any, LEFTARG = text[], RIGHTARG = text[]);

-- Support functions for operator #2 `text[] ^@| text`
CREATE FUNCTION text_array_ops_extract_query_2(prefix text, OUT entries text[], OUT partial bool[]) RETURNS record
AS 'SELECT ARRAY[prefix], ARRAY[TRUE]' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION text_array_ops_consistent_2(bool[], text[]) RETURNS bool
AS 'SELECT TRUE' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION text_array_ops_compare_partial_2(idx text, query text) RETURNS bool
AS 'SELECT idx ^@ query' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

-- Support functions for operator #3 `text[] ^@|| text[]`
CREATE FUNCTION text_array_ops_consistent_3(bool[], text[]) RETURNS bool
AS 'SELECT TRUE' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION text_array_ops_compare_partial_3(idx text, query text) RETURNS bool
AS 'SELECT idx ^@ query' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION text_array_ops_extract_query_3(prefixes text[], OUT entries text[], OUT partial bool[]) RETURNS record
AS 'SELECT prefixes, array_fill(TRUE, ARRAY[array_length(prefixes, 1)])' LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;


CREATE OPERATOR CLASS text_array_ops FOR TYPE text[] USING gin AS
  STORAGE text,
  FUNCTION 2 gin_sql_extract_value,
  FUNCTION 3 gin_sql_extract_query,
  FUNCTION 5 gin_sql_compare_partial,
  FUNCTION 6 gin_sql_triconsistent,
  FUNCTION 7 gin_sql_options,
  OPERATOR 1 &&(anyarray, anyarray),
  OPERATOR 2 ^@|(text[], text),
  OPERATOR 3 ^@||(text[], text[]);

CREATE TABLE test (data text[]);

INSERT INTO test SELECT ARRAY['foo', i::text, 'bar' || (i / 1000)] FROM generate_series (1, 100000) i;

CREATE INDEX ON test USING gin (data text_array_ops(opclass_name = 'text_array_ops'));

EXPLAIN (COSTS OFF)
SELECT * FROM test WHERE data && '{12345}';
SELECT * FROM test WHERE data && '{12345}';
SELECT * FROM test WHERE data && '{12345,23456}';

EXPLAIN (COSTS OFF)
SELECT * FROM test WHERE data ^@| '12345';
SELECT * FROM test WHERE data ^@| '12345';
SELECT * FROM test WHERE data ^@| '123456';
SELECT * FROM test WHERE data ^@| '1234';
SELECT COUNT(*) FROM test WHERE data ^@| '123';
SELECT COUNT(*) FROM test WHERE data ^@| '12';
SELECT COUNT(*) FROM test WHERE data ^@| '1';
SELECT COUNT(*) FROM test WHERE data ^@| 'bar1';
SELECT COUNT(*) FROM test WHERE data ^@| 'bar';
SELECT COUNT(*) FROM test WHERE data ^@| '';

DROP OPERATOR FAMILY text_array_ops USING gin CASCADE;
DROP FUNCTION text_array_ops_extract_query_1(text[]);


-- Example 2. text[] opclass for intersection, containment and more
-- complex jsonb queries.
--
-- Uses query_int type for representation of logical expressions on
-- entries and gin_sql_triconsistent_expr(), so there is no need to
-- write own triconsistent().

-- extract_query() for operator #1 `text[] && text[]` (intersection)
CREATE OR REPLACE FUNCTION text_array_ops_extract_query_1(
  query text[],
  OUT entries text[],
  OUT partial bool[],
  OUT expr query_int
) RETURNS record
AS $$
  SELECT
    COALESCE(array_agg(entry), '{}'), -- empty result if no non-NULL entries
    NULL::bool[],
    string_agg(idx::text, '|')::query_int
  FROM (
    SELECT entry, row_number() OVER () - 1 AS idx
    FROM unnest(query) entry
    WHERE entry IS NOT NULL
  ) q
$$ LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

SELECT * FROM text_array_ops_extract_query_1('{}');
SELECT * FROM text_array_ops_extract_query_1('{foo}');
SELECT * FROM text_array_ops_extract_query_1('{NULL}');
SELECT * FROM text_array_ops_extract_query_1('{1234,345,NULL,foo,NULL,NULL,5678}');

-- extract_query() for operator #4 `text[] @> text[]` (containment)
CREATE OR REPLACE FUNCTION text_array_ops_extract_query_4(
  query text[],
  OUT entries text[],
  OUT partial bool[],
  OUT expr query_int
) RETURNS record
AS $$
  SELECT

    CASE
      WHEN TRUE = ANY (SELECT unnest(query) IS NULL)
      THEN '{}'::text[] -- empty result if contains NULL
      ELSE (
        SELECT array_agg(entry) -- NULL == match all, if empty query
        FROM unnest(query) entry
        WHERE entry IS NOT NULL
      )
    END,

    NULL::bool[],

    (SELECT string_agg(idx::text, '&')::query_int
	 FROM (
       SELECT entry, row_number() OVER () - 1 AS idx
       FROM unnest(query) entry
       WHERE entry IS NOT NULL
     ) x)
$$ LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

SELECT * FROM text_array_ops_extract_query_4('{}');
SELECT * FROM text_array_ops_extract_query_4('{foo}');
SELECT * FROM text_array_ops_extract_query_4('{NULL}');
SELECT * FROM text_array_ops_extract_query_4('{1234,345,NULL,foo,NULL,NULL,5678}');
SELECT * FROM text_array_ops_extract_query_4('{1234,345,foo,5678}');

-- Operator `text[] @@ jsonb` for checking existence of elements
--
-- jsonb expr == "str" | [ ... ]
--
--   "str" == EXISTS(element = "str")
--   [">", "str"] == EXISTS(element > "str")
--   ["> <=", "str1", "str2"] == EXISTS(element > "str1" AND element <= "str2")
--   ["OR",  expr1, expr2, ...] == expr1 OR  expr2 OR  ...
--   ["AND", expr1, expr2, ...] == expr1 AND expr2 AND ...

CREATE OR REPLACE FUNCTION text_array_query(arr text[], query jsonb) RETURNS bool
LANGUAGE plpython3u
TRANSFORM FOR TYPE jsonb
AS $$
def exec(query):
  if type(query) != list:
    return query in arr
  else:
    op = query[0]
    if op == 'OR':
      for i in range(1, len(query)):
        if exec(query[i]):
          return True
      return False
    elif op == 'AND':
      for i in range(1, len(query)):
        if not exec(query[i]):
          return False
      return True
    elif op == '>':
      return any(x >  query[1] for x in arr)
    elif op == '>=':
      return any(x >= query[1] for x in arr)
    elif op == '<':
      return any(x <  query[1] for x in arr)
    elif op == '<=':
      return any(x <= query[1] for x in arr)
    elif op == '> <':
      return any(x >  query[1] and x <  query[2] for x in arr)
    elif op == '>= <':
      return any(x >= query[1] and x <  query[2] for x in arr)
    elif op == '>= <=':
      return any(x >= query[1] and x <= query[2] for x in arr)
    elif op == '> <=':
      return any(x >  query[1] and x <= query[2] for x in arr)
    else:
      plpy.error("invalid query operation: %s" % op)

return exec(query)
$$ IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR @@ (FUNCTION = text_array_query, LEFTARG = text[], RIGHTARG = jsonb);

-- Structure for range queries, lower_bound contained in GIN entry
CREATE TYPE text_array_query_range AS (
  lower_inclusive bool,
  upper_inclusive bool,
  upper_bound text
);

-- extract_query() for operator #5 `text[] @@ jsonb`
CREATE OR REPLACE FUNCTION text_array_ops_extract_query_5(
  query jsonb,
  OUT entries text[],
  OUT partial text_array_query_range[],
  OUT expr query_int
) RETURNS record
LANGUAGE plpython3u
TRANSFORM FOR TYPE jsonb
AS $$
def node(idx, lo, hi, lo_inc, hi_inc):
  return ([lo], [(lo_inc, hi_inc, hi)], idx)

def extract(query, idx):
  if type(query) != list:
    return ([query], [None], idx)
  else:
    op = query[0]

    if op == 'OR':
      op = '|'
    elif op == 'AND':
      op = '&'
    elif op == '>':
      return node(idx, query[1], None, False, False)
    elif op == '>=':
      return node(idx, query[1], None, True, False)
    elif op == '<':
      return node(idx, "", query[1], True, False)
    elif op == '<=':
      return node(idx, "", query[1], True, True)
    elif op == '> <':
      return node(idx, query[1], query[2], False, False)
    elif op == '>= <':
      return node(idx, query[1], query[2], True, False)
    elif op == '>= <=':
      return node(idx, query[1], query[2], True, True)
    elif op == '> <=':
      return node(idx, query[1], query[2], False, True)
    else:
      plpy.error("invalid query operation: %s" % op)

    # construct logical AND/OR expression from subexpressions
    entries = []
    partial = []
    expr = None

    for i in range(1, len(query)):
      (entries2, partial2, expr2) = extract(query[i], idx)
      entries = entries + entries2
      partial = partial + partial2
      idx = idx + len(entries2)
      expr = '(%s) %s (%s)' % (expr, op, expr2) if expr != None else expr2

    return (entries, partial, expr)

return extract(query, 0)
$$ IMMUTABLE STRICT PARALLEL SAFE;

SELECT * FROM text_array_ops_extract_query_5('["OR", ["<", "12345"], [">", "123"], ["> <=", "aaa", "bbb"], "cccc"]');

-- Compare lower/upper bounds for range queries (query == lower_bound)
CREATE OR REPLACE FUNCTION text_array_ops_compare_partial_5(
  idx text, lower_bound text, range text_array_query_range
) RETURNS bool
AS $$
  SELECT
    ((range).lower_inclusive OR idx > lower_bound OR NULL) AND
    ((range).upper_bound IS NULL OR
     CASE WHEN (range).upper_inclusive THEN idx <= (range).upper_bound ELSE idx < (range).upper_bound END)
$$ LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;


CREATE OPERATOR CLASS text_array_ops FOR TYPE text[] USING gin AS
  STORAGE text,
  FUNCTION 2 gin_sql_extract_value,
  FUNCTION 3 gin_sql_extract_query,
  FUNCTION 5 gin_sql_compare_partial,
  FUNCTION 6 gin_sql_triconsistent_expr, -- for query_int
  FUNCTION 7 gin_sql_options,
  OPERATOR 1 &&(anyarray, anyarray),
  OPERATOR 4 @>(anyarray, anyarray),
  OPERATOR 5 @@(text[], jsonb);

CREATE INDEX ON test USING gin (data text_array_ops(opclass_name = 'text_array_ops'));

SET enable_seqscan = OFF;

EXPLAIN (COSTS OFF)
SELECT * FROM test WHERE data && '{12345}';
SELECT * FROM test WHERE data && '{12345}';
SELECT * FROM test WHERE data && '{12345,23456}';
SELECT * FROM test WHERE data && '{12345,NULL}';

EXPLAIN (COSTS OFF)
SELECT * FROM test WHERE data @> '{12345}';
SELECT * FROM test WHERE data @> '{12345}';
SELECT * FROM test WHERE data @> '{12345,23456}';
SELECT * FROM test WHERE data @> '{12345,NULL}';
SELECT * FROM test WHERE data @> '{12345,foo}';
SELECT * FROM test WHERE data @> '{12345,foo,bar12}';
SELECT * FROM test WHERE data @> '{12345,foo,bar13}';
SELECT COUNT(*) FROM test WHERE data @> '{}';

SELECT count(*) FROM test WHERE data @@ '["OR", "bar0", "12345", ["AND", "foo", "bar45"]]';

SELECT * FROM test WHERE data @@ '["> <",   "12340", "12345"]';
SELECT * FROM test WHERE data @@ '[">= <",  "12340", "12345"]';
SELECT * FROM test WHERE data @@ '[">= <=", "12340", "12345"]';
SELECT * FROM test WHERE data @@ '["> <=",  "12340", "12345"]';

SELECT count(*) FROM test WHERE data @@ '["> <", "12345", "13456"]';
SELECT count(*) FROM test WHERE data @@ '["AND", "bar0",  ["> <", "12345", "13456"]]';
SELECT count(*) FROM test WHERE data @@ '["AND", "bar1",  ["> <", "12345", "13456"]]';
SELECT count(*) FROM test WHERE data @@ '["AND", "bar12", ["> <", "12345", "13456"]]';
SELECT count(*) FROM test WHERE data @@ '["AND", "bar13", ["> <", "12345", "13456"]]';
SELECT count(*) FROM test WHERE data @@ '["AND", [">= <", "bar12", "bar99"], ["> <", "12345", "13456"]]';

RESET enable_seqscan;


-- Example 3. jsonb_path_ops analogue written on PL/Python

-- Extracts a list of `hash(path, value)`
CREATE OR REPLACE FUNCTION my_jsonb_path_ops_extract_value(jb jsonb)
RETURNS int4[]
LANGUAGE plpython3u
TRANSFORM FOR TYPE jsonb
AS $$
import hashlib

def paths(path_hash, val):
  if type(val) == list:
    for elem in val:
      yield from paths(path_hash, elem)

  elif type(val) == dict:
    for k, v in val.items():
      h = path_hash.copy()
      h.update(repr(k).encode('utf-8'))
      yield from paths(h, v)

  else:
    hash = path_hash.copy()
    hash.update(repr(val).encode('utf-8'))
    h = int(hash.hexdigest(1), 16) # 1-byte hash for testing recheck
    #h = int(hash.hexdigest(4), 16) # 4-byte hash
    #h = int(hash.hexdigest()[0:7], 16) # for md5()
    yield h if h < (1 << 31) else (1 << 31) - h

#return list(paths(hashlib.md5(), jb))
return list(paths(hashlib.shake_128(), jb))
$$ IMMUTABLE STRICT PARALLEL SAFE;

-- Extracts a list of `hash(path, value)` for operator @>
CREATE OR REPLACE FUNCTION my_jsonb_path_ops_extract_query_1(
  query jsonb,
  OUT entries int4[],
  OUT partial bool[],
  OUT expr query_int,
  OUT recheck bool
) RETURNS record
AS $$
  WITH entries AS (
   SELECT my_jsonb_path_ops_extract_value(query) AS entries
  )
  SELECT
    nullif(entries, '{}'),
    NULL::bool[],
    (SELECT string_agg(idx::text, '&')::query_int
     FROM generate_series(0, array_length(entries, 1) - 1) idx),
    TRUE
  FROM entries
$$
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE;

-- Opclass storing int4 hashes of (path, value)
CREATE OPERATOR CLASS my_jsonb_path_ops FOR TYPE jsonb USING gin AS
  STORAGE int4,
  FUNCTION 2 gin_sql_extract_value,
  FUNCTION 3 gin_sql_extract_query,
  FUNCTION 6 gin_sql_triconsistent_expr,
  FUNCTION 7 gin_sql_options,
  OPERATOR 1 @>(jsonb, jsonb);

CREATE TABLE test_jb (jb jsonb);

INSERT INTO test_jb SELECT NULL FROM generate_series(1, 100);
INSERT INTO test_jb SELECT '{}' FROM generate_series(1, 200);
INSERT INTO test_jb SELECT '[]' FROM generate_series(1, 300);
INSERT INTO test_jb SELECT jsonb_build_array(i) FROM generate_series(1, 10000) i;
INSERT INTO test_jb SELECT jsonb_build_array(i, 'baz' || (i / 100)) FROM generate_series(1, 10000) i;
INSERT INTO test_jb SELECT jsonb_build_array('foo', i) FROM generate_series(1, 10000) i;
INSERT INTO test_jb SELECT jsonb_build_object('foo', i) FROM generate_series(1, 10000) i;
INSERT INTO test_jb SELECT jsonb_build_object('foo', i, 'bar', 'baz' || (i / 100)) FROM generate_series(1, 10000) i;

CREATE INDEX ON test_jb USING gin (jb my_jsonb_path_ops (opclass_name = 'my_jsonb_path_ops'));

SET enable_seqscan = OFF;

EXPLAIN (COSTS OFF)
SELECT * FROM test_jb WHERE jb @> '{"foo": 123}';
SELECT * FROM test_jb WHERE jb @> '{"foo": 123}';
SELECT * FROM test_jb WHERE jb @> '{"foo": 123, "bar": "baz1"}';
SELECT count(*) FROM test_jb WHERE jb @> '{"bar": "baz1"}';

SELECT * FROM test_jb WHERE jb @> '[123]';
SELECT * FROM test_jb WHERE jb @> '[123, 456]';
SELECT * FROM test_jb WHERE jb @> '[123, "baz1"]';
SELECT count(*) FROM test_jb WHERE jb @> '["baz1"]';
SELECT count(*) FROM test_jb WHERE jb @> '["foo"]';

SELECT count(*) FROM test_jb WHERE jb @> '{}';
SELECT count(*) FROM test_jb WHERE jb @> '[]';
SELECT count(*) FROM test_jb WHERE jb @> '123';

RESET enable_seqscan;

DROP TABLE test;
DROP TABLE test_jb;

DROP EXTENSION gin_sql_api CASCADE;
