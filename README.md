# OpenLMIS PostgreSQL Docker Image

Standard PostgreSQL image for OpenLMIS v3+ (`openlmis/postgres`). The image is the official
[postgis/postgis](https://hub.docker.com/r/postgis/postgis) image (itself based on the official
[postgres](https://hub.docker.com/_/postgres/) image) plus:

- `postgresql.conf.sample` with `wal_level = logical`, `max_wal_senders = 10`, `max_replication_slots = 10`,
  so that the reporting stack (Debezium, `pgoutput`) can attach without any configuration;
- an init script that creates the `open_lmis` database with the `postgis` and `uuid-ossp` extensions.

The `12-debezium` and `14-debezium` tags were built on `debezium/postgres`. That base is no longer needed:
the reporting stack decodes WAL with the built-in `pgoutput` plugin, and the Debezium image additionally
pulls PostGIS from Debian *testing*, preloads `decoderbufs` and trusts replication connections from anywhere.
`openlmis/postgres:17` is published with the alias `17-debezium` so that `OL_POSTGRES_VERSION=17-debezium`
keeps working in existing deployments.

| Tag | Base | PostgreSQL | PostGIS |
|---|---|---|---|
| `17`, `17-debezium` | `postgis/postgis:17-3.6` (Debian trixie) | 17.x | 3.6 |
| `14-debezium` | `debezium/postgres:14` (Debian bullseye) | 14.x | 3.5 |
| `12-debezium` | `debezium/postgres:12` (Debian bullseye) | 12.x | 3.x |

Build: `docker build -t openlmis/postgres:17 .`
Full configuration details (environment variables, `POSTGRES_INITDB_ARGS`, etc.) are in the official image docs.

## Upgrading PostgreSQL 14 → 17

PostgreSQL 14 reached community end of life in November 2026; Amazon RDS standard support ends on
2027-02-28, after which RDS either auto-enrols the instance in paid Extended Support or (when it is
disabled) upgrades it on its own schedule. This section is the tested procedure for OpenLMIS; the
numbers come from a copy of a production-size database (142 GB, 21 million large objects, PostGIS)
upgraded on RDS and in Docker in November 2026 (OLMIS-8422).

### 1. What changes for OpenLMIS

- No code changes are needed. All core services (JDBC driver `42.6.2`, Flyway `6.0.8`, Spring Boot 2.2,
  Hibernate 5.4) start, migrate, load demo data and pass their unit and integration test suites against
  17.x. Flyway only logs `Flyway upgrade recommended: PostgreSQL 17.x is newer than this version of Flyway
  and support has not been tested` — the same warning it has logged on 14.
- `password_encryption`: PostgreSQL 14+ hashes new passwords with SCRAM-SHA-256 by default. Services on
  pgjdbc ≥ 42.2.1 connect fine. Only services still on the Spring Boot 1.5 driver `9.4.1212`
  (e.g. `mw-reports`) cannot speak SCRAM (`The authentication type 10 is not supported`) and need either
  `password_encryption = md5` plus a re-set password and an `md5` line in `pg_hba.conf` (RDS accepts
  both: `rds.accepted_password_auth_method = md5+scram`), or a driver bump. md5 still works on 17 and is
  only deprecated in PostgreSQL 18.
- Extensions: PostGIS (facility locations, geographic zone boundaries) and `uuid-ossp`. A major upgrade
  never upgrades extensions; run the extension updates after the upgrade (below).
- `max_connections`: RDS 17 reserves a few slots for the new `rds_reserved` role
  (`rds.rds_reserved_connections`, default 4). Account for it if the setting is tight.
- Collation: Docker images changed the Debian release (bullseye → trixie, glibc 2.31 → 2.41), so text
  indexes must be rebuilt after a self-hosted upgrade (step A.9). RDS keeps the same glibc; no reindex.
- Large objects (`pg_largeobject`, used by `hapifhir.hfj_res_ver.res_text` and the DHIS2 integration) are
  preserved by `pg_upgrade` and by RDS in-place upgrades. They are **not** copied by logical replication
  (RDS Blue/Green, path C) and dominate the cost of dump/restore (path B).

### 2. Before any upgrade

Run these on the database and keep the output — it is the baseline for the verification step.

```sql
select version();
select extname, extversion from pg_extension order by 1;                 -- PostGIS version
select count(*) from pg_largeobject_metadata;                             -- large objects
select slot_name, plugin, active, wal_status from pg_replication_slots;   -- reporting stack slot
select pubname from pg_publication;                                       -- dbz_publication
select count(*) from pg_prepared_xacts;                                   -- must be 0
select schemaname||'.'||tablename from pg_tables t                        -- tables without a primary key
 where schemaname not in ('pg_catalog','information_schema')
   and not exists (select 1 from pg_constraint c join pg_class r on r.oid=c.conrelid
                   join pg_namespace n on n.oid=r.relnamespace
                   where c.contype='p' and n.nspname=t.schemaname and r.relname=t.tablename);
select schemaname, sequencename, last_value from pg_sequences order by 1,2;
```

Then:

1. Take a backup (RDS snapshot or a copy of the data volume) and test that you can restore it.
2. Update PostGIS to the newest version available on the **current** major
   (`alter extension postgis update;` plus `postgis_topology`, `postgis_raster`, `postgis_tiger_geocoder`
   if installed). RDS requires this when skipping majors.
3. Detach the reporting stack (section 7): the Debezium replication slot blocks RDS upgrades and
   Blue/Green creation, and it does not survive `pg_upgrade` anyway. The publication and the
   `reporting_heartbeat` / `debezium_signal` tables survive every path except dump/restore.
4. Plan a window. Measured on a 142 GB database with 21 million large objects on `db.m5.2xlarge`:

| Path | Application downtime | Total elapsed | Notes |
|---|---|---|---|
| A. Docker `pg_upgrade --link` | ~47 min (+ ~11 min analyze and reindex) | ~1 h | no data copy, old cluster unusable after the new one starts |
| B. Docker dump/restore | ~4.8 h | ~4.8 h | 109 min dump + 136 min restore of the large objects alone; ~45 min without large objects |
| C. Docker logical replication | ~3 min | ~45 min | 37 min initial sync while production runs; manual copy of large objects and sequences |
| RDS in-place (Modify) | ~35 min | ~47 min to `available` | RDS runs `ANALYZE` itself; extensions updated in seconds afterwards |
| RDS Blue/Green | ~13 s (switchover 72 s) | ~1 h deployment | no large-object writes and no reporting stack during the deployment; `REPLICA IDENTITY FULL` on tables without a primary key |

Demo-size databases (ref-distro, ~200 MB) upgrade with path A in seconds.

### 3. Path A — Docker, `pg_upgrade --link` (recommended for self-hosted)

The 14 data directory and the new 17 directory must be in the same Docker volume (hard links do not work
across volumes). Existing deployments keep the data directory at the root of the volume
(`olmis-db:/var/lib/postgresql/data`); move it into a subdirectory once, inside the volume, which is
instant.

1. Stop the application services and the reporting stack connector, drop the slot:
   `select pg_drop_replication_slot('debezium_reporting');` (section 7).
2. Stop the database container. Keep a copy of the volume if you can afford the disk
   (`cp -a` of 121 GB took 11 minutes on gp3); it is the only rollback once the new cluster has started.
3. Re-layout the volume (one-off): mount it in a throwaway container and run
   `mkdir 14 17 && mv -- !(14|17) 14/ && mkdir 14/data 17/data && mv 14/* 14/data/` — or equivalently
   `mkdir -p /v/14 && mv /v/data /v/14/data && mkdir -p /v/17/data`. The old data directory must end up at
   `<volume>/14/data` and an empty `<volume>/17/data` must exist.
4. Run the upgrade with the helper image built from `Dockerfile.upgrade` (17 image plus the 14 binaries and
   PostGIS for both):

   ```bash
   docker build -t openlmis/postgres-upgrade:14-to-17 -f Dockerfile.upgrade .
   docker run --rm -v olmis-db:/var/lib/postgresql openlmis/postgres-upgrade:14-to-17 bash -ec '
     OLDBIN=/usr/lib/postgresql/14/bin; NEWBIN=/usr/lib/postgresql/17/bin
     OLD=/var/lib/postgresql/14/data; NEW=/var/lib/postgresql/17/data
     chown -R postgres:postgres /var/lib/postgresql
     ctl=$(gosu postgres $OLDBIN/pg_controldata $OLD)
     CK=""; echo "$ctl" | grep -q "Data page checksum version:.*[1-9]" && CK=--data-checksums
     LOC=$(echo "$ctl" | sed -n "s/^LC_COLLATE: *//p")
     cd /tmp
     gosu postgres $NEWBIN/initdb -D $NEW --locale="$LOC" --encoding=UTF8 $CK --username=postgres
     gosu postgres $NEWBIN/pg_upgrade --link -j $(nproc) -b $OLDBIN -B $NEWBIN -d $OLD -D $NEW \
       -o "-c shared_preload_libraries=''" --check
     gosu postgres $NEWBIN/pg_upgrade --link -j $(nproc) -b $OLDBIN -B $NEWBIN -d $OLD -D $NEW \
       -o "-c shared_preload_libraries=''"
     cp $OLD/postgresql.auto.conf $NEW/ && cp $OLD/pg_hba.conf $NEW/'
   ```

   `-o "-c shared_preload_libraries=''"` is required: the 14-debezium image's `postgresql.conf` preloads
   `decoderbufs,wal2json`, which the upgrade image does not ship, so the old postmaster would not start.
   `--check` runs the prechecks (prepared transactions, required libraries including `postgis-3`) without
   touching anything. The new `postgresql.conf` comes from the 17 image (`wal_level = logical`);
   `postgresql.auto.conf` (`ALTER SYSTEM` settings) and `pg_hba.conf` are copied by hand — `pg_upgrade`
   does not carry them over.
5. Switch the deployment to the 17 image and the new data directory: `OL_POSTGRES_VERSION=17` and, for
   the `db` service, `environment: PGDATA=/var/lib/postgresql/17/data` with the volume mounted at
   `/var/lib/postgresql` (the init scripts are skipped because the directory already holds a cluster).
   Start the database only.
6. Update the extensions: `alter extension postgis update; alter extension "uuid-ossp" update;`
   (and `postgis_topology`, `postgis_raster`, `fuzzystrmatch`, `pg_buffercache`, `pgstattuple` where
   installed), then `select postgis_full_version();` must report no pending upgrade.
7. `vacuumdb --all --analyze-in-stages` (statistics are not carried over; 3 minutes for 121 GB).
8. Check the settings that must have survived: `show wal_level;` (`logical`), `max_connections`,
   `password_encryption`, `max_slot_wal_keep_size`, and that `pg_publication` still lists
   `dbz_publication`.
9. Rebuild the indexes: `reindexdb --all -j $(nproc)` (8 minutes for 460 indexes / 121 GB). The image
   moved from glibc 2.31 to 2.41 and PostgreSQL cannot warn about it after an upgrade from 14
   (`datcollversion` is written by the new `initdb`), so do it unconditionally. Then
   `alter database open_lmis refresh collation version;`.
10. Re-attach the reporting stack (section 7), start the application services, run the verification
    (section 8). The old cluster can be deleted with the `delete_old_cluster.sh` that `pg_upgrade` leaves in
    `17/data` — only after the verification.

Rollback: before step 5 nothing has changed in `14/data` except `global/pg_control` renamed to
`pg_control.old`; rename it back and start 14. After the new cluster has started, restore the copy from
step 2.

### 4. Path B — Docker, dump and restore

Use it only when the database has no large objects or is small, or when the volume cannot be re-laid out.
Everything between the start of the dump and the end of the restore is downtime.

1. Start an empty 17 container (`openlmis/postgres:17`, a fresh volume), create the roles
   (`pg_dumpall --globals-only` from 14, filtered) and the database.
2. Tables: `pg_dump -Fd -j 8 --compress=lz4 --no-blobs` from 14, `pg_restore -j 8` into 17
   (7 + 34 minutes for 36 GB compressed / 112 GB restored).
3. Large objects: `pg_dump -Fc --compress=lz4 -a --exclude-table='*'` from 14 (one connection, one object at
   a time — 109 minutes for 21 million objects), then restore **only the large-object entries**:
   `pg_restore -l archive | grep -E ' BLOBS? ' > lobs.list; pg_restore -L lobs.list --transaction-size=1000`
   (136 minutes). Do not use the `-n <nonexistent> -b` recipe from older guides — pg_dump 17 refuses it
   ("no matching schemas were found"), and `--exclude-table='*'` may still include table data depending on
   the user and search path, hence the list filter.
4. Extensions, `ANALYZE`, verification as in path A (no reindex needed: the data was rewritten).

### 5. Path C — Docker, logical replication (minimal downtime, expert)

Production keeps running during the initial copy; the cutover window only covers large objects and
sequences. Measured: 37 minutes of initial sync, 2.7 minutes of cutover.

1. Start an empty 17 container reachable from the 14 one. Copy roles and the schema:
   `pg_dump --schema-only --no-publications --no-subscriptions | psql` (the `CREATE EXTENSION` statements
   pre-populate the PostGIS tables on 17 — exclude the extension schemas `postgis`, `tiger`,
   `tiger_data`, `topology` from the publication).
2. On 14: `alter table ... replica identity full` on every table without a primary key (26 in the Malawi
   schema), otherwise UPDATE/DELETE on them fail on production as soon as the publication exists. Create
   the publication with an explicit table list (all application schemas).
3. On 17: `create subscription ... with (copy_data = true)`; wait until every row of
   `pg_subscription_rel` has `srsubstate = 'r'`.
4. Cutover (writes blocked): copy the large objects — as a superuser the raw copy of `pg_largeobject` and
   `pg_largeobject_metadata` with `COPY ... (FORMAT binary)` in 8 parallel streams took 129 seconds, while
   `pg_dump`/`pg_restore` of the same objects takes hours (path B) — remap `lomowner` to the local role
   OID; `setval()` every sequence to the publisher's `last_value` (32 seconds); confirm the apply lag is
   zero; `drop subscription`.
5. Extensions, `ANALYZE`, verification. Drop the publication and reset the replica identities on 14 if the
   old cluster is kept.

### 6. RDS

#### In-place major version upgrade (recommended)

RDS runs `pg_upgrade` in link mode. Measured on `db.m5.2xlarge`, 142 GB, 21 million large objects:
35 minutes without connections (shutdown → `pg_upgrade` → restart), 47 minutes until the instance is
`available` again (the pre-upgrade and post-upgrade backups and the enhanced-monitoring reconfiguration
run before/after). AWS warns that millions of large objects need memory: at least 32 GB RAM for
25–30 million objects.

1. Prechecks (section 2). `rdsadmin` extensions, prepared transactions, `reg*` columns and views on
   `pg_stat_activity` fail the precheck; the Debezium slot fails it too — drop it (section 7). A read
   replica is upgraded together with the primary and extends the outage; promote or delete it before and
   recreate it after.
2. Update PostGIS on 14 (`alter extension postgis update` etc.).
3. Create the 17 parameter group. **Nothing is carried over**: set `rds.logical_replication = 1`,
   `password_encryption = md5` (if still needed), `rds.force_ssl`, `max_slot_wal_keep_size` (2 GB in the
   reporting-stack docs), `min_wal_size` and anything else `describe-db-parameters --source user` shows
   on the 14 group. `max_wal_senders` is raised by RDS to 35 if set lower.
4. `aws rds modify-db-instance --engine-version 17.11 --db-parameter-group-name <pg17>
   --allow-major-version-upgrade --apply-immediately` (17.5/17.6 leave standard support in October 2026;
   use the newest minor). Watch `describe-events` (`pre-check started/finished`, `DB instance shutdown`,
   `Backing up`, `available`) and the logs `pg_upgrade_precheck.log`, `pg_upgrade_internal.log`,
   `pg_upgrade_server.log` under `describe-db-log-files`.
5. After `available`: `select postgis_extensions_upgrade();` plus `alter extension` for the others
   (7 seconds). RDS has already run `ANALYZE` on every table. Verify the parameter group is `in-sync`
   (no reboot was needed in the test), `show wal_level` etc.
6. Re-attach the reporting stack (section 7), verification (section 8).

Rollback: restore the snapshot RDS took before the upgrade into a new instance and repoint the
application; the upgraded instance cannot be downgraded.

#### Blue/Green deployment (13 seconds of switchover, strict preconditions)

Green is a physical copy of blue upgraded to 17 and kept in sync by logical replication; the switchover
renames the instances and endpoints. Measured: deployment `AVAILABLE` after 55 minutes (replica 10–15,
upgrade 38–44, backups 3) plus ~9 minutes of green `modifying` before it accepts the switchover;
switchover 72 seconds, of which the endpoint did not answer for 13 seconds; sequences were synchronized
at switchover. Hard constraints found in the test:

- The Debezium slot blocks the creation: "Creation of blue/green deployment failed due to external
  replication on the blue primary instance". Detach the reporting stack for the whole deployment.
- One `lo_create`/`lo_write` on blue during the deployment degrades the replication within two minutes
  ("Replication has been degraded"); the deployment must then be deleted and recreated. Stop every
  service that writes large objects (hapifhir, dhis2-integration) for the whole hour.
- UPDATE/DELETE on tables without a primary key fail on production for the whole deployment
  (`cannot update table ... does not have a replica identity and publishes updates`) — set
  `replica identity full` on them first (28 tables in the Malawi schema, among them
  `auth.oauth_access_token` and `requisition.available_products`).
- DDL is not replicated (no Flyway migrations, no deployments during the window).
- Green does not get the extension updates nor statistics: run `postgis_extensions_upgrade()` and
  `vacuumdb --analyze-in-stages` (7.6 minutes) after the switchover, then delete the old blue.

Use it only when the ~35 minute outage of the in-place path is unacceptable and the preconditions can
be met; otherwise the in-place upgrade is simpler and safer.

### 7. Detaching and re-attaching the reporting stack

The stack (Debezium on Kafka Connect, `pgoutput`, slot `debezium_reporting`, publication
`dbz_publication`) must be stopped cleanly before and re-attached after. The full runbook is in the
reporting-stack repository (`docs/runbook-source-upgrade.md`); the short version:

Before the upgrade, with application writes already stopped:

1. Stop the connect watchdog (`docker compose stop connect-watchdog`) — it re-registers a missing
   connector within a minute and will otherwise start a full snapshot the moment the database is back.
2. Pause the Airflow DAG `platform_refresh`.
3. Wait until the slot has no lag, then stop the connector and reset its offsets:
   `PUT /connectors/openlmis-postgres-cdc/stop`, `DELETE /connectors/openlmis-postgres-cdc/offsets`,
   `DELETE /connectors/openlmis-postgres-cdc`. Resetting the offsets is mandatory: with stale offsets the
   re-registered task fails (`Last recorded offset is no longer available on the server`) and the changes
   made after the upgrade are lost for the stack.
4. `select pg_drop_replication_slot('debezium_reporting');`

After the upgrade, before application writes resume:

5. Re-apply the CDC init SQL if the path was dump/restore (publication, heartbeat and signal tables); the
   other paths keep them.
6. Register the connector with `DEBEZIUM_SNAPSHOT_MODE=no_data` (`make register-connector`): the new slot
   is created immediately, no snapshot runs, streaming starts from now. Measured: 21 seconds.
7. Resume writes, start the watchdog and the DAG, run `make reconcile`.

If writes could not be blocked between steps 3 and 6, use `FORCE=1 make recover-slot` instead of step 6:
it re-snapshots every captured table (30–60 minutes for the Malawi tables) and dbt deduplicates. Each
re-snapshot appends a full copy to the raw tables; purge the previous snapshot's `op = 'r'` rows
afterwards or the staging models will outgrow the ClickHouse memory limit.

### 8. Verification

Compare with the baseline from section 2 after every path: `select version()`, extension versions,
`count(*) from pg_largeobject_metadata`, row counts of all tables, `pg_sequences`, and content checksums
of the tables you care about, e.g.
`select md5(string_agg(h, '' order by h)) from (select md5(t::text) h from <schema>.<table> t) s;`.
In the OLMIS-8422 tests every path produced identical row counts, sequences, large objects (metadata and
content) and checksums; the only differences were the PostGIS topology metadata tables rewritten by the
extension update. Then start the services (Flyway must report no pending migrations), log in, and run
the main flows (requisition submit/authorize/approve, stock adjustment, order print, a Jasper report,
notifications).

### 9. Pitfalls seen in the tests

- `pg_dump -Fd` writes one file per large object — 21 million files; never use the directory format on a
  database with large objects.
- A publication `FOR ALL TABLES` (left over from older reporting experiments) breaks UPDATE/DELETE on
  every table without a primary key; the ref-distro init SQL uses an explicit list.
- Restoring an RDS snapshot gives a lazily loaded volume: the first full read of 142 GB took 77 minutes.
  Warm it up before measuring anything.
- Kafka in the reporting stack writes to `/tmp/kafka-logs` inside the container, not to the mounted
  volume; two full snapshots filled a 400 GB disk.
