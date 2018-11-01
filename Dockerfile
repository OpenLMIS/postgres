FROM debezium/postgres:9.6-alpine

COPY init/ /docker-entrypoint-initdb.d