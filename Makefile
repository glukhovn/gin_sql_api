# contrib/gin_sql/Makefile

MODULE_big = gin_sql_api
EXTENSION = gin_sql_api
DATA = gin_sql_api--1.0.sql
OBJS = gin_sql_api.o
REGRESS = gin_sql_api

EXTRA_INSTALL += contrib/intarray contrib/jsonb_plpython

ifdef USE_PGXS
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/gin_sql_api
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
