FROM debezium/postgres:14

COPY init/ /docker-entrypoint-initdb.d
