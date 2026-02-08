#!/bin/bash

# --- Cấu hình hệ thống ---
REPUBLIC_HOME="$HOME/.republicd"
BINARY_PATH="/usr/local/bin/republicd"
BINARY_URL="https://github.com/RepublicAI/networks/releases/download/v0.2.0/republicd-linux-amd64"
CHAIN_ID="raitestnet_77701-1"
VERSION="v0.1.0"
SNAP_RPC="https://statesync.republicai.io"
RPC_PUBLIC="https://rpc.republicai.io:443"
PEERS="e281dc6e4ebf5e32fb7e6c4a111c06f02a1d4d62@3.92.139.74:26656,cfb2cb90a241f7e1c076a43954f0ee6d42794d04@54.173.6.183:26656,dc254b98cebd6383ed8cf2e766557e3d240100a9@54.227.57.160:26656"
KEYRING_BACKEND="test"
DENOM="arai"
GAS_PRICE="250000000arai"
GAS_LIMIT="300000"
FEES="250000000000000000arai"

# --- Màu sắc ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Hàm tiện ích ---
msg() { echo -e "${GREEN}[*] $1${NC}"; }
err() { echo -e "${RED}[!] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }

get_balance() {
    local addr=$1
    local bal_arai=$(republicd query bank balances "$addr" --node "$RPC_PUBLIC" --output json 2>/dev/null | jq -r '.balances[] | select(.denom=="arai") | .amount')
    if [ -z "$bal_arai" ]; then bal_arai=0; fi
    echo "scale=4; $bal_arai/1000000000000000000" | bc
}

# --- Chức năng chính ---

install_node() {
    msg "Cài đặt phụ trợ..."
    sudo apt install jq bc git curl
    msg "Đang cài đặt Republic Binary..."
    curl -L "$BINARY_URL" -o /tmp/republicd
    chmod +x /tmp/republicd
    sudo mv /tmp/republicd "$BINARY_PATH"
    
    read -p "Nhập Moniker: " MONIKER
    republicd init "$MONIKER" --chain-id "$CHAIN_ID" --home "$REPUBLIC_HOME"
    curl -s https://raw.githubusercontent.com/RepublicAI/networks/main/testnet/genesis.json > "$REPUBLIC_HOME/config/genesis.json"
    
    msg "Cấu hình State Sync..."
    LATEST_HEIGHT=$(curl -s $SNAP_RPC/block | jq -r .result.block.header.height)
    BLOCK_HEIGHT=$((LATEST_HEIGHT - 1000))
    TRUST_HASH=$(curl -s "$SNAP_RPC/block?height=$BLOCK_HEIGHT" | jq -r .result.block_id.hash)

    sed -i.bak -E "s|^(enable[[:space:]]+=[[:space:]]+).*$|\1true| ; \
    s|^(rpc_servers[[:space:]]+=[[:space:]]+).*$|\1\"$SNAP_RPC,$SNAP_RPC\"| ; \
    s|^(trust_height[[:space:]]+=[[:space:]]+).*$|\1$BLOCK_HEIGHT| ; \
    s|^(trust_hash[[:space:]]+=[[:space:]]+).*$|\1\"$TRUST_HASH\"|" "$REPUBLIC_HOME/config/config.toml"
    sed -i.bak -e "s/^persistent_peers *=.*/persistent_peers = \"$PEERS\"/" "$REPUBLIC_HOME/config/config.toml"

    sudo tee /etc/systemd/system/republicd.service > /dev/null <<EOF
[Unit]
Description=Republic Protocol Node
After=network-online.target
[Service]
User=$USER
ExecStart=$BINARY_PATH start --home $REPUBLIC_HOME --chain-id $CHAIN_ID
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload && sudo systemctl enable republicd && sudo systemctl start republicd
    msg "Cài đặt hoàn tất! Node đang khởi chạy."
}

manage_wallet() {
    echo -e "1. Tạo ví mới\n2. Khôi phục ví (Mnemonic)\n3. Tạo ví phụ delegate hàng loạt"
    read -p "Chọn: " wopt
    case $wopt in
        1)
            read -p "Nhập tên ví: " kname
            republicd keys add "$kname" --keyring-backend "$KEYRING_BACKEND" --home "$REPUBLIC_HOME"
            ;;
        2)
            read -p "Nhập tên ví: " kname
            republicd keys add "$kname" --recover --keyring-backend "$KEYRING_BACKEND" --home "$REPUBLIC_HOME"
            ;;
        3)
            read -p "Số lượng ví phụ: " count
            LOG_FILE="wallets_$(date +%Y%m%d).txt"
            for ((i=1; i<=count; i++)); do
                sfx=$(printf "%02d" $i)
                kn="dele_$sfx"
                out=$(republicd keys add "$kn" --keyring-backend "$KEYRING_BACKEND" --home "$REPUBLIC_HOME" --output json 2>&1)
                echo "$out" | jq -r '"\(.name) | \(.address) | \(.mnemonic)"' >> "$LOG_FILE"
                echo -e "Đã tạo: $kn - $(echo "$out" | jq -r '.address')"
            done
            msg "Đã lưu thông tin vào $LOG_FILE"
            ;;
    esac
}

