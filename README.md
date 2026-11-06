# OpenLMIS PostgreSQL Docker Image

Standard PostgreSQL image for OpenLMIS v3+ (`openlmis/postgres`). The image is the official
[postgis/postgis](https://hub.docker.com/r/postgis/postgis) image (itself based on the official
[postgres](https://hub.docker.com/_/postgres/) image) plus:

- `wal_level = logical` appended to the image's `postgresql.conf.sample` (`max_wal_senders` and
  `max_replication_slots` keep the PostgreSQL defaults of 10), so that the reporting stack (Debezium,
  `pgoutput`) can attach without any configuration;
- an init script that creates the `open_lmis` database with the `postgis` and `uuid-ossp` extensions.

The `12-debezium` and `14-debezium` tags were built on `debezium/postgres`. That base is no longer needed:
the reporting stack decodes WAL with the built-in `pgoutput` plugin; the 12/14 images preload
`decoderbufs,wal2json` and trust physical replication connections from anywhere
(`host replication postgres 0.0.0.0/0 trust`), and the Debezium 17 image additionally pulls PostGIS from
Debian *testing*. `openlmis/postgres:17` is the only new tag: a `14-debezium` data directory does not
start on it anyway, so every deployment switches to `OL_POSTGRES_VERSION=17` as part of its upgrade.

| Tag | Base | PostgreSQL | PostGIS |
|---|---|---|---|
| `17` | `postgis/postgis:17-3.6` (Debian trixie) | 17.x | 3.6 |
| `14-debezium` | `debezium/postgres:14` (Debian bullseye) | 14.x | 3.5 |
| `12-debezium` | `debezium/postgres:12` (Debian bullseye) | 12.x | 3.x |

Build and publish the image and the upgrade helper `openlmis/postgres-upgrade:14-to-17` (section 3).
The helper is published too, so that every site upgrades with the same tested tool instead of a local
build from floating package versions; it is built after the image because it starts
`FROM openlmis/postgres:17`:

```bash
docker build -t openlmis/postgres:17 .
docker build -t openlmis/postgres-upgrade:14-to-17 -f Dockerfile.upgrade .
docker push openlmis/postgres:17 && docker push openlmis/postgres-upgrade:14-to-17
```

Full configuration details (environment variables, `POSTGRES_INITDB_ARGS`, etc.) are in the official image docs.

## Upgrading PostgreSQL 14 → 17

PostgreSQL 14 reaches community end of life on 12 November 2026; Amazon RDS standard support ends on
2027-02-28, after which RDS either auto-enrols the instance in paid Extended Support or (when it is
disabled) upgrades it on its own schedule. This section is the tested procedure for OpenLMIS; the
numbers come from a copy of a production-size database (142 GB on RDS, 21 million large objects, PostGIS)
upgraded on RDS and — restored into a 14 container, 121 GB on disk — in Docker on an EC2 `m5.2xlarge`, in
November 2026 (OLMIS-8422). Every figure is a single run, not an average.

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
  only deprecated in PostgreSQL 18. The same applies to `selv-v3-report` (Spring Boot 1.5.9), verified
  in the SELV rehearsal. `pg_upgrade` keeps the stored hashes as they are, so check them before the
  upgrade: `select rolname, left(rolpassword, 14) from pg_authid where rolpassword is not null;` —
  `md5…` keeps working for those services, `SCRAM-SHA-256$…` breaks them already on 14 (self-hosted
  only: the RDS master user cannot read `pg_authid`; there, `password_encryption` in the parameter group
  at the time the password was set is the only evidence). Malawi, SELV and
  Eswatini set md5 during earlier upgrades; it matters for the path choice — paths B and C start from a
  fresh 17 container whose default `pg_hba.conf` accepts only SCRAM, so md5 roles cannot log in there
  (see section 4); path A and the RDS paths carry the old `pg_hba.conf` over.
- Extensions: PostGIS (facility locations, geographic zone boundaries) and `uuid-ossp`. A major upgrade
  never upgrades extensions; run the extension updates after the upgrade (below).
- `max_connections`: RDS reserves a few connections for its `rds_reserved` role
  (`rds.rds_reserved_connections`, default 4, present on 14 as well — not an upgrade change). Account for
  it if the setting is tight.
- Collation: Docker images changed the Debian release (bullseye → trixie, glibc 2.31 → 2.41), so text
  indexes must be rebuilt after a self-hosted upgrade (path A, step 8). RDS kept the same glibc in the test (no
  reindex needed), but that depends on the OS under the engine version: compare the collation version
  from the baseline (section 2) after every upgrade and reindex when it differs.
- `max_replication_slots` / `max_wal_senders`: 4 on the Debezium-based 14 image, 10 (the PostgreSQL
  defaults) on 17 — expected when comparing `show all` before and after.
- Logical decoding plugins: the 17 image ships only the built-in `pgoutput`, which the SolDevelo reporting
  stack uses. The legacy ref-distro reporting stack (`reporting/`, NiFi, Debezium 1.5) registers its
  connectors with `plugin.name=wal2json` and cannot run against this image — switch those connectors to
  `pgoutput` or keep that deployment on `14-debezium` until the legacy stack is retired.
- Large objects (`pg_largeobject`, used by `hapifhir.hfj_res_ver.res_text` and the DHIS2 integration) are
  preserved by `pg_upgrade` and by RDS in-place upgrades. They are **not** copied by logical replication
  (RDS Blue/Green, path C) and dominate the cost of dump/restore (path B).

### 2. Before any upgrade

Run these on the database and keep the output — it is the baseline for the verification step.

```sql
select version();
select pg_collation_actual_version(oid) from pg_collation
 where collname = 'en_US.utf8';                                           -- OS collation version (use your datcollate)
select extname, extversion from pg_extension order by 1;                 -- PostGIS version
select count(*) from pg_largeobject_metadata;                             -- large objects
select slot_name, plugin, active, wal_status from pg_replication_slots;   -- reporting stack slot
select pubname from pg_publication;                                       -- dbz_publication
select count(*) from pg_prepared_xacts;                                   -- must be 0
select schemaname||'.'||tablename from pg_tables t                        -- tables without a primary key
 where schemaname not in ('pg_catalog','information_schema')
   and not exists (select 1 from pg_constraint c join pg_class r on r.oid=c.conrelid
                   join pg_namespace n on n.oid=r.relnamespace
                   where c.contype='p' and n.nspname=t.schemaname and r.relname=t.tablename)
 order by 1;
select schemaname, sequencename, last_value from pg_sequences order by 1,2;
select n.nspname||'.'||c.relname, c.relispopulated from pg_class c         -- materialized views (count(*) on an
  join pg_namespace n on n.oid = c.relnamespace where c.relkind = 'm' order by 1;   -- unpopulated one errors out)
select name, setting, source from pg_settings                             -- every non-default setting
 where source not in ('default', 'override') order by 1;                  -- (compare after the upgrade)
select n.nspname||'.'||c.relname,                                         -- row counts of all tables
       (xpath('/row/c/text()', query_to_xml(format('select count(*) c from %I.%I', n.nspname, c.relname),
                                            false, true, '')))[1]::text::bigint
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind = 'r' and n.nspname not in ('pg_catalog','information_schema') order by 1;
```

The row counts take seconds on a demo database and minutes on a production-size one (it is a sequential
scan of every table); on large databases count the application tables you care about and add the content
checksums from section 8 for the big ones. In Docker run the block with
`docker compose exec db psql -U postgres -d open_lmis -f -` (paste, then `Ctrl-D`) or `-c "..."` per query.

Then:

1. Take a backup (RDS snapshot or a copy of the data volume) and test that you can restore it (restoring
   a 142 GB RDS snapshot into a new `db.m5.2xlarge` took 8 min 40 s to `available`; the volume then
   loads lazily, section 9). A `pg_dump` of the database alone is not a full backup: it has no roles and
   no grants (restoring the SELV dump reported 583 `role … does not exist` errors) — keep
   `pg_dumpall --globals-only` next to it.
2. Update PostGIS to the newest version available on the **current** major
   (`alter extension postgis update;` plus `postgis_topology`, `postgis_raster`, `postgis_tiger_geocoder`
   if installed). RDS requires this when skipping majors; on the Docker `14-debezium` image it is a no-op
   (the image ships only PostGIS 3.5.0, `version "3.5.0" of extension "postgis" is already installed`).
3. Detach the reporting stack (section 7): the Debezium replication slot blocks RDS upgrades and
   Blue/Green creation, and it does not survive `pg_upgrade` anyway. The publication and the
   `reporting_heartbeat` / `debezium_signal` tables survive every path (a whole-database `pg_dump` includes
   publications); re-apply the init SQL if `pg_publication` is empty afterwards.
4. Plan a window. Measured on the same data: RDS rows on `db.m5.2xlarge` (142 GB), Docker rows on an EC2
   `m5.2xlarge` with the 121 GB copy, 21 million large objects in both:

| Path | Application downtime | Total elapsed | Notes |
|---|---|---|---|
| A. Docker `pg_upgrade` | link mode ~47 min (+ ~11 min analyze and reindex); copy mode: 21 min for the 78 GB SELV database without large objects, of which ~17 min is the file copy (~4.6 GB/min on a default gp3 volume, 3000 IOPS / 125 MB/s) — expect ~26 min of copy for 121 GB, more on slower disks | ~1 h | copy mode keeps the old volume intact; link mode: no data copy, old cluster unusable after the new one starts |
| B. Docker dump/restore | ~4.8 h | ~4.8 h | 109 min dump + 136 min restore of the large objects alone; ~45 min without large objects |
| C. Docker logical replication | ~3 min | ~45 min | 37 min initial sync while production runs; manual copy of large objects and sequences |
| RDS in-place (Modify) | ~35 min | ~44–47 min to `available` | planner statistics are not carried over: `vacuumdb --analyze-in-stages` after `available` (~30 min on the freshly upgraded 142 GB instance); extensions updated in seconds |
| RDS Blue/Green | ~13 s (switchover 72 s) | ~1 h deployment | no large-object writes and no reporting stack during the deployment; `REPLICA IDENTITY FULL` on tables without a primary key |

Demo-size databases (ref-distro, ~200 MB) upgrade with path A in seconds. Measured end to end on a copy
of the SELV production database (78 GB, 297 tables, no large objects, one EC2 `m5.2xlarge`): 34 minutes
of downtime for path A in copy mode including the post-upgrade steps, rollback 64 seconds.

### 3. Path A — Docker, `pg_upgrade` into a new volume (recommended for self-hosted)

`pg_upgrade` reads the 14 data directory and writes a new 17 one. In copy mode (the default) the old
cluster is never modified, so the rollback is to point the deployment back at the old volume, and the new
volume keeps the stock layout (`<volume>:/var/lib/postgresql/data`, no `PGDATA` override). The price is a
second volume and the time to copy the relation files: seconds for demo-size data, ~17 minutes for the
78 GB SELV database on a default gp3 volume (~4.6 GB/min), so expect ~26 minutes for the 121 GB Malawi
copy on top of the 46 minutes `pg_upgrade` itself needed there in link mode. Link mode (variant below)
avoids the copy at the cost of a one-off re-layout of the volume and a riskier rollback.

`<old-volume>` below is the real name of the volume your compose file mounts at
`/var/lib/postgresql/data`: for a volume declared in the compose file it carries the project prefix
(ref-distro: `openlmis-ref-distro_olmis-db` for the key `olmis-db`), for an `external` volume it is the
key itself (SELV: `pgdata`) — check with `docker inspect <db container> --format '{{json .Mounts}}'`.
`<new-volume>` is any new name, e.g. `openlmis-ref-distro_olmis-db-17` or `pgdata-17`.

If the data volume holds a hand-edited `postgresql.conf` (SELV ships one with `shared_buffers = 512MB`,
`max_connections = 200` and the Debezium preload line), those settings are gone after the upgrade: the
new cluster takes `postgresql.conf` from the 17 image, and copying the old file over would stop 17 from
starting (preloaded libraries the image does not ship). Carry the deliberate values over with
`ALTER SYSTEM SET …` on 17 (step 7) — the baseline query on `pg_settings` lists them with
`source = 'configuration file'`.

1. Stop the application services but not the database —
   `docker compose stop $(docker compose config --services | grep -vxE 'db|consul|log|redis')` stops
   everything the compose file defines except the database and its infrastructure — and the reporting
   stack connector (section 7), then drop the slot; the form below is a no-op when the stack was never
   attached (append `</dev/null` to every `docker compose exec` that runs from a script or over
   `ssh … bash -s` — `exec` otherwise reads the rest of the script as its stdin and the following steps are
   skipped silently; `-T` alone only drops the pseudo-TTY and does not prevent that):
   `docker compose exec db psql -U postgres -d open_lmis -c "select pg_drop_replication_slot(slot_name) from pg_replication_slots where slot_name = 'debezium_reporting';"`.
2. Stop the database container (`docker compose stop db`). The old volume is the rollback: it stays a
   valid 14 cluster throughout. It is not byte-for-byte untouched, though — `pg_upgrade` (the `--check`
   call too) starts and stops the old postmaster, which rewrites catalog pages (hint bits), `pg_stat/`,
   `pg_xact/`, `pg_control` and WAL; no relation data changes, but a checksum of the directory taken
   before and after will differ.
3. Run the upgrade with the helper image `openlmis/postgres-upgrade:14-to-17` (`docker pull` it; build it
   from `Dockerfile.upgrade` only when the tag is not available to you). It is the 17 image plus the 14
   binaries and PostGIS for 14: the 17 side is pinned to the image's PostGIS version, the 14 side gets
   whichever 3.x PGDG shipped at build time, which may be newer than the 17 side (3.7.0 vs 3.6.4 in the
   published build — expected and harmless): `pg_upgrade` only needs `postgis-3` to exist on both sides,
   the catalog is updated to the image's version in step 5:

   ```bash
   docker volume create <new-volume>
   docker run --rm -v <old-volume>:/var/lib/postgresql/old -v <new-volume>:/var/lib/postgresql/new \
     openlmis/postgres-upgrade:14-to-17 bash -ec '
     OLDBIN=/usr/lib/postgresql/14/bin; NEWBIN=/usr/lib/postgresql/17/bin
     OLD=/var/lib/postgresql/old; NEW=/var/lib/postgresql/new
     chown postgres:postgres $NEW
     ctl=$(gosu postgres $OLDBIN/pg_controldata $OLD)
     CK=""; echo "$ctl" | grep -q "Data page checksum version:.*[1-9]" && CK=--data-checksums
     cd /tmp
     gosu postgres $NEWBIN/initdb -D $NEW --encoding=UTF8 $CK --username=postgres
     gosu postgres $NEWBIN/pg_upgrade -b $OLDBIN -B $NEWBIN -d $OLD -D $NEW \
       -o "-c shared_preload_libraries=" --check
     gosu postgres $NEWBIN/pg_upgrade -b $OLDBIN -B $NEWBIN -d $OLD -D $NEW \
       -o "-c shared_preload_libraries="
     cp $OLD/postgresql.auto.conf $NEW/
     grep -v "^host replication .* 0\.0\.0\.0/0 trust" $OLD/pg_hba.conf > $NEW/pg_hba.conf'
   ```

   The old directory is only read: `postgres` is uid 999 in the 14-debezium image, the helper and the 17
   image, so nothing in the script changes its ownership or contents. `initdb` uses the image's default locale, `en_US.utf8`, which is
   also what the `14-debezium` image initialised its clusters with; `pg_controldata` on 14 does not report
   the locale, so there is no detection — a cluster created with another locale fails the `--check` call
   with `lc_collate values for database "template1" do not match`, in which case rerun `initdb` with
   `--locale=<datcollate of the old cluster>` (`select datcollate from pg_database where datname = 'template1'`
   on 14). `-o "-c shared_preload_libraries="` (empty) is required: the 14-debezium image's `postgresql.conf` preloads
   `decoderbufs,wal2json`, which the upgrade image does not ship, so the old postmaster would not start.
   `--check` runs the prechecks (prepared transactions, required libraries including `postgis-3`) without
   touching anything; run it every time, right before the real call. No `-j`: OpenLMIS is one database in
   one tablespace, so parallel jobs gain nothing here, and with `-j > 1` the parallel restore raced against
   `pg_upgrade` recreating the `postgres` database with its old OID (`FATAL: database "postgres" does not
   exist … It seems to have just been dropped`) in 8 of 8 attempts on a 16-core host; one of those runs
   still printed `Upgrade Complete` while a relation file was missing from the new cluster. Both calls
   must end without a `*failure*` line and the second with `Upgrade Complete`; if the real call fails, do
   not rerun it on the half-written directory — recreate `<new-volume>` (copy mode) or restore the volume
   copy (link mode) first. The new `postgresql.conf` comes from the 17 image (`wal_level = logical`);
   `postgresql.auto.conf` (`ALTER SYSTEM` settings) and `pg_hba.conf` are copied by hand — `pg_upgrade`
   does not carry them over. The copy drops the `host replication postgres 0.0.0.0/0 trust` line that the
   Debezium base appended to every 14 cluster: it allows a passwordless `pg_basebackup` from any host that
   reaches the port, and Debezium does not need it (a logical replication connection is matched by the
   `host all all all` line, not by the `replication` keyword).
4. Switch the deployment to the 17 image and the new volume without editing the tracked
   `docker-compose.yml`: set `OL_POSTGRES_VERSION=17` in `.env` and add an override file next to it:

   ```yaml
   # docker-compose.pg17.yml
   volumes:
     olmis-db:            # the key your compose file mounts at /var/lib/postgresql/data (SELV: pgdata)
       name: <new-volume>
       external: true
   ```

   The key must match the one the `db` service mounts: Compose accepts an override for an unused key
   without a word, and the 17 container then starts on the old volume and dies with
   `database files are incompatible with server … initialized by PostgreSQL version 14` (no damage; seen
   in the SELV rehearsal). After the start, `docker inspect <db container> --format '{{json .Mounts}}'`
   must show `<new-volume>`.

   Start the database only: `docker compose -f docker-compose.yml -f docker-compose.pg17.yml up -d db`
   (consul comes up with it through `depends_on`). The entrypoint logs `Skipping initialization` because
   the directory already holds a cluster. If the reporting stack is attached, keep its overlay in the
   list as well (`-f docker-compose.yml -f docker-compose.reporting-stack.yml -f docker-compose.pg17.yml`,
   plus `docker-compose.reporting-dev.yml` where it is used): without it the database leaves the
   `reporting-shared` network and loses the `olmis-db` alias, so Kafka Connect cannot reach it. The least
   error-prone form is `COMPOSE_FILE=docker-compose.yml:docker-compose.reporting-stack.yml:docker-compose.pg17.yml`
   in `.env`, after which every plain `docker compose …` command below works unchanged. Use the same file
   list for every later command of this deployment; the rollback is to leave the `pg17` override out
   (remove the `COMPOSE_FILE` line). If deployments are scripted (SELV deploys over Docker TLS with
   `deploy_to_production_env.sh`, which copies `.env` from its credentials checkout and recreates every
   container), put `OL_POSTGRES_VERSION=17` and `COMPOSE_FILE` where that script takes `.env` from, and
   keep the override file next to the compose file on every machine that deploys — otherwise the next
   deployment silently starts 14 on the old volume again.
5. Update the extensions:
   `docker compose exec db psql -U postgres -d open_lmis -c 'alter extension postgis update; alter extension "uuid-ossp" update;'`
   (and `postgis_topology`, `postgis_raster`, `fuzzystrmatch`, `pg_buffercache`, `pgstattuple` where
   installed), then `select postgis_full_version();` must report no pending upgrade.
6. `docker compose exec db vacuumdb -U postgres --all --analyze-in-stages` (statistics are not carried
   over; 3 minutes for 121 GB). All client tools in the container need `-U postgres`, otherwise they
   connect as `root` and fail with `role "root" does not exist`.
7. Check the settings that must have survived, against the baseline:
   `docker compose exec db psql -U postgres -d open_lmis -c 'show wal_level' -c 'show max_connections' -c 'show password_encryption' -c 'show max_slot_wal_keep_size' -c 'select pubname from pg_publication'`
   — `wal_level` must be `logical`, the rest equal to the baseline; `pg_publication` lists
   `dbz_publication` only if the reporting stack was attached before the upgrade (empty otherwise, as in
   the baseline). Then diff the full `pg_settings` list from the baseline against the new cluster: expected
   differences are `shared_preload_libraries` (empty now), `max_wal_senders` / `max_replication_slots`
   (4 → 10) and the `lc_*` / `TimeZone` values written by `initdb`; anything else that came from a
   hand-edited `postgresql.conf` (SELV: `shared_buffers` 512MB → 128MB) is re-applied with
   `alter system set shared_buffers = '512MB';` and a restart of the container.
8. Rebuild the indexes: `docker compose exec db sh -c 'reindexdb -U postgres --all -j $(nproc)'`
   (8 minutes for 460 indexes / 121 GB). The image moved from glibc 2.31 to 2.41 and PostgreSQL cannot
   warn about it after an upgrade from 14 (`datcollversion` is written by the new `initdb`), so do it
   unconditionally. Then
   `docker compose exec db psql -U postgres -d open_lmis -c 'alter database open_lmis refresh collation version;'`.
9. Re-attach the reporting stack (section 7), start the application services (`docker compose up -d`),
   run the verification (section 8). With the reporting-stack overlay the start re-runs
   `reporting-stack-init`, which sets the publication back to the table list in
   `reporting-stack/init-db.sql` (`ALTER PUBLICATION … SET TABLE`): a table added by hand drops out of
   CDC silently while `verify-cdc` and `reconcile` stay green, so compare
   `select count(*) from pg_publication_tables where pubname = 'dbz_publication'` with the baseline after
   the start and keep every addition in `init-db.sql`. Delete the old volume
   (`docker volume rm <old-volume>`) only after the verification.

Rollback: stop the services, leave the override out, set `OL_POSTGRES_VERSION=14-debezium` and start
again; the old volume has not changed. Everything written on 17 after the cutover is lost — roll back
before resuming writes, or export those changes first.

#### Variant: link mode in the same volume (no second volume, no data copy)

`pg_upgrade --link` hard-links the relation files instead of copying them, so both data directories must be
in the same volume, and the old cluster becomes unusable the moment the new one starts. Use it when there
is no disk for a second volume or the copy time is not acceptable (link mode took 46 minutes on the 121 GB
Malawi copy, dominated by the schema restore of 21 million large objects). Differences from the steps above:

- Before step 3, keep a copy of the volume if you can afford the disk (`cp -a` of 121 GB took 11 minutes on
  gp3): it is the only rollback once the new cluster has started:

  ```bash
  docker volume create <copy>
  docker run --rm -v <volume>:/from:ro -v <copy>:/to alpine cp -a /from/. /to/
  ```

  Then re-layout the volume, once, in a throwaway container — the old data directory must end up at
  `<volume>/14/data` (owned by `postgres`, mode 0700, or the old postmaster refuses to start; the
  container runs as root, hence the `chown`) and an empty `<volume>/17/data` must exist:

  ```bash
  docker run --rm -v <volume>:/v openlmis/postgres:17 sh -c \
    'cd /v && mkdir -p 14/data 17/data && chown postgres:postgres 14/data 17/data && chmod 700 14/data && find . -mindepth 1 -maxdepth 1 ! -name 14 ! -name 17 -exec mv -t 14/data/ -- {} +'
  ```

- Step 3 runs with `-v <volume>:/var/lib/postgresql`, `OLD=/var/lib/postgresql/14/data`,
  `NEW=/var/lib/postgresql/17/data` and `--link` on both `pg_upgrade` calls.
- Step 4: keep the volume and move the data directory instead of switching volumes. The override must
  *replace* the stock mount (`!override`, Compose ≥ 2.24), otherwise the volume is mounted twice:

  ```yaml
  # docker-compose.pg17.yml (link mode)
  services:
    db:
      environment:
        PGDATA: /var/lib/postgresql/17/data
      volumes: !override
        - olmis-db:/var/lib/postgresql
  ```

  Remove the old `db` container before starting (`docker compose rm -sf db`, then the `up -d db` from
  step 4): Compose otherwise carries the previous container's mount for the image's
  `VOLUME /var/lib/postgresql/data` over, and `docker inspect` shows the volume root mounted there as
  well. PostgreSQL runs from `17/data` either way (`show data_directory`), and an empty root-owned `data`
  directory next to `14/` and `17/` is normal.
- Step 9: delete the old cluster in a throwaway container:
  `docker run --rm -v <volume>:/v openlmis/postgres:17 sh -c 'rm -rf /v/14/data'` (what the
  `delete_old_cluster.sh` that `pg_upgrade` prints would do). Optionally return to the stock layout
  afterwards: stop the database,
  `docker run --rm -v <volume>:/v openlmis/postgres:17 sh -c 'cd /v && mv 17/data/* . && rm -rf 14 17 data'`
  (same filesystem, instant; the data directory holds no dot files), drop the override and start with the
  stock compose file again.
- Rollback before the new cluster has started: `pg_upgrade` only renamed `14/data/global/pg_control` to
  `pg_control.old`; rename it back and start the 14 image with the volume at `/var/lib/postgresql` and
  `PGDATA=/var/lib/postgresql/14/data` (the stock mount would see an empty `data` root and refuse to
  start). After the new cluster has started: stop the database and restore the copy —
  `docker run --rm -v <copy>:/from:ro -v <volume>:/to alpine sh -c 'find /to -mindepth 1 -delete && cp -a /from/. /to/'` —
  then `OL_POSTGRES_VERSION=14-debezium` with the stock compose file. Writes made on 17 are lost.

Both variants were run end to end on a ref-distro demo database (178 MB: `pg_upgrade` 4 s, data identical
to the 14 baseline, link-mode rollback verified) and link mode additionally on the 121 GB Malawi copy.

### 4. Path B — Docker, dump and restore

Use it only when the database has no large objects or is small, or when the volume cannot be re-laid out.
Everything between the start of the dump and the end of the restore is downtime. Run every `pg_dump` /
`pg_restore` below from the 17 container against the 14 server (`-h <14 host>`): `--compress=lz4` needs
pg_dump 16+ and `--transaction-size` needs pg_restore 17. Keep the dump files on a host directory bind-mounted
into that container (`-v /backup:/dump`), not in the container's filesystem.

Passwords: a fresh 17 container writes `host all all all scram-sha-256` into its `pg_hba.conf`, and a role
whose password is still an md5 hash cannot authenticate against that method (verified: `password
authentication failed`, while the `md5` method accepts both hash kinds). Deployments that set
`password_encryption = md5` in an earlier upgrade (Malawi, SELV, Eswatini) therefore start the 17 container
with `-e POSTGRES_HOST_AUTH_METHOD=md5` (or copy the old `pg_hba.conf` into the new volume after the first
start) and keep `password_encryption = md5` as long as the Spring Boot 1.5 driver needs it; the alternative
is to reset every role's password on 17 so that it is re-hashed with SCRAM. The same applies to path C.
`pg_upgrade` (path A) is not affected: it carries the old `pg_hba.conf` over.

1. Start an empty 17 container (`openlmis/postgres:17`, a fresh volume). Its init script already creates
   `open_lmis` with `postgis` and `uuid-ossp`, so only the roles are missing — apply them without the
   superuser the image created:
   `pg_dumpall -h <14 host> -U postgres --globals-only | grep -v '^CREATE ROLE postgres;' | psql -U postgres`.
2. Tables: `pg_dump -Fd -j 8 --compress=lz4 --no-blobs` from 14, `pg_restore -j 8` into 17
   (7 + 34 minutes for 36 GB compressed / 112 GB restored).
3. Large objects: `pg_dump -Fc --compress=lz4 -a --exclude-table='*.*'` from 14 (one connection, one
   object at a time — 109 minutes for 21 million objects), then restore **only the large-object entries**:
   `pg_restore -l lobs.dump | grep -E ' BLOBS? ' > lobs.list`, then
   `pg_restore -d open_lmis -L lobs.list --transaction-size=1000 lobs.dump`
   (136 minutes). Do not use the `-n <nonexistent> -b` recipe from older guides — pg_dump 17 refuses it
   ("no matching schemas were found"). The pattern must be `'*.*'`: a bare `'*'` matches only the schemas
   on the search path, so the dump also carries the table data of every other schema (10× larger, with
   `--disable-triggers` warnings); the list filter keeps the restore correct either way.
4. Extensions, `ANALYZE`, verification as in path A (no reindex needed: the data was rewritten).

Rollback: the 14 container and its volume are untouched until you delete them; point the deployment back.

### 5. Path C — Docker, logical replication (minimal downtime, expert)

Production keeps running during the initial copy; the cutover window only covers large objects and
sequences. Measured: 37 minutes of initial sync, 2.7 minutes of cutover.

1. Start an empty 17 container reachable from the 14 one (with `POSTGRES_HOST_AUTH_METHOD=md5` if any role
   still has an md5 hash, see path B). Copy roles and the schema:
   `pg_dump --schema-only --no-publications --no-subscriptions | psql` (the `CREATE EXTENSION` statements
   pre-populate the PostGIS tables on 17 — exclude the extension schemas `postgis`, `tiger`,
   `tiger_data`, `topology` from the publication).
2. On 14: `alter table ... replica identity full` on every table without a primary key (26 in the Malawi
   application schemas; 28 with `reports` and `tiger`), otherwise UPDATE/DELETE on them fail on production as soon as the publication exists. Create
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

Rollback: keep 14 running until the verification passes; `drop subscription` on 17 and dropping the
publication on 14 undo everything.

### 6. RDS

#### In-place major version upgrade (recommended)

RDS runs `pg_upgrade` in link mode. Measured on `db.m5.2xlarge`, 142 GB, 21 million large objects:
35 minutes without connections (shutdown → `pg_upgrade` → restart), 47 minutes until the instance is
`available` again (the pre-upgrade and post-upgrade backups and the enhanced-monitoring reconfiguration
run before/after). AWS warns that millions of large objects need memory: at least 32 GB RAM for
25–30 million objects.

1. Prechecks: section 2 plus the RDS-specific ones. RDS refuses the upgrade (and leaves the instance on
   14) when any of these returns rows; the Debezium slot fails it too — drop it (section 7):

   ```sql
   select count(*) from pg_prepared_xacts;                                  -- must be 0
   select n.nspname, c.relname, a.attname from pg_attribute a              -- reg* columns (none in OpenLMIS)
     join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
    where a.atttypid in ('regproc'::regtype, 'regprocedure'::regtype, 'regoper'::regtype,
                         'regoperator'::regtype, 'regconfig'::regtype, 'regdictionary'::regtype)
      and c.relkind = 'r' and n.nspname not in ('pg_catalog', 'information_schema');
   select schemaname, viewname from pg_views                                -- views on pg_stat_activity
    where definition ilike '%pg_stat_activity%';
   select extname from pg_extension where extname like 'rdsadmin%';        -- rdsadmin extensions
   ```

   Then, with the AWS CLI: the target must be in
   `aws rds describe-db-engine-versions --engine postgres --engine-version <current 14.x> --query 'DBEngineVersions[0].ValidUpgradeTarget[?IsMajorVersionUpgrade].EngineVersion'`
   (from 14.22: 17.9, 17.10, 17.11 among others), and
   `aws rds describe-db-instances --db-instance-identifier <id> --query 'DBInstances[0].BackupRetentionPeriod'`
   must be greater than 0 — otherwise RDS takes no pre-upgrade snapshot and there is nothing to roll
   back to. A read replica is upgraded together with the primary and extends the outage; promote or
   delete it before and recreate it after.
2. Update PostGIS on 14 (`alter extension postgis update` etc.; 3.4.3 → 3.4.6 took 6 seconds).
3. Create the 17 parameter group. **Nothing is carried over**:

   ```bash
   aws rds create-db-parameter-group --db-parameter-group-name <pg17> --db-parameter-group-family postgres17 --description "OpenLMIS PostgreSQL 17"
   aws rds describe-db-parameters --db-parameter-group-name <pg14> --source user --query 'Parameters[].[ParameterName,ParameterValue]' --output text
   aws rds modify-db-parameter-group --db-parameter-group-name <pg17> --parameters \
     "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot" \
     "ParameterName=max_slot_wal_keep_size,ParameterValue=2048,ApplyMethod=immediate"
   ```

   Repeat every value the second command lists (`rds.logical_replication`, `password_encryption = md5` if
   still needed, `rds.force_ssl`, `min_wal_size`, …). Two things that list does not tell you: the
   `postgres17` family defaults to `rds.force_ssl = 1` (`postgres14`: 0), so an instance that never set it
   rejects every connection without TLS after the upgrade — set it to 0 explicitly if any client connects
   without SSL (`--source user` hides values equal to the family default, so compare the 17 group with
   `describe-db-parameters` without the filter); and if the 14 group has no `max_slot_wal_keep_size`
   (unlimited), this is the moment to add the 2 GB the reporting-stack docs require — it changes
   behaviour (the slot is invalidated instead of filling the storage). `max_wal_senders` is raised by RDS
   to 35 if set lower.
4. `aws rds modify-db-instance --db-instance-identifier <id> --engine-version 17.11 --db-parameter-group-name <pg17>
   --allow-major-version-upgrade --apply-immediately` (the newest minor the step 1 list shows; older
   17.x minors reach the end of RDS standard support earlier). RDS takes the pre-upgrade snapshot
   (`rds:preupgrade-<id>-14-22-to-17-11-<n>`, type `automated`), shuts the instance down, runs
   `pg_upgrade`, starts 17 and takes the post-upgrade backup. Progress: the instance status is
   `upgrading` and a `select 1` probe every few seconds shows the outage; `describe-events` reports
   `DB instance shutdown` first and `The engine version upgrade started` only near the end, so do not
   wait for that event. Logs under `describe-db-log-files`: `error/pg_upgrade_internal.log.<n>` and
   `error/pg_upgrade_server.log.<n>` (`pg_upgrade_precheck.log` appears only when the precheck fails).
   Measured twice on the same data: 35 min without connections, 44 and 47 min to `available`.
5. After `available`: `select postgis_extensions_upgrade();` plus `alter extension` for the others
   (seconds). Then, **before the application starts**,
   `vacuumdb -h <endpoint> -U <master user> -d <database> --analyze-in-stages` (not `--all`: it would also
   try `rdsadmin`, which the master user cannot connect to): RDS does not carry planner statistics over
   and does not analyze for you (15 minutes after the upgrade `pg_stats` covered 4 of 266
   tables in the test); it took 30 minutes on the 142 GB instance straight after the upgrade, on the
   lazily loaded volume. Verify the parameter group is `in-sync` (no reboot was needed in the test),
   `show wal_level` etc., and that `pg_collation_actual_version` still matches the baseline (it did in
   both tests: `2.26-59.amzn2` under 14 and 17). If it differs: `reindexdb -h <endpoint> -U <master user> -d <database> -j 4`
   from a client and `alter database <db> refresh collation version;` as in path A step 8 (over the
   network; the Docker test needed 8 minutes for 460 indexes on 121 GB).
6. Re-attach the reporting stack (section 7), verification (section 8).

Rollback: restore the automated pre-upgrade snapshot
(`aws rds describe-db-snapshots --db-instance-identifier <id> --snapshot-type automated`, name
`rds:preupgrade-…`) into a new instance (8 min 40 s to `available` for 142 GB on `db.m5.2xlarge`) and
repoint the application, or swap the identifiers (`modify-db-instance --new-db-instance-identifier`) so
that the endpoint stays; the upgraded instance cannot be downgraded. That snapshot is automated: it expires
with the retention period and is deleted together with the instance, so copy it to a manual one right
after `available` (`aws rds copy-db-snapshot`) and keep it until the verification has passed. Every write
made on 17 is lost by the rollback — decide go/no-go before the application resumes writes; afterwards fix
forward on 17 rather than back. The reporting stack must be re-attached with a full re-snapshot after a
rollback (section 7, `recover-slot`): ClickHouse already holds changes the restored database never saw.

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
  `replica identity full` on them first (28 tables in the Malawi database, among them
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

A demo-style instance running `spring_profiles_active=demo-data,refresh-db` must be switched to
`production` (after the demo data is loaded) before the stack is attached, and stay so through the
upgrade: every start under `refresh-db` recreates the schemas, which floods the connector with deletes and
inserts and drops the recreated tables from the publication.

Before the upgrade, with application writes already stopped:

1. Stop the connect watchdog — from the reporting-stack repository root,
   `docker compose --env-file .env -f compose/docker-compose.yml stop connect-watchdog` (the compose file
   lives in `compose/`, a bare `docker compose stop` finds nothing). It re-registers a missing connector
   within a minute and will otherwise start a full snapshot the moment the database is back.
2. Pause the Airflow DAG `platform_refresh`.
3. Wait until the slot has no lag, then stop the connector and reset its offsets:
   `PUT /connectors/openlmis-postgres-cdc/stop`, wait until `/status` reports `STOPPED` (stop is
   asynchronous and the reset is rejected before that), `DELETE /connectors/openlmis-postgres-cdc/offsets`,
   `DELETE /connectors/openlmis-postgres-cdc`. Resetting the offsets is mandatory: with stale offsets the
   re-registered task fails (`Last recorded offset is no longer available on the server`) and the changes
   made after the upgrade are lost for the stack.
4. `select pg_drop_replication_slot('debezium_reporting');`

After the upgrade, before application writes resume:

5. Check `wal_level = logical` and the other CDC parameters on the new cluster, and that the publication
   and the heartbeat/signal tables are there; re-apply the CDC init SQL if not (it is idempotent).
6. Register the connector with `DEBEZIUM_SNAPSHOT_MODE=no_data` (`make register-connector`): the new slot
   is created immediately, no snapshot runs, streaming starts from now. Measured: 13–21 seconds.
7. Resume writes, start the watchdog and the DAG, run `make reconcile`, then `make register-connector` once
   more with the default snapshot mode so that the stored config is back to `when_needed`. After the
   application is up, re-check the publication table count (path A, step 9).

If writes could not be blocked between steps 3 and 6, use `FORCE=1 SKIP_DBT=1 make recover-slot` instead
of step 6: it re-snapshots every captured table (30–60 minutes for the Malawi tables); run
`make initial-dbt-build` only after the snapshot has finished (row counts per table, not the connector
state). Each re-snapshot appends a full copy to the raw tables; purge the previous snapshot's `op = 'r'`
rows afterwards or the staging models will outgrow the ClickHouse memory limit.

### 8. Verification

Compare with the baseline from section 2 after every path: `select version()`, extension versions,
`count(*) from pg_largeobject_metadata`, row counts of all tables, `pg_sequences`, and content checksums
of the tables you care about, e.g.
`select md5(string_agg(h, '' order by h)) from (select md5(t::text) h from <schema>.<table> t) s;`.
In the OLMIS-8422 tests every path produced identical row counts, sequences, large objects (metadata and
content) and checksums; the only differences were the PostGIS topology metadata tables rewritten by the
extension update. Then start the services and check that Flyway found nothing to do: the services log
Flyway only at WARN level, so compare `select count(*), max(installed_rank) from <schema>.schema_version`
(`flyway_schema_history` in the newer services) before and after the start — equal means no pending
migrations. Note that `spring_profiles_active=demo-data,refresh-db` (the ref-distro default) recreates the
schemas on every start, so compare the data *before* starting the services on such an instance. Then log
in and run the main flows (requisition submit/authorize/approve, stock adjustment, order print, a Jasper
report, notifications).

### 9. Pitfalls seen in the tests

- `pg_dump -Fd` writes one file per large object — 21 million files; never use the directory format on a
  database with large objects.
- A publication `FOR ALL TABLES` (left over from older reporting experiments) breaks UPDATE/DELETE on
  every table without a primary key; the ref-distro init SQL uses an explicit list.
- Restoring an RDS snapshot gives a lazily loaded volume: the first full read of 142 GB took 77 minutes.
  Warm it up before measuring anything.
