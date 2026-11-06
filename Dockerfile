FROM postgis/postgis:17-3.6

# Base init would also load PostGIS into template_postgis and the default database; open_lmis gets it from init/.
RUN rm /docker-entrypoint-initdb.d/10_postgis.sh \
    && echo "wal_level = logical" >> /usr/share/postgresql/postgresql.conf.sample

COPY init/ /docker-entrypoint-initdb.d
