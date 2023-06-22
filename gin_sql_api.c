#include "postgres.h"
#include "fmgr.h"
#include "funcapi.h"

#include "access/gin.h"
#include "access/reloptions.h"
#include "catalog/pg_opclass.h"
#include "catalog/pg_am_d.h"
#include "commands/defrem.h"
#include "miscadmin.h"
#include "parser/parse_func.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"

PG_MODULE_MAGIC;

typedef struct GinSqlOptions
{
	int32   vl_len_;
	int		opclass_name;
} GinSqlOptions;

static GinSqlOptions *
gin_sql_get_options(FunctionCallInfo fcinfo)
{
	if (!PG_HAS_OPCLASS_OPTIONS())
		elog(ERROR, "gin_sql must have opclass options");

	return (GinSqlOptions *) PG_GET_OPCLASS_OPTIONS();
}

typedef struct GinSqlInfo
{
	char	   *opclassname;
	Oid			opfamilyoid;
	Oid			opclassoid;
	Oid			opcintype;
	Oid			opckeytype;

	Oid			typid;
	int16		typlen;
	bool		typbyval;
	char		typalign;

	FmgrInfo   *finfo;
	TypeFuncClass fnrettypclass;
	Oid			fnrettypid;
	TupleDesc	fnrettupdesc;
} GinSqlInfo;

static GinSqlInfo *
idx_sql_get_info(FunctionCallInfo fcinfo, Oid amoid, int proc, StrategyNumber strategy)
{
	GinSqlInfo *info;
	GinSqlOptions *options;
	HeapTuple	opctup;
	Form_pg_opclass opcform;
	MemoryContext fn_mcxt = fcinfo->flinfo->fn_mcxt;

	if (fcinfo->flinfo->fn_extra)
		return (GinSqlInfo *) fcinfo->flinfo->fn_extra;

	info = MemoryContextAllocZero(fn_mcxt, sizeof(*info));
	fcinfo->flinfo->fn_extra = info;

	options = gin_sql_get_options(fcinfo);

	info->opclassname = GET_STRING_RELOPTION(options, opclass_name);
	info->opclassoid = get_opclass_oid(amoid, list_make1(makeString(info->opclassname)), false);

	opctup = SearchSysCache1(CLAOID, ObjectIdGetDatum(info->opclassoid));
	if (!HeapTupleIsValid(opctup))
		elog(ERROR, "cache lookup failed for operator class %u", info->opclassoid);
	opcform = (Form_pg_opclass) GETSTRUCT(opctup);

	info->opfamilyoid = opcform->opcfamily;
	info->opcintype = opcform->opcintype;
	info->opckeytype = opcform->opckeytype;

	ReleaseSysCache(opctup);

	info->typid = OidIsValid(info->opckeytype) ? info->opckeytype : info->opcintype;

	get_typlenbyvalalign(info->typid, &info->typlen, &info->typbyval, &info->typalign);

	if (!info->finfo)
	{
		char		fname[NAMEDATALEN + 1];
		Oid			fnargs[3];
		Oid			fnoid;
		MemoryContext oldcxt;

		if (amoid == GIN_AM_OID)
		{
			switch (proc)
			{
				case GIN_EXTRACTVALUE_PROC:
					snprintf(fname, sizeof(fname) - 1, "%s_extract_value", info->opclassname);
					fnargs[0] = info->opcintype;
					fnoid = LookupFuncName(list_make1(makeString(fname)), 1, fnargs, false);
					break;

				case GIN_EXTRACTQUERY_PROC:
					snprintf(fname, sizeof(fname) - 1, "%s_extract_query_%d", info->opclassname, strategy);
					fnoid = DatumGetObjectId(DirectFunctionCall1(regprocin, CStringGetDatum(fname)));
					break;

				case GIN_TRICONSISTENT_PROC:
					snprintf(fname, sizeof(fname) - 1, "%s_consistent_%d", info->opclassname, strategy);
					fnoid = DatumGetObjectId(DirectFunctionCall1(regprocin, CStringGetDatum(fname)));
					break;

				case GIN_COMPARE_PARTIAL_PROC:
					snprintf(fname, sizeof(fname) - 1, "%s_compare_partial_%d", info->opclassname, strategy);
					fnoid = DatumGetObjectId(DirectFunctionCall1(regprocin, CStringGetDatum(fname)));
					break;

				default:
					elog(ERROR, "invalid GIN support procedure number: %d", proc);
			}
		}
		else
			elog(ERROR, "invalid AM oid: %d", amoid);

		oldcxt = MemoryContextSwitchTo(fn_mcxt);

		info->finfo = MemoryContextAlloc(fn_mcxt, sizeof(*info->finfo));
		fmgr_info_cxt(fnoid, info->finfo, fn_mcxt);

		info->fnrettypclass = get_func_result_type(fnoid, &info->fnrettypid, &info->fnrettupdesc);

		MemoryContextSwitchTo(oldcxt);
	}

	return info;
}

