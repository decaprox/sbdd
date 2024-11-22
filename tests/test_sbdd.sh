#!/bin/bash

MODULE_NAME="sbdd"
MODULE_PATH="$MODULE_NAME.ko"

INVALID_TARGET="/invalid/path"
VALID_TARGET="/dev/vdb"
SYSFS_SLAVE_LINK="/sys/block/sbdd/slaves/vdb"
BLOCK_DEVICE="/dev/sbdd"

TEMP_DIR=$(mktemp -d)
WRITE_FILE="$TEMP_DIR/write_data"
READ_FILE_SBDD="$TEMP_DIR/read_data_sbdd"
READ_FILE_TARGET="$TEMP_DIR/read_data_target"

GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

cleanup() {
    sudo rmmod "$MODULE_NAME" &>/dev/null
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

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

test_load_with_invalid_param() {
    sudo insmod "$MODULE_PATH" target="$INVALID_TARGET" 2>/dev/null
    dmesg | tail -n 50 | grep -q "call blkdev_get_by_path() failed" &&
        ! is_module_loaded
    print_result "test_load_with_invalid_param" $?
    sudo rmmod "$MODULE_NAME" &>/dev/null
}

test_load_with_valid_param() {
    sudo insmod "$MODULE_PATH" target="$VALID_TARGET"
    dmesg | tail -n 50 | grep -q "initialization complete" &&
        [ -d $SYSFS_SLAVE_LINK ]
    print_result "test_load_with_valid_param" $?
    sudo rmmod "$MODULE_NAME" &>/dev/null
}

test_io_with_target() {
    sudo insmod "$MODULE_PATH" target="$VALID_TARGET" 2>/dev/null
    if ! ls "$BLOCK_DEVICE" &>/dev/null; then
        echo "Block device $BLOCK_DEVICE not created"
        cleanup
        exit 1
    fi

    # Generate random data
    sudo dd if=/dev/urandom of="$WRITE_FILE" bs=1M count=1 &>/dev/null
    # Write to /dev/sbdd
    sudo dd if="$WRITE_FILE" of="$BLOCK_DEVICE" bs=1M count=1 &>/dev/null
    # Read back from /dev/sbdd
    sudo dd if="$BLOCK_DEVICE" of="$READ_FILE_SBDD" bs=1M count=1 &>/dev/null
    # Read back from the target device
    sudo dd if="$VALID_TARGET" of="$READ_FILE_TARGET" bs=1M count=1 &>/dev/null
    # Compare the written data with the data read back
    cmp -s "$WRITE_FILE" "$READ_FILE_SBDD"
    RESULT_SBDD=$?

    cmp -s "$WRITE_FILE" "$READ_FILE_TARGET"
    RESULT_TARGET=$?

    cleanup

    if [ $RESULT_SBDD -eq 0 ] && [ $RESULT_TARGET -eq 0 ]; then
        print_result "test_io_with_target" 0
    else
        print_result "test_io_with_target" 1
    fi
}

test_load_module
test_unload_module
test_load_with_invalid_param
test_load_with_valid_param
test_io_with_target