create_validator_json() {
    msg "Bắt đầu quy trình cấu hình Validator qua JSON..."
    
    # 1. Nhập liệu từ người dùng
    read -p "Nhập Moniker (Tên hiển thị): " moniker
    read -p "Nhập Identity (Keybase.io ID - để trống): " identity
    read -p "Nhập Website (để trống): " website
    
    # Nhập số lượng RAI (Mặc định là 0.5 RAI)
    read -p "Nhập số lượng RAI muốn stake (Mặc định 0.5): " amount_rai
    amount_rai=${amount_rai:-0.5}
    
    # Chuyển đổi sang arai (RAI * 10^18)
    # Dùng printf để tránh định dạng số khoa học (e+18)
    amount_arai=$(printf "%.0f" $(echo "$amount_rai * 1000000000000000000" | bc -l))

    read -p "Nhập Min Self Delegation (RAI) (Mặc định 1): " min_self_rai
    min_self_rai=${min_self_rai:-1}
    # Giữ nguyên định dạng string cho min-self-delegation vì chain thường nhận số thực ở đây
    
    read -p "Nhập tên ví (Key Name) thực hiện giao dịch: " kname

    # 2. Lấy Pubkey của Node
    # Đảm bảo lệnh này chạy được, nếu không sẽ báo lỗi ngay
    PUBKEY=$(republicd comet show-validator --home "$REPUBLIC_HOME")
    if [ -z "$PUBKEY" ]; then
        err "Không thể lấy Pubkey! Hãy chắc chắn node đã được init."
        return 1
    fi

    # 3. Tạo file JSON
    cat <<EOF > validator.json
{
  "pubkey": $PUBKEY,
  "amount": "${amount_arai}arai",
  "moniker": "$moniker",
  "identity": "$identity",
  "website": "$website",
  "security": "",
  "details": "Republic AI Testnet Validator",
  "commission-rate": "0.1",
  "commission-max-rate": "0.2",
  "commission-max-change-rate": "0.01",
  "min-self-delegation": "$min_self_rai"
}
EOF

    # 4. Kiểm tra và hiển thị cho người dùng
    echo -e "\n${YELLOW}--- Kiểm tra nội dung file validator.json ---${NC}"
    if command -v jq &> /dev/null; then
        cat validator.json | jq '.'
    else
        cat validator.json
    fi
    echo -e "${YELLOW}------------------------------------------${NC}"
    echo -e "${BLUE}Tổng số arai tính toán: $amount_arai${NC}\n"

    # 5. Xác nhận và gửi giao dịch
    read -p "Nội dung trên đã chính xác chưa? (y/n): " confirm
    if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
        msg "Đang gửi giao dịch create-validator..."
        republicd tx staking create-validator validator.json \
            --from="$kname" \
            --chain-id="$CHAIN_ID" \
            --home="$REPUBLIC_HOME" \
            --gas=400000 \
            --fees=400000000000000000arai \
            --node "$RPC_PUBLIC" \
            --keyring-backend "$KEYRING_BACKEND" \
            -y
    else
        warn "Đã hủy bỏ giao dịch."
    fi
}

