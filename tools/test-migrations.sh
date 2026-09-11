#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Aplica todas las migraciones en un Postgres desechable y las pone a prueba:
#   · humo:      generar mundo, fundar, comprar, construir, producir, vender
#   · seguridad: que un jugador no pueda escribir en la economía a mano
#   · balanceo:  margen por hora de cada receta
#
#   ./tools/test-migrations.sh
#
# Requiere: postgresql-client y un servidor Postgres accesible.
# Variables: PGHOST PGPORT PGUSER PGPASSWORD (por defecto, socket local).
# -----------------------------------------------------------------------------
set -euo pipefail

DB="${URBANHILLS_TEST_DB:-urbanhills_test}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Recreando la base $DB"
dropdb --if-exists "$DB"
createdb "$DB"

psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$ROOT/tools/local-shim.sql"

for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "==> $(basename "$f")"
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"
done

echo "==> Prueba de humo"
psql -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/tools/smoke-test.sql"

echo "==> Prueba de seguridad (RLS)"
psql -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/tools/rls-test.sql"

echo "==> Balanceo económico"
psql -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/tools/check-balance.sql"

echo
echo "OK — migraciones, prueba de humo, seguridad y balanceo."