static GinSqlInfo *
gin_sql_get_info(FunctionCallInfo fcinfo, int proc, StrategyNumber strategy)
{
	return idx_sql_get_info(fcinfo, GIN_AM_OID, proc, strategy);
}

PG_FUNCTION_INFO_V1(gin_sql_extract_value);

Datum
gin_sql_extract_value(PG_FUNCTION_ARGS)
{
	Datum		value = PG_GETARG_DATUM(0);
	int32	   *nentries = (int32 *) PG_GETARG_POINTER(1);
	bool	  **nullFlags = (bool **) PG_GETARG_POINTER(2);

	GinSqlInfo *info = gin_sql_get_info(fcinfo, GIN_EXTRACTVALUE_PROC, 0);
	Datum		entries_array = FunctionCall1Coll(info->finfo, PG_GET_COLLATION(), value);
	Datum	   *entries;

	deconstruct_array(DatumGetArrayTypeP(entries_array),
					  info->typid, info->typlen, info->typbyval, info->typalign,
					  &entries, nullFlags, nentries);

	PG_RETURN_POINTER(entries);
}

typedef struct GinSqlExtraData
{
	Datum		data;
	bool		recheck;
} GinSqlExtraData;

typedef struct GinSqlEntryData
{
	GinSqlExtraData *extra;
	Datum		partial;
} GinSqlEntryData;

PG_FUNCTION_INFO_V1(gin_sql_extract_query);

