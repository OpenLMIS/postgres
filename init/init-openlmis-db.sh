#!/bin/bash

set -e

createdb --username "$POSTGRES_USER" open_lmis
psql -d open_lmis -c "CREATE EXTENSION postgis;"
psql -d open_lmis -c 'DROP EXTENSION IF EXISTS "uuid-ossp"; CREATE EXTENSION "uuid-ossp";'