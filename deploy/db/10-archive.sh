#!/bin/sh
# Runs once, when the database is first created: turns on WAL archiving.
set -e
echo "include '/usr/local/share/kick_tracker/archive.conf'" >> "$PGDATA/postgresql.conf"