Datum
gin_sql_extract_query(PG_FUNCTION_ARGS)
{
	Datum		query = PG_GETARG_DATUM(0);
	int32	   *nentries = (int32 *) PG_GETARG_POINTER(1);
	StrategyNumber strategy = PG_GETARG_UINT16(2);
	bool	  **partial_match = (bool **) PG_GETARG_POINTER(3);
	Pointer   **p_extra_data = (Pointer **) PG_GETARG_POINTER(4);
	bool	  **null_flags = (bool **) PG_GETARG_POINTER(5);
	int32	   *search_mode = (int32 *) PG_GETARG_POINTER(6);

	GinSqlInfo *info = gin_sql_get_info(fcinfo, GIN_EXTRACTQUERY_PROC, strategy);
	Datum		entries_array = FunctionCall1Coll(info->finfo, PG_GET_COLLATION(), query);
	Datum	   *entries;
	GinSqlEntryData *partial_data = NULL;
	Datum		extra_data = 0;
	int			npartial = -1;
	bool		have_extra_data = false;
	bool		recheck = false;

	*p_extra_data = NULL;
	*partial_match = NULL;
	*search_mode = GIN_SEARCH_MODE_DEFAULT;

	if (info->fnrettypclass == TYPEFUNC_COMPOSITE)
	{
		/* OUT entries[], OUT partial_match bool[], OUT expr query_int, OUT recheck */
		HeapTupleData tup;
		HeapTupleHeader tuphdr = DatumGetHeapTupleHeader(entries_array);
		Datum		values[4];
		bool		isnull[4];
		Form_pg_attribute attrs = info->fnrettupdesc->attrs;
		int			natts;

		tup.t_len = HeapTupleHeaderGetDatumLength(tuphdr);
		tup.t_data = tuphdr;

		heap_deform_tuple(&tup, info->fnrettupdesc, values, isnull);

		natts = info->fnrettupdesc->natts;

		if (isnull[0])
			entries_array = (Datum) 0;
		else
			entries_array = values[0];

		if (natts > 1 && !isnull[1])
		{
			Datum	   *partial_values;
			bool	   *partial_isnull;
			Oid			typelem = get_element_type(attrs[1].atttypid);
			int16		typlen;
			bool		typbyval;
			char		typalign;

			get_typlenbyvalalign(typelem, &typlen, &typbyval, &typalign);

			deconstruct_array(DatumGetArrayTypeP(values[1]),
							  typelem, typlen, typbyval, typalign,
							  /* BOOLOID, 1, true, 'c', */
							  &partial_values, &partial_isnull, &npartial);

			*partial_match = palloc(sizeof(bool) * npartial);
			partial_data = palloc(sizeof(*partial_data) * npartial);
			have_extra_data = true;

			for (int i = 0; i < npartial; i++)
			{
				(*partial_match)[i] = !partial_isnull[i];
				partial_data[i].partial = partial_isnull[i] ? 0 : partial_values[i];
				/*
				if (partial_isnull[i])
					elog(ERROR, "partial match array should not contain NULLs");
				(*partial_match)[i] = DatumGetBool(partial_values[i]);
				*/
			}

			pfree(partial_values);
			pfree(partial_isnull);
		}

		if (natts > 2 && !isnull[2])
		{
			have_extra_data = true;
			extra_data = attrs[2].attbyval ? values[2] : PointerGetDatum(PG_DETOAST_DATUM_COPY(values[2]));
			/* extra_data = datumCopy(values[2], false, -1); */
		}

		if (natts > 3 && !isnull[3] && DatumGetBool(values[3]))
			recheck = true;
	}

	if (entries_array)
		deconstruct_array(DatumGetArrayTypeP(entries_array),
						  info->typid, info->typlen, info->typbyval, info->typalign,
						  &entries, null_flags, nentries);
	else
	{
		*nentries = 0;
		*search_mode = GIN_SEARCH_MODE_ALL;
	}

	if (npartial >= 0 && *nentries != npartial)
		elog(ERROR, "size of entries array %d does not match size of partial match array %d", *nentries, npartial);

	*nentries = Max(0, *nentries);

	if (have_extra_data || recheck)
	{
		GinSqlExtraData *extra = palloc(sizeof(*extra));

		extra->data = extra_data;
		extra->recheck = recheck;

		*p_extra_data = palloc0(sizeof(Pointer) * (*nentries + 1));
		(*p_extra_data)[*nentries] = (Pointer) extra;

		for (int i = 0; i < *nentries; i++)
		{
			if (partial_data && (*partial_match)[i])
			{
				partial_data[i].extra = extra;
				(*p_extra_data)[i] = (Pointer) &partial_data[i];
			}
			else
				(*p_extra_data)[i] = 0;
		}
	}

	PG_RETURN_POINTER(entries);
}

PG_FUNCTION_INFO_V1(gin_sql_triconsistent);

