FROM mdillon/postgis:9.6

RUN apt-get update \
  && apt-get install -y --no-install-recommends postgresql-contrib \
  && rm -rf /var/lib/apt/lists/*

COPY init/ /docker-entrypoint-initdb.d

RUN echo "host all all 0.0.0.0/0 md5" > /var/lib/postgresql/data/pg_hba.conf