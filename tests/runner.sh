#!/bin/bash

SBDD_PATH="/sbdd"
TOOLCHAIN_ENV="/opt/rh/gcc-toolset-11/enable"

source $TOOLCHAIN_ENV &&
    cd $SBDD_PATH &&
    make clean &&
    make &&
    ./tests/test_sbdd.sh
