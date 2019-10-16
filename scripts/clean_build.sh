#!/bin/bash

echo "Building opai-ng"
cd ./pp/oppai-ng
git stash # fixme
./build
# and return back
cd -

echo "Building Cython code"

find . -name "*.c" -type f -delete
find . -name "*.o" -type f -delete
find . -name "*.so" -type f -delete
python3 setup.py build_ext --inplace