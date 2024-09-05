#!/bin/bash
source /etc/profile
echo "Running after install script"

printenv

ls -la /var/www/
ls -la /var/www/ttrek-app/
sh /var/www/ttrek-app/run.sh
