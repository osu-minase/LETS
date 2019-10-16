#!/bin/bash

echo "Building opai-ng"
./pp/oppai-ng/build


echo "Building Cython code"

find . -name "*.c" -type f -delete
find . -name "*.o" -type f -delete
find . -name "*.so" -type f -delete
python3 setup.py build_ext --inplace