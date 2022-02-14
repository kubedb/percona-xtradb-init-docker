#!/usr/bin/env bash

script_name=${0##*/}

function timestamp() {
    date +"%Y/%m/%d %T"
}

function log() {
    local type="$1"
    local msg="$2"
    echo "$(timestamp) [$script_name] [$type] $msg"
}

# include directory in my.cnf for custom-config
if [ ! -z "$(ls -A /etc/mysql/custom.conf.d/)" ]; then
    echo '!includedir /etc/mysql/custom.conf.d/' >>/etc/mysql/my.cnf
fi

while [ true ]; do
    log "INFO" "initializing run.sh"

    # clean up old files
    rm -rf /run-script/*
    if [ -f "/scripts/peer-list" ]; then
        rm /scripts/peer-list
    fi

    if [ -f "/scripts/seqno" ]; then
        rm /scripts/seqno
    fi

    # start on-start script
    ./scripts/on-start.sh $@
    sleep 1
done
