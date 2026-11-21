"""PREPARED ONLY: requires separate production export approval and private access.

Requires PostgreSQL 16 pg_dump on PATH, psycopg2 and protected libpq service/pass
files. Writes private recovery artifacts only to the explicitly supplied folder.
Never runs migrations or modifies the source database.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from datetime import datetime, timezone

import psycopg2
from psycopg2 import sql


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--service', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--approved-production-export', action='store_true')
    args = parser.parse_args()
    if not args.approved_production_export:
        parser.error('Separate approval for production export is required')
    if shutil.which('pg_dump') is None:
        parser.error('PostgreSQL 16 pg_dump must be installed on the approved client')
    # Require a fresh, explicitly provisioned protected directory. Never overwrite.
    folder = args.output.resolve()
    folder.mkdir(exist_ok=False)
    archive = folder / 'safecircle.dump'
    env = dict(os.environ, PGSERVICE=args.service, PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=60000 -c lock_timeout=5000')
    with psycopg2.connect(service=args.service) as conn:
        conn.set_session(isolation_level='REPEATABLE READ', readonly=True)
        with conn.cursor() as cursor:
            cursor.execute("SET LOCAL TIME ZONE 'UTC'")
            cursor.execute("SET LOCAL datestyle = 'ISO, YMD'")
            cursor.execute("SET LOCAL statement_timeout = '60s'")
            cursor.execute('SELECT current_database(), version_num FROM alembic_version')
            database, revision = cursor.fetchone()
            if database != 'safecircle_db' or revision != 'e17d6a10bc25':
                raise RuntimeError('Unexpected source identity or Alembic revision')
            cursor.execute('SELECT pg_export_snapshot()')
            snapshot = cursor.fetchone()[0]
            started = datetime.now(timezone.utc).isoformat()
            result = subprocess.run([
                'pg_dump', '--format=custom', '--no-owner', '--no-acl',
                '--lock-wait-timeout=5s', '--snapshot=' + snapshot,
                '--file=' + str(archive),
            ], env=env, capture_output=True)
            if result.returncode:
                raise RuntimeError('Backup failed; inspect protected client diagnostics without printing credentials')
            cursor.execute("""
                SELECT n.nspname, c.relname FROM pg_class c
                JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='public' AND c.relkind IN ('r','p')
                AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE
                    d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e')
                ORDER BY 1,2
            """)
            tables = cursor.fetchall()
            checks = ["SET TIME ZONE 'UTC';", "SET datestyle = 'ISO, YMD';",
                      "DO $$ BEGIN IF current_database() <> 'safecircle_restore_drill' THEN RAISE EXCEPTION 'Wrong restore target'; END IF; END $$;"]
            counts = {}
            for schema, table in tables:
                identifier = sql.Identifier(schema, table)
                # Digest sorted row digests, never expose raw user/account/device data.
                query = sql.SQL("SELECT count(*), md5(coalesce(string_agg(h,'' ORDER BY h),'')) FROM (SELECT md5(row_to_json(t)::text) AS h FROM {} t) rows").format(identifier)
                cursor.execute(query)
                count, digest = cursor.fetchone()
                counts[schema + '.' + table] = count
                validation = sql.SQL("DO $$ DECLARE n bigint; h text; BEGIN SELECT * INTO n,h FROM ({} ) q; IF n <> {} OR h <> {} THEN RAISE EXCEPTION 'Restore content mismatch'; END IF; END $$;").format(query, sql.Literal(count), sql.Literal(digest))
                checks.append(validation.as_string(conn))
            checks.append("DO $$ BEGIN IF (SELECT version_num FROM alembic_version) <> 'e17d6a10bc25' THEN RAISE EXCEPTION 'Wrong revision'; END IF; END $$;")
            checks.append("SELECT 'RESTORE_CONTENT_AND_REVISION_VERIFIED' AS result;")
            (folder / 'verify_restore.sql').write_text('\n'.join(checks) + '\n', encoding='utf-8')
    metadata = {'database': database, 'revision': revision, 'snapshot_utc': started,
                'archive_sha256': hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest(),
                'table_counts': counts}
    (folder / 'evidence.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    print('Backup and private verification artifacts prepared; no restore performed.')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        raise SystemExit('Recovery preparation failed. Preserve private artifacts for authorized inspection; do not publish raw database errors.') from None
