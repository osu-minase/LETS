#!/bin/bash

set -e

echo "Latest local commit"
git log -1

echo "Pulling changes from GitHub"
git pull

echo "Updating submodules"
git submodule update

echo "Building"
./scripts/clean_build.sh
