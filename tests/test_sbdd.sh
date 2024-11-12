#!/bin/bash

MODULE_NAME="sbdd"
MODULE_PATH="$MODULE_NAME.ko"

GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

print_result() {
    local test_name="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        echo -e "${test_name} ${GREEN}OK${NC}"
    else
        echo -e "${test_name} ${RED}FAIL${NC}"
    fi
}

is_module_loaded() {
    lsmod | grep "$MODULE_NAME" &> /dev/null
}

test_load_module() {
    sudo insmod "$MODULE_PATH"
    if is_module_loaded; then
        dmesg | tail -n 50 | grep -q "sbdd: initialization complete"
        print_result "test_load_module" $?
    else
        print_result "test_load_module" 1
    fi
}

test_unload_module() {
    sudo rmmod "$MODULE_NAME"
    if ! is_module_loaded; then
        dmesg | tail -n 50 | grep -q "sbdd: exiting complete"
        print_result "test_unload_module" $?
    else
        print_result "test_unload_module" 1
    fi
}

test_load_module
test_unload_module
