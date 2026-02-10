#!/bin/bash

# Configuration - match the import script
BINARY="republicd"
HOME_DIR="/root/.republicd"
BACKEND="test"
PREFIX="dele_"

echo "Bắt đầu xoá các keys có tiền tố: $PREFIX"
echo "-----------------------------------"

# List all keys from keyring matching the prefix
keys=$($BINARY keys list --home "$HOME_DIR" --keyring-backend "$BACKEND" 2>/dev/null | grep "name: ${PREFIX}" | awk '{print $NF}')

count=0
deleted=0

# Process each key
while IFS= read -r key_name || [ -n "$key_name" ]; do
    if [ -z "$key_name" ]; then
        continue
    fi
    
    ((count++))
    echo "Đang xoá key: $key_name..."
    
    # Delete the key - pipe 'y' to confirm deletion
    echo "y" | $BINARY keys delete "$key_name" \
        --home "$HOME_DIR" \
        --keyring-backend "$BACKEND" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "✅ Thành công: $key_name"
        ((deleted++))
    else
        echo "❌ Thất bại: $key_name"
    fi
    
    echo "-----------------------------------"
done <<< "$keys"

echo "Hoàn tất xoá: Đã xoá $deleted/$count keys có tiền tố: $PREFIX"
