FROM postgis/postgis:17-3.6

# The base image's 10_postgis.sh would also create template_postgis and load PostGIS into the default
# database; OpenLMIS only needs the extensions in open_lmis, exactly as the 14-debezium image did.
RUN rm /docker-entrypoint-initdb.d/10_postgis.sh

COPY postgresql.conf.sample /usr/share/postgresql/postgresql.conf.sample
COPY init/ /docker-entrypoint-initdb.d
