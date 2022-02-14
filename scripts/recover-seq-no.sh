#!/usr/bin/env bash

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

export line=$(docker-entrypoint.sh mysqld --wsrep-recover 2>&1 | grep "Recovered position:" | xargs echo) && echo -n ${line##*:} >/scripts/seqno