delegate_menu() {
    echo -e "1. Self Delegate (Ví chính)\n2. Check balance ví phụ\n3. Auto Delegate (Ví phụ > 0.5 RAI)"
    read -p "Chọn: " dopt
    case $dopt in
        1)
            read -p "Tên ví chính: " kname
            addr=$(republicd keys show "$kname" -a --keyring-backend "$KEYRING_BACKEND" --home "$REPUBLIC_HOME")
            val_addr=$(republicd keys show "$kname" --bech val -a --keyring-backend "$KEYRING_BACKEND" --home "$REPUBLIC_HOME")
            bal=$(get_balance "$addr")
            echo -e "Balance hiện tại: ${BLUE}$bal RAI${NC}"
            read -p "Nhập số lượng RAI muốn delegate: " stake_rai
            stake_arai=$(echo "$stake_rai * 1000000000000000000 / 1" | bc)
            republicd tx staking delegate "$val_addr" "${stake_arai}arai" --from "$kname" --chain-id "$CHAIN_ID" --gas 300000 --fees 250000000000000000arai --node "$RPC_PUBLIC" --keyring-backend "$KEYRING_BACKEND" --home "$REPUBLIC_HOME" -y
            ;;
        2)
            printf "%-15s | %-45s | %-10s\n" "Key Name" "Address" "Balance (RAI)"
            keys=$(republicd keys list --home "$REPUBLIC_HOME" --keyring-backend "$KEYRING_BACKEND" --output json | jq -r '.[] | select(.name | startswith("dele_")) | .name + ":" + .address')
            for item in $keys; do
                name=${item%%:*}
                addr=${item#*:}
                echo -e "$name | $addr | $(get_balance "$addr") RAI"
            done
            ;;
        3)
            val_addr=$(republicd keys show wallet --bech val -a --keyring-backend "$KEYRING_BACKEND" --home "$REPUBLIC_HOME")
            keys=$(republicd keys list --home "$REPUBLIC_HOME" --keyring-backend "$KEYRING_BACKEND" --output json | jq -r '.[] | select(.name | startswith("dele_")) | .name + ":" + .address')
            for item in $keys; do
                name=${item%%:*}
                addr=${item#*:}
                bal=$(get_balance "$addr")
                if (( $(echo "$bal > 0.3" | bc -l) )); then
                    stake_rai=$(echo "$bal - 0.1" | bc -l)
                    stake_arai=$(echo "$stake_rai * 1000000000000000000 / 1" | bc)
                    msg "Ví $name: Stake $stake_rai RAI..."
                    republicd tx staking delegate "$val_addr" "${stake_arai}arai" --from "$name" --chain-id "$CHAIN_ID" --gas 300000 --fees 250000000000000000arai --node "$RPC_PUBLIC" --keyring-backend "$KEYRING_BACKEND" --home "$REPUBLIC_HOME" -y
                    sleep 3
                fi
            done
            ;;
    esac
}

optimize_node() {
    echo -e "${YELLOW}Optimizing Node for Low RAM and Disk usage...${NC}"
    SERVICE_NAME=republicd
    systemctl stop $SERVICE_NAME
    
    # 1. Update app.toml for Pruning
    sed -i 's/^pruning =.*/pruning = "custom"/' $REPUBLIC_HOME/config/app.toml
    sed -i 's/^pruning-keep-recent =.*/pruning-keep-recent = "1000"/' $REPUBLIC_HOME/config/app.toml
    sed -i 's/^pruning-keep-every =.*/pruning-keep-every = "0"/' $REPUBLIC_HOME/config/app.toml
    sed -i 's/^pruning-interval =.*/pruning-interval = "10"/' $REPUBLIC_HOME/config/app.toml
    
    # 2. Update config.toml for Indexer
    sed -i 's/^indexer =.*/indexer = "null"/' $REPUBLIC_HOME/config/config.toml
    
    # 3. Reduce Mempool size (Optional - for RAM)
    sed -i 's/^size =.*/size = 1000/' $REPUBLIC_HOME/config/config.toml

    # 4. Giảm iavl cache size xuống còn khoảng 200,000 (Tiết kiệm khoảng 1-1.5GB RAM)
    sed -i 's/^iavl-cache-size =.*/iavl-cache-size = 200000/' $HOME/.republicd/config/app.toml
    sed -i 's/^iavl-disable-fastnode =.*/iavl-disable-fastnode = true/' $HOME/.republicd/config/app.toml
    
    # 4. Restart Service
    systemctl start $SERVICE_NAME
    echo -e "${GREEN}Optimization applied! Node restarted.${NC}"
}

export_node_info() {
    msg "Đang trích xuất thông tin Node..."
    
    # Lấy Node ID
    NODE_ID=$(republicd comet show-node-id --home "$REPUBLIC_HOME")
    
    # Tự động lấy IP Public (dùng dịch vụ ifconfig.me)
    PUBLIC_IP=$(curl -s -4 ifconfig.me)
    
    # Lấy port P2P (mặc định là 26656 từ config.toml, nếu bạn đổi port hãy sửa ở đây)
    P2P_PORT=$(sed -n 's/^laddr = "tcp:\/\/0.0.0.0:\([0-9]*\)".*/\1/p' "$REPUBLIC_HOME/config/config.toml" | head -n 1)
    P2P_PORT=${P2P_PORT:-26656} # Default nếu không tìm thấy

    if [ -z "$NODE_ID" ]; then
        err "Không tìm thấy Node ID. Hãy chắc chắn node đã được cài đặt."
    else
        echo -e "\n${BLUE}--- THÔNG TIN PEER CỦA BẠN ---${NC}"
        echo -e "${GREEN}${NODE_ID}@${PUBLIC_IP}:${P2P_PORT}${NC}"
        echo -e "------------------------------"
        echo -e "Hãy copy dòng trên để nhập vào node mới.\n"
    fi
}

