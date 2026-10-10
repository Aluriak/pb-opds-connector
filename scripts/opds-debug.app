#!/bin/sh
LOG=/mnt/ext1/opds-log.txt
BIN="/mnt/ext1/applications/OPDS Connector.bin"
echo "== run" >> $LOG
"$BIN" >> $LOG 2>&1
echo "exit code: $?" >> $LOG
