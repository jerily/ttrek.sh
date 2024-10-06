#!/bin/bash
source /etc/profile
echo "Running after install script"

printenv

ls -la /app/
sh /app/run.sh
