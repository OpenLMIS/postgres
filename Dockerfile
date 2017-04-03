FROM postgres:9.6

COPY init/ /docker-entrypoint-initdb.d

RUN echo "host all all 0.0.0.0/0 md5" > /var/lib/postgresql/data/pg_hba.conf