#!/bin/bash

set -e

echo "Fetching submosules"
git submodule init
git submodule update

echo "Installing deps..."
# apt-get install python3 python3-dev -y
# apt install python3-mysqldb python-dev libmysqlclient-dev -y

pip3 install -r requirements.txt

echo "Installing opai-ng"

./pp/oppai-ng/build