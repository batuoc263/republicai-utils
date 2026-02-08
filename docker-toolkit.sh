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

# --- Hàm hỗ trợ Docker ---
# Chạy lệnh republicd bên trong container của một node cụ thể
d_exec() {
    local id=$1
    shift
    docker exec -it "republicd_node$id" republicd "$@" --home $CONTAINER_HOME
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
    docker run --rm -v "$DATA_DIR:$CONTAINER_HOME" $IMAGE \
        init "$MONIKER" --chain-id "$CHAIN_ID" --home $CONTAINER_HOME

    curl -s "$GENESIS_URL" > "$DATA_DIR/config/genesis.json"

    # Port & Indexer & Pruning (tương tự setup-aio.sh)
    sed -i "s|tcp://0.0.0.0:26656|tcp://0.0.0.0:$P2P_PORT|g" "$DATA_DIR/config/config.toml"
    sed -i "s|tcp://127.0.0.1:26657|tcp://0.0.0.0:$RPC_PORT|g" "$DATA_DIR/config/config.toml"
    sed -i 's/^indexer =.*/indexer = "null"/' "$DATA_DIR/config/config.toml"
    sed -i 's/^pruning =.*/pruning = "custom"/' "$DATA_DIR/config/app.toml"
    sed -i 's/^pruning-keep-recent =.*/pruning-keep-recent = "100"/' "$DATA_DIR/config/app.toml"
    sed -i 's/^pruning-interval =.*/pruning-interval = "19"/' "$DATA_DIR/config/app.toml"

    docker run -d --name "republicd_node$NODE_ID" --restart always \
        -v "$DATA_DIR:$CONTAINER_HOME" -p "$P2P_PORT:$P2P_PORT" -p "$RPC_PORT:$RPC_PORT" \
        $IMAGE start --home $CONTAINER_HOME
    msg "Node $NODE_ID đang chạy!"
}

wallet_mgr() {
    read -p "Nhập ID node để quản lý ví: " id
    echo -e "1. Tạo ví mới\n2. Khôi phục ví\n3. Xem danh sách ví"
    read -p "Chọn: " wopt
    case $wopt in
        1) read -p "Tên ví: " kname; d_exec "$id" keys add "$kname" --keyring-backend test ;;
        2) read -p "Tên ví: " kname; d_exec "$id" keys add "$kname" --recover --keyring-backend test ;;
        3) d_exec "$id" keys list --keyring-backend test ;;
    esac
}

validator_mgr() {
    read -p "Nhập ID node để tạo Validator: " id
    read -p "Tên ví (đã tạo ở bước trên): " kname
    read -p "Số lượng RAI stake (vd: 0.5): " amount_rai
    
    # Lấy Pubkey từ bên trong container
    PUBKEY=$(docker exec "republicd_node$id" republicd comet show-validator --home $CONTAINER_HOME)
    MONIKER=$(docker exec "republicd_node$id" cat $CONTAINER_HOME/config/config.toml | grep -oP '(?<=moniker = ")[^"]*')
    
    # Tính toán arai (Sử dụng bc để chính xác)
    amount_arai=$(printf "%.0f" $(echo "$amount_rai * 1000000000000000000" | bc -l))

    # Tạo file json tạm bên trong container
    docker exec "republicd_node$id" bash -c "cat <<EOF > $CONTAINER_HOME/validator.json
{
  \"pubkey\": $PUBKEY,
  \"amount\": \"${amount_arai}arai\",
  \"moniker\": \"$MONIKER\",
  \"identity\": \"\",
  \"website\": \"\",
  \"security\": \"\",
  \"details\": \"Republic AI Docker Node\",
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
        -y
}

# --- Menu chính ---
while true; do
    echo -e "\n${GREEN}=== REPUBLIC AI DOCKER ULTIMATE TOOL ===${NC}"
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
        4) read -p "ID node: " id; d_exec "$id" status | jq .SyncInfo ;;
        5) read -p "ID node: " id; docker logs -f "republicd_node$id" ;;
        0) exit 0 ;;
    esac
done