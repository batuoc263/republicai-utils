#!/bin/bash

# --- Cấu hình mặc định ---
IMAGE="ghcr.io/republicai/republicd:0.1.0"
CHAIN_ID="raitestnet_77701-1"
CONTAINER_HOME="/home/republic/.republicd"
GENESIS_URL="https://raw.githubusercontent.com/RepublicAI/networks/main/testnet/genesis.json"
SNAP_RPC="https://statesync.republicai.io"
RPC_PUBLIC="https://rpc.republicai.io:443"
DENOM="arai"

# --- Màu sắc ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

msg() { echo -e "${GREEN}[*] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err() { echo -e "${RED}[!] $1${NC}"; }

# --- Hàm hỗ trợ docker ---
# Chạy lệnh republicd bên trong container của một node cụ thể
d_exec() {
    local id=$1
    shift
    sudo docker exec -it "republicd_node$id" republicd "$@" --home $CONTAINER_HOME
}

# --- Chức năng chính ---

deploy_node() {
    read -p "Nhập ID node (vd: 1, 2...): " NODE_ID
    read -p "Nhập Moniker: " MONIKER
    
    OFFSET=$((NODE_ID * 10))
    P2P_PORT=$((26656 + OFFSET))
    RPC_PORT=$((26657 + OFFSET))
    REST_PORT=$((1317 + OFFSET))
    GRPC_PORT=$((9090 + OFFSET))
    
    DATA_DIR="$HOME/.republicd_node$NODE_ID"
    mkdir -p "$DATA_DIR"

    msg "Khởi tạo Node $NODE_ID..."
    sudo docker run --rm -v "$DATA_DIR:$CONTAINER_HOME" $IMAGE \
        init "$MONIKER" --chain-id "$CHAIN_ID" --home $CONTAINER_HOME

    curl -s "$GENESIS_URL" > "$DATA_DIR/config/genesis.json"

    # Port & Indexer & Pruning (tương tự setup-aio.sh)
    sed -i "s|tcp://0.0.0.0:26656|tcp://0.0.0.0:$P2P_PORT|g" "$DATA_DIR/config/config.toml"
    sed -i "s|tcp://127.0.0.1:26657|tcp://0.0.0.0:$RPC_PORT|g" "$DATA_DIR/config/config.toml"
    sed -i 's/^indexer =.*/indexer = "null"/' "$DATA_DIR/config/config.toml"
    sed -i 's/^pruning =.*/pruning = "custom"/' "$DATA_DIR/config/app.toml"
    sed -i 's/^pruning-keep-recent =.*/pruning-keep-recent = "100"/' "$DATA_DIR/config/app.toml"
    sed -i 's/^pruning-interval =.*/pruning-interval = "19"/' "$DATA_DIR/config/app.toml"

    sudo docker run -d --name "republicd_node$NODE_ID" --restart always \
        -v "$DATA_DIR:$CONTAINER_HOME" -p "$P2P_PORT:$P2P_PORT" -p "$RPC_PORT:$RPC_PORT" \
        $IMAGE start --home $CONTAINER_HOME
    msg "Node $NODE_ID đang chạy!"
}

wallet_mgr() {
    read -p "Nhập ID node để quản lý ví: " id
    echo -e "1. Tạo ví mới\n2. Khôi phục ví\n3. Xem danh sách ví\n4. Kiểm tra số dư (Balance)\n5. Import ví từ file (Batch Clone)\n6. Gửi token (Send Token)"
    read -p "Chọn: " wopt
    case $wopt in
        1) read -p "Tên ví: " kname; d_exec "$id" keys add "$kname" --keyring-backend test ;;
        2) read -p "Tên ví: " kname; d_exec "$id" keys add "$kname" --recover --keyring-backend test ;;
        3) d_exec "$id" keys list --keyring-backend test ;;
        4) 
            read -p "Tên ví hoặc địa chỉ: " wallet_addr
            d_exec "$id" query bank balances "$wallet_addr"
            ;;
        5) batch_import_wallets "$id" ;;
        6) send_token "$id" ;;
    esac
}

batch_import_wallets() {
    local id=$1
    
    # Kiểm tra file wallets.txt
    if [[ ! -f "wallets.txt" ]]; then
        err "File wallets.txt không tìm thấy!"
        return 1
    fi
    
    # Đếm số lượng ví trong file
    total_wallets=$(wc -l < wallets.txt)
    msg "Tổng số ví trong file: $total_wallets"
    
    # Hỏi nhân dân
    read -p "Nhập thứ tự ví bắt đầu (1-$total_wallets): " start_idx
    read -p "Nhập số lượng ví muốn import: " count
    
    # Validate input
    if [[ ! "$start_idx" =~ ^[0-9]+$ ]] || [[ ! "$count" =~ ^[0-9]+$ ]]; then
        err "Vui lòng nhập số nguyên!"
        return 1
    fi
    
    if [[ $start_idx -lt 1 || $start_idx -gt $total_wallets ]]; then
        err "Thứ tự ví không hợp lệ!"
        return 1
    fi
    
    if [[ $((start_idx + count - 1)) -gt $total_wallets ]]; then
        err "Không đủ ví trong file! Chỉ có $total_wallets ví."
        return 1
    fi
    
    msg "Bắt đầu import $count ví từ thứ tự $start_idx..."
    
    # Import ví
    local end_idx=$((start_idx + count - 1))
    local wallet_counter=1
    
    for ((line_num=$start_idx; line_num<=end_idx; line_num++)); do
        mnemonic=$(sed -n "${line_num}p" wallets.txt)
        wallet_name="dele_${wallet_counter}"
        
        echo -ne "${YELLOW}[${wallet_counter}/${count}] Importing $wallet_name từ dòng $line_num...${NC}\r"
        
        # Khôi phục ví (keyring-backend test không cần password)
        echo "$mnemonic" | sudo docker exec -i "republicd_node$id" republicd keys add "$wallet_name" --recover --keyring-backend test >/dev/null 2>&1
        
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✓ Ví $wallet_counter ($wallet_name) import thành công!${NC}"
        else
            echo -e "${RED}✗ Ví $wallet_counter ($wallet_name) import thất bại!${NC}"
        fi
        
        ((wallet_counter++))
    done
    
    msg "Hoàn tất import $count ví!"
    echo -e "${YELLOW}Danh sách ví mới:${NC}"
    d_exec "$id" keys list --keyring-backend test
}

