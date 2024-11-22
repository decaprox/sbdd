#!/bin/bash

MODULE_NAME="sbdd"
MODULE_PATH="$MODULE_NAME.ko"

INVALID_TARGET="/invalid/path"
VALID_TARGET="/dev/vdb"
SYSFS_SLAVE_LINK="/sys/block/sbdd/slaves/vdb"
SYSFS_TARGET="/sys/block/sbdd/target"
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

print_result() {
    local test_name="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        echo -e "${test_name} ${GREEN}OK${NC}"
    else
        echo -e "${test_name} ${RED}FAIL${NC}"
    fi
}

load_module() {
    sudo insmod "$MODULE_PATH" "$1" &>/dev/null
}

unload_module() {
    sudo rmmod "$MODULE_NAME" &>/dev/null
}

test_load_module() {
    load_module
    if is_module_loaded; then
        dmesg | tail -n 50 | grep -q "sbdd: initialization complete"
        print_result "test_load_module" $?
    else
        print_result "test_load_module" 1
    fi
}

test_unload_module() {
    unload_module
    if ! is_module_loaded; then
        dmesg | tail -n 50 | grep -q "sbdd: exiting complete"
        print_result "test_unload_module" $?
    else
        print_result "test_unload_module" 1
    fi
}

test_load_with_invalid_param() {
    load_module target="$INVALID_TARGET"
    dmesg | tail -n 50 | grep -q "call blkdev_get_by_path() failed" &&
        ! is_module_loaded
    print_result "test_load_with_invalid_param" $?
    unload_module
}

test_load_with_valid_param() {
    load_module target="$VALID_TARGET"
    dmesg | tail -n 50 | grep -q "initialization complete" &&
        [ -d $SYSFS_SLAVE_LINK ]
    print_result "test_load_with_valid_param" $?
    unload_module
}

test_io_with_target() {
    load_module target="$VALID_TARGET"
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

    if [ $RESULT_SBDD -eq 0 ] && [ $RESULT_TARGET -eq 0 ]; then
        print_result "test_io_with_target" 0
    else
        print_result "test_io_with_target" 1
    fi
}

test_sysfs_target_set_valid() {
    load_module
    echo "$VALID_TARGET" | sudo tee "$SYSFS_TARGET" > /dev/null
    SYSFS_VALUE=$(cat "$SYSFS_TARGET")
    if [ "$SYSFS_VALUE" == "$VALID_TARGET" ]; then
        print_result "test_sysfs_target_set_valid" 0
    else
        print_result "test_sysfs_target_set_valid" 1
    fi
    unload_module
}

test_sysfs_target_set_invalid() {
    load_module
    echo "$INVALID_TARGET" | sudo tee "$SYSFS_TARGET" 2>&1 >/dev/null
    SYSFS_VALUE=$(cat "$SYSFS_TARGET")
    if [[ "$SYSFS_VALUE" == "None" ]]; then
        print_result "test_sysfs_target_set_invalid" 0
    else
        print_result "test_sysfs_target_set_invalid" 1
    fi
    unload_module
}

test_io_with_sysfs_target() {
    load_module

    # Write the valid target to sysfs
    echo "$VALID_TARGET" | sudo tee "$SYSFS_TARGET" > /dev/null
    # Write random data
    dd if=/dev/urandom of="$WRITE_FILE" bs=1M count=1 &>/dev/null
    # Write to /dev/sbdd
    sudo dd if="$WRITE_FILE" of="$BLOCK_DEVICE" bs=1M count=1 &>/dev/null
    # Read back from /dev/sbdd
    sudo dd if="$BLOCK_DEVICE" of="$READ_FILE_SBDD" bs=1M count=1 &>/dev/null
    # Read back from the target device
    sudo dd if="$VALID_TARGET" of="$READ_FILE_TARGET" bs=1M count=1 &>/dev/null
    # Compare written and read data
    cmp -s "$WRITE_FILE" "$READ_FILE_SBDD"
    RESULT_SBDD=$?

    cmp -s "$WRITE_FILE" "$READ_FILE_TARGET"
    RESULT_TARGET=$?

    if [ $RESULT_SBDD -eq 0 ] && [ $RESULT_TARGET -eq 0 ]; then
        print_result "test_io_with_sysfs_target" 0
    else
        print_result "test_io_with_sysfs_target" 1
    fi

    unload_module
}

test_load_module
test_unload_module
test_load_with_invalid_param
test_load_with_valid_param
test_io_with_target
test_sysfs_target_set_invalid
test_sysfs_target_set_valid
test_io_with_sysfs_target

cleanup