Datum
gin_sql_triconsistent(PG_FUNCTION_ARGS)
{
	GinTernaryValue *check = (GinTernaryValue *) PG_GETARG_POINTER(0);
	StrategyNumber strategy = PG_GETARG_UINT16(1);
	Datum		query = PG_GETARG_DATUM(2);
	int32		nentries = PG_GETARG_INT32(3);
/*	Pointer	   *extra_data = (Pointer *) PG_GETARG_POINTER(4); */
/*	Datum	   *query_keys = (Datum *) PG_GETARG_POINTER(5); */
/*	bool	   *null_flags = (bool *) PG_GETARG_POINTER(6); */

	GinSqlInfo *info = gin_sql_get_info(fcinfo, GIN_TRICONSISTENT_PROC, strategy);
	ArrayType  *check_array = NULL;
	GinTernaryValue	res;

	Datum	   *entries = palloc(sizeof(*entries) * nentries);
	bool	   *nulls = palloc(sizeof(*nulls) * nentries);
	int			dims[1] = {nentries};
	int			lbs[1] = {1};

	for (int i = 0; i < nentries; i++)
	{
		entries[i] = BoolGetDatum(check[i] == GIN_TRUE);
		nulls[i] = check[i] == GIN_MAYBE;
	}

	check_array = construct_md_array(entries, nulls, 1, dims, lbs, BOOLOID, 1, true, 'c');

	{
		LOCAL_FCINFO(fcinfo, 2);

		InitFunctionCallInfoData(*fcinfo, info->finfo, 2, PG_GET_COLLATION(), NULL, NULL);

		fcinfo->args[0].value = PointerGetDatum(check_array);
		fcinfo->args[0].isnull = false;
		fcinfo->args[1].value = query;
		fcinfo->args[1].isnull = false;

		res = DatumGetBool(FunctionCallInvoke(fcinfo)) ? GIN_TRUE : GIN_FALSE;

		if (fcinfo->isnull)
			res = GIN_MAYBE;
	}

	pfree(entries);
	pfree(nulls);

	PG_RETURN_INT32(res);
}

PG_FUNCTION_INFO_V1(gin_sql_compare_partial);

Datum
gin_sql_compare_partial(PG_FUNCTION_ARGS)
{
	Datum		query_key = PG_GETARG_DATUM(0);
	Datum		index_key = PG_GETARG_DATUM(1);
	StrategyNumber strategy = PG_GETARG_UINT16(2);
	GinSqlEntryData *data = (GinSqlEntryData *) PG_GETARG_POINTER(3);
	GinSqlInfo *info = gin_sql_get_info(fcinfo, GIN_COMPARE_PARTIAL_PROC, strategy);
	int32		res;

	{
		LOCAL_FCINFO(fcinfo, 3);

		InitFunctionCallInfoData(*fcinfo, info->finfo, 3, PG_GET_COLLATION(), NULL, NULL);

		fcinfo->args[0].value = index_key;
		fcinfo->args[0].isnull = false;
		fcinfo->args[1].value = query_key;
		fcinfo->args[1].isnull = false;
		fcinfo->args[2].value = data ? data->partial : 0;
		fcinfo->args[2].isnull = !data;

		res = DatumGetBool(FunctionCallInvoke(fcinfo)) ? 0 : 1;

		if (fcinfo->isnull)
			res = -1;
	}

	PG_RETURN_INT32(res);
}

static void
validate_opclass_name_relopt(const char *value)
{
/*
	if (value && strlen(value) <= 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("opclass_name must be non-empty")));
*/

	if (strlen(value) > NAMEDATALEN)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("opclass_name must be at most %d bytes", NAMEDATALEN)));
}

static Size
fill_validate_opclass_name_relopt(const char *value, void *ptr)
{
	int			len = strlen(value);

	if (ptr)
		strcpy((char *) ptr, value);

	return len + 1;
}

PG_FUNCTION_INFO_V1(gin_sql_options);

Datum
gin_sql_options(PG_FUNCTION_ARGS)
{
	local_relopts *relopts = (local_relopts *) PG_GETARG_POINTER(0);

	init_local_reloptions(relopts, sizeof(GinSqlOptions));
	add_local_string_reloption(relopts, "opclass_name", "prefix of opclass support function names",
							   "",
                               &validate_opclass_name_relopt,
                               &fill_validate_opclass_name_relopt,
                               offsetof(GinSqlOptions, opclass_name));

	PG_RETURN_VOID();
}

