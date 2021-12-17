FROM debezium/postgres:12

COPY init/ /docker-entrypoint-initdb.d