send_token() {
    local id=$1
    
    # Hỏi thông tin
    read -p "Tên ví nguồn (hoặc địa chỉ): " from_addr
    read -p "Tên ví đích (hoặc địa chỉ): " to_addr
    read -p "Số lượng RAI muốn gửi: " amount_rai
    
    # Validate input
    if [[ -z "$from_addr" || -z "$to_addr" || -z "$amount_rai" ]]; then
        err "Vui lòng nhập đầy đủ thông tin!"
        return 1
    fi
    
    # Kiểm tra amount có phải số
    if ! [[ "$amount_rai" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        err "Số lượng phải là số hợp lệ!"
        return 1
    fi
    
    # Tính toán arai (RAI * 10^18)
    amount_arai=$(printf "%.0f" $(echo "$amount_rai * 1000000000000000000" | bc -l))
    
    msg "Chuẩn bị gửi $amount_rai RAI (${amount_arai}arai)"
    echo -e "${YELLOW}Từ: $from_addr${NC}"
    echo -e "${YELLOW}Đến: $to_addr${NC}"
    read -p "Xác nhận gửi? (y/n): " confirm
    
    if [[ "$confirm" != "y" ]]; then
        warn "Đã hủy giao dịch."
        return 0
    fi
    
    msg "Đang gửi giao dịch..."
    d_exec "$id" tx bank send "$from_addr" "$to_addr" "${amount_arai}arai" \
        --from "$from_addr" \
        --chain-id "$CHAIN_ID" \
        --gas-prices="2500000000arai" \
        --gas-adjustment=1.5 \
        --gas=auto \
        -y
    
    echo -e "${GREEN}Giao dịch đã được gửi!${NC}"
}

validator_mgr() {
    read -p "Nhập ID node để tạo Validator: " id
    read -p "Tên ví (đã tạo ở bước trên): " kname
    read -p "Số lượng RAI stake (vd: 0.5): " amount_rai
    
    # Lấy Pubkey từ bên trong container
    PUBKEY=$(sudo docker exec "republicd_node$id" republicd comet show-validator --home $CONTAINER_HOME)
    MONIKER=$(sudo docker exec "republicd_node$id" cat $CONTAINER_HOME/config/config.toml | grep -oP '(?<=moniker = ")[^"]*')
    
    # Tính toán arai (Sử dụng bc để chính xác)
    amount_arai=$(printf "%.0f" $(echo "$amount_rai * 1000000000000000000" | bc -l))

    # Tạo file json tạm bên trong container
    sudo docker exec "republicd_node$id" bash -c "cat <<EOF > $CONTAINER_HOME/validator.json
{
  \"pubkey\": $PUBKEY,
  \"amount\": \"${amount_arai}arai\",
  \"moniker\": \"$MONIKER\",
  \"identity\": \"\",
  \"website\": \"\",
  \"security\": \"\",
  \"details\": \"Republic AI Node\",
  \"commission-rate\": \"0.1\",
  \"commission-max-rate\": \"0.2\",
  \"commission-max-change-rate\": \"0.01\",
  \"min-self-delegation\": \"1\"
}
EOF"

    msg "Đang gửi giao dịch tạo Validator cho Node $id..."
    d_exec "$id" tx staking create-validator $CONTAINER_HOME/validator.json \
        --from "$kname" \
        --chain-id "$CHAIN_ID" \
        --gas-prices="2500000000arai" \
        --gas-adjustment=1.5 \
        --gas=auto \
        --home $CONTAINER_HOME \
        --keyring-backend test \
        -y
}

# --- Menu chính ---
while true; do
    echo -e "\n${GREEN}=== REPUBLIC AI docker ULTIMATE TOOL ===${NC}"
    echo "1. Triển khai Node mới (StateSync + Optimize)"
    echo "2. Quản lý Ví (Keys)"
    echo "3. Tạo Validator (JSON mode)"
    echo "4. Kiểm tra Sync Status"
    echo "5. Xem Logs"
    echo "0. Thoát"
    read -p "Chọn option: " opt
    case $opt in
        1) deploy_node ;;
        2) wallet_mgr ;;
        3) validator_mgr ;;
        4) read -p "ID node: " id; d_exec "$id" status | jq .sync_info ;;
        5) read -p "ID node: " id; sudo docker logs -f "republicd_node$id" ;;
        0) exit 0 ;;
    esac
done