/* Structure definitions for type query_int copied from contrib/intarray */

/*
 * item in polish notation with back link
 * to left operand
 */
typedef struct ITEM
{
	int16		type;
	int16		left;
	int32		val;
} ITEM;

typedef struct QUERYTYPE
{
	int32		vl_len_;		/* varlena header (do not touch directly!) */
	int32		size;			/* number of ITEMs */
	ITEM		items[FLEXIBLE_ARRAY_MEMBER];
} QUERYTYPE;

/* "type" codes for ITEM */
#define END		0
#define ERR		1
#define VAL		2
#define OPR		3
#define OPEN	4
#define CLOSE	5

static GinTernaryValue
execute(ITEM *curitem, GinTernaryValue *check, int nentries)
{
	check_stack_depth();

	if (curitem->type == VAL)
	{
		if (curitem->val < 0 || curitem->val >= nentries)
			elog(ERROR, "invalid intarray query");

		return check[curitem->val];
	}
	else if (curitem->val == (int32) '!')
	{
		GinTernaryValue res = execute(curitem - 1, check, nentries);

		if (res == GIN_TRUE)
			return GIN_FALSE;
		else if (res == GIN_FALSE)
			return GIN_TRUE;
		else
			return GIN_MAYBE;
	}
	else if (curitem->val == (int32) '&')
	{
		GinTernaryValue res1 = execute(curitem + curitem->left, check, nentries);
		GinTernaryValue res2;

		if (res1 == GIN_FALSE)
			return GIN_FALSE;

		res2 = execute(curitem - 1, check, nentries);

		if (res2 == GIN_FALSE)
			return GIN_FALSE;

		if (res1 == GIN_TRUE && res2 == GIN_TRUE)
			return GIN_TRUE;

		Assert(res1 == GIN_MAYBE || res2 == GIN_MAYBE);
		return GIN_MAYBE;
	}
	else
	{							/* | operator */
		GinTernaryValue res1 = execute(curitem + curitem->left, check, nentries);
		GinTernaryValue res2;

		if (res1 == GIN_TRUE)
			return GIN_TRUE;

		res2 = execute(curitem - 1, check, nentries);

		if (res2 == GIN_TRUE)
			return GIN_TRUE;

		if (res1 == GIN_FALSE && res2 == GIN_FALSE)
			return GIN_FALSE;

		Assert(res1 == GIN_MAYBE || res2 == GIN_MAYBE);
		return GIN_MAYBE;
	}
}

PG_FUNCTION_INFO_V1(gin_sql_triconsistent_expr);

Datum
gin_sql_triconsistent_expr(PG_FUNCTION_ARGS)
{
	GinTernaryValue *check = (GinTernaryValue *) PG_GETARG_POINTER(0);
/*	StrategyNumber strategy = PG_GETARG_UINT16(1); */
/*	Datum		query = PG_GETARG_DATUM(2); */
	int32		nentries = PG_GETARG_INT32(3);
	Pointer	   *extra_data = (Pointer *) PG_GETARG_POINTER(4);
/*	Datum	   *query_keys = (Datum *) PG_GETARG_POINTER(5); */
/*	bool	   *null_flags = (bool *) PG_GETARG_POINTER(6); */
	GinSqlExtraData *extra;
	QUERYTYPE  *int_query;
	GinTernaryValue	res;

	if (!extra_data || !extra_data[nentries])
		PG_RETURN_INT32(GIN_TRUE);

	extra = (GinSqlExtraData *) extra_data[nentries];
	int_query = (QUERYTYPE *) DatumGetPointer(extra->data);

	if (!int_query)
		res = GIN_TRUE;
	else
		res = execute(&int_query->items[int_query->size - 1], check, nentries);

	if (res == GIN_TRUE && extra->recheck)
		res = GIN_MAYBE;

	PG_RETURN_INT32(res);
}
