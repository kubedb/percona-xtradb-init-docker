#!/usr/bin/env bash

if [ "$(ls -A /var/lib/mysql | grep -v 'lost+found' | wc -l)" -eq 0 ]; then
    echo -n "Empty"
else
    echo -n "Not Empty"
fi
