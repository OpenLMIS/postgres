FROM postgres:9.4

COPY init/ /docker-entrypoint-initdb.d