import_peers() {
    read -p "Dán chuỗi Peer (id@ip:port): " NEW_PEERS
    
    if [ -z "$NEW_PEERS" ]; then
        err "Chuỗi Peer không được để trống!"
        return 1
    fi

    msg "Đang dừng dịch vụ republicd..."
    sudo systemctl stop republicd

    msg "Đang cập nhật persistent_peers vào config.toml..."
    # Backup config trước khi sửa
    cp "$REPUBLIC_HOME/config/config.toml" "$REPUBLIC_HOME/config/config.toml.bak"
    
    # Dùng sed để tìm và thay thế dòng persistent_peers
    # Lưu ý: Lệnh này thay thế toàn bộ danh sách cũ bằng danh sách mới bạn nhập vào
    sed -i "s/^persistent_peers *=.*/persistent_peers = \"$NEW_PEERS\"/" "$REPUBLIC_HOME/config/config.toml"

    msg "Đang khởi động lại dịch vụ..."
    sudo systemctl start republicd
    
    msg "Hoàn tất! Kiểm tra log để xem node có kết nối được không."
    sudo journalctl -u republicd -f -o cat --since "1 min ago"
}

update_node() {
    msg "Bắt đầu quy trình cập nhật Republic Binary..."
    
    # 1. Yêu cầu nhập URL hoặc phiên bản
    read -p "Nhập URL tải Binary mới (hoặc để trống để dùng v0.2.0): " UPDATE_URL
    UPDATE_URL=${UPDATE_URL:-"$BINARY_URL"}
    
    # 2. Dừng dịch vụ
    msg "Đang dừng dịch vụ republicd..."
    sudo systemctl stop republicd
    
    # 3. Tải và thay thế binary
    msg "Đang tải binary từ: $UPDATE_URL"
    curl -L "$UPDATE_URL" -o /tmp/republicd_new
    
    if [ $? -ne 0 ]; then
        err "Tải file thất bại! Vui lòng kiểm tra lại URL."
        sudo systemctl start republicd
        return 1
    fi
    
    chmod +x /tmp/republicd_new
    
    # Backup binary cũ cho chắc chắn
    mv "$BINARY_PATH" "${BINARY_PATH}_bak_$(date +%Y%m%d)"
    sudo mv /tmp/republicd_new "$BINARY_PATH"
    
    # 4. Khởi động lại và kiểm tra
    msg "Đang khởi động lại dịch vụ..."
    sudo systemctl daemon-reload
    sudo systemctl start republicd
    
    NEW_VER=$($BINARY_PATH version)
    msg "Cập nhật hoàn tất! Phiên bản hiện tại: ${BLUE}$NEW_VER${NC}"
    
    # Gợi ý kiểm tra log
    warn "Hãy kiểm tra log (Option 7) để đảm bảo node không bị panic sau khi update."
}

cleanup() {
    warn "CẢNH BÁO: Hành động này sẽ dừng node và XÓA TOÀN BỘ DỮ LIỆU!"
    read -p "Xác nhận xóa? (type 'DELETE'): " confirm
    if [ "$confirm" == "DELETE" ]; then
        sudo systemctl stop republicd
        docker stop republicd 2>/dev/null && docker rm republicd 2>/dev/null
        rm -rf "$REPUBLIC_HOME"
        msg "Đã dọn dẹp sạch sẽ."
    else
        msg "Hủy bỏ dọn dẹp."
    fi
}

# --- Menu chính ---
while true; do
    echo -e "\n${BLUE}=== REPUBLIC AI ALL-IN-ONE TOOLKIT ===${NC}"
    echo "1. Cài đặt Node (Binary + StateSync)"
    echo "2. Tối ưu node (cấu hình pruning và tắt indexer)"
    echo "3. Quản lý Ví (Tạo/Khôi phục/Ví phụ)"
    echo "4. Tạo Validator"
    echo "5. Delegate (Self/Auto)"
    echo "6. Kiểm tra Sync Status"
    echo "7. Xem Logs (Systemd)"
    echo "8. Export Peer Info (Lấy info node này)"
    echo "9. Import Peers (Dán info node khác vào)"
    echo "10. Cập nhật Node (Update Binary)"
    echo "0. Thoát"
    read -p "Chọn option: " main_opt

    case $main_opt in
        1) install_node ;;
        2) optimize_node;;
        3) manage_wallet ;;
        4) create_validator_json;;
        5) delegate_menu ;;
        6) republicd status 2>&1 | jq '.SyncInfo // .sync_info' ;;
        7) sudo journalctl -u republicd -f -o cat ;;
        8) export_node_info ;;
        9) import_peers ;;
        10) update_node ;;
        0) exit 0 ;;
    esac
done