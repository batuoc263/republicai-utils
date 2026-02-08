#!/bin/bash

# --- CẤU HÌNH ---
IMAGE="ghcr.io/republicai/republicd:0.1.0"
CHAIN_ID="raitestnet_77701-1"
CONTAINER_HOME="/home/republic/.republicd"
SNAPSHOT_URL="https://snapshot-t.vinjan-inc.com/republic/latest.tar.lz4"

# Màu sắc
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}   REPUBLIC AI V14: AUTO SYNC WAIT & INTERACTIVE WALLET       ${NC}"
echo -e "${GREEN}==============================================================${NC}"

# Wrapper Docker
run_docker() {
    if groups | grep -q "docker"; then docker "$@"; else sudo docker "$@"; fi
}

# 0. CHECK DEPENDENCIES
if ! command -v lz4 &> /dev/null; then
    sudo apt update && sudo apt install -y lz4 jq curl
fi

# 1. NHẬP THÔNG TIN
read -p "Bắt đầu từ Node số mấy? (Ví dụ: 1): " START_NUM
read -p "Số lượng Node muốn cài? (Ví dụ: 10): " COUNT

if [[ -z "$START_NUM" || -z "$COUNT" ]]; then
    echo "Thiếu thông tin!"; exit 1
fi
END_NUM=$((START_NUM + COUNT - 1))

PUBLIC_PEERS="e281dc6e4ebf5e32fb7e6c4a111c06f02a1d4d62@3.92.139.74:26656,cfb2cb90a241f7e1c076a43954f0ee6d42794d04@54.173.6.183:26656"

# ====================================================
# PHẦN 1: CÀI ĐẶT NODE (INSTALLATION)
# ====================================================
echo -e "\n${BLUE}>>> PHẦN 1: CÀI ĐẶT & NẠP SNAPSHOT${NC}"

for (( i=$START_NUM; i<=$END_NUM; i++ ))
do
    NODE_NAME="republicd_node${i}"
    HOST_DIR="$HOME/.republicd_node${i}"
    
    OFFSET=$((i * 10))
    PORT_RPC=$((26657 + OFFSET))
    PORT_P2P=$((26656 + OFFSET))
    PORT_API=$((1317 + OFFSET))

    if [[ "$i" -eq 1 ]]; then
        MEM="10g"; CPU="3.0"; ROLE="HUB"
    else
        MEM="7g"; CPU="1.5"; ROLE="WORKER"
    fi

    echo -e "\n${CYAN}>>> SETUP NODE ${i} ($ROLE)${NC}"

    # Nhập tên Moniker
    while true; do
        read -p "Nhập tên hiển thị (Moniker) cho Node ${i}: " MONIKER
        if [[ -n "$MONIKER" ]]; then break; fi
    done

    # Xóa cũ & Tạo mới
    if [ -d "$HOST_DIR" ]; then sudo rm -rf "$HOST_DIR"; fi
    run_docker stop $NODE_NAME 2>/dev/null
    run_docker rm $NODE_NAME 2>/dev/null
    mkdir -p "$HOST_DIR"

    # Init Config
    run_docker run --rm --user 0:0 -v "$HOST_DIR:$CONTAINER_HOME" $IMAGE init "$MONIKER" --chain-id $CHAIN_ID --home $CONTAINER_HOME > /dev/null
    sudo curl -s https://raw.githubusercontent.com/RepublicAI/networks/main/testnet/genesis.json -o "$HOST_DIR/config/genesis.json"

    # Nạp Snapshot (Fix Permission với sudo tar)
    echo -e "${YELLOW}Downloading Snapshot...${NC}"
    sudo rm -rf "$HOST_DIR/data"
    curl -L $SNAPSHOT_URL | lz4 -dc - | sudo tar -xf - -C "$HOST_DIR"

    # Internal Peer Logic
    PEERS_CONFIG="$PUBLIC_PEERS"; PEX_CONFIG="false"
    if [[ "$i" -eq 1 ]]; then
        PEX_CONFIG="true"
    else
        NODE1_ID=$(run_docker exec republicd_node1 republicd comet show-node-id --home $CONTAINER_HOME 2>/dev/null)
        NODE1_IP=$(run_docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' republicd_node1)
        if [[ -n "$NODE1_ID" && -n "$NODE1_IP" ]]; then
            PEERS_CONFIG="${NODE1_ID}@${NODE1_IP}:26656"
        fi
    fi

    # Config Update
    CONF="$HOST_DIR/config/config.toml"
    APP="$HOST_DIR/config/app.toml"
    sudo sed -i "s|^persistent_peers *=.*|persistent_peers = \"$PEERS_CONFIG\"|" $CONF
    sudo sed -i "s|^pex *=.*|pex = $PEX_CONFIG|" $CONF
    sudo sed -i "s|^moniker *=.*|moniker = \"$MONIKER\"|" $CONF
    
    sudo sed -i 's|^pruning *=.*|pruning = "custom"|' $APP
    sudo sed -i 's|^pruning-keep-recent *=.*|pruning-keep-recent = "100"|' $APP
    sudo sed -i 's|^pruning-interval *=.*|pruning-interval = "19"|' $APP

    # Fix quyền lại cho User Docker
    sudo chown -R 1001:1001 "$HOST_DIR"

    # Start Node
    run_docker run -d --name $NODE_NAME --restart unless-stopped \
      --memory="$MEM" --memory-swap="10g" --cpus="$CPU" \
      -v "$HOST_DIR:$CONTAINER_HOME" \
      -p $PORT_RPC:26657 -p $PORT_P2P:26656 -p $PORT_API:1317 \
      $IMAGE start --home $CONTAINER_HOME --chain-id $CHAIN_ID > /dev/null

    echo -e "${GREEN}DONE Node ${i}!${NC}"
done

# ====================================================
# PHẦN 2: CHỜ SYNC & TẠO VALIDATOR (AUTO WAIT)
# ====================================================
echo -e "\n${BLUE}>>> PHẦN 2: CHỜ ĐỒNG BỘ & TẠO VALIDATOR${NC}"
read -p "Bạn có muốn tiếp tục bước tạo Ví & Validator không? (y/n): " DO_VAL
if [[ "$DO_VAL" != "y" ]]; then echo "Đã dừng script."; exit 0; fi

for (( i=$START_NUM; i<=$END_NUM; i++ ))
do
    NODE_NAME="republicd_node${i}"
    WALLET_NAME="wallet_node${i}"
    HOST_DIR="$HOME/.republicd_node${i}"
    
    echo -e "\n${CYAN}====================================================${NC}"
    echo -e "${CYAN}   ĐANG XỬ LÝ NODE ${i}   ${NC}"
    echo -e "${CYAN}====================================================${NC}"

    # --- BƯỚC 1: CHỜ SYNC (WAIT LOOP) ---
    echo -e "${YELLOW}Đang kiểm tra trạng thái đồng bộ (Sync Status)...${NC}"
    while true; do
        # Lấy status, lọc bỏ log rác
        STATUS=$(run_docker exec $NODE_NAME republicd status 2>/dev/null)
        
        # Parse JSON
        CATCHING_UP=$(echo "$STATUS" | jq -r '.sync_info.catching_up' 2>/dev/null)
        BLOCK=$(echo "$STATUS" | jq -r '.sync_info.latest_block_height' 2>/dev/null)
        
        if [[ "$CATCHING_UP" == "false" ]]; then
            echo -e "${GREEN}>>> Đã Sync Xong! Block: $BLOCK${NC}"
            break
        elif [[ "$CATCHING_UP" == "true" ]]; then
            echo -ne "Đang tải dữ liệu... Block: $BLOCK \r"
            sleep 10 # Đợi 10 giây rồi check lại
        else
            echo -ne "Đang khởi động RPC... Vui lòng đợi.\r"
            sleep 5
        fi
    done

    # --- BƯỚC 2: TẠO VÍ (INTERACTIVE) ---
    if ! run_docker exec $NODE_NAME republicd keys show $WALLET_NAME --home $CONTAINER_HOME &>/dev/null; then
        echo -e "\n${BLUE}Tạo ví mới (Hãy nhập mật khẩu và lưu 24 từ khóa):${NC}"
        # Chạy tương tác
        run_docker exec -it $NODE_NAME republicd keys add $WALLET_NAME --home $CONTAINER_HOME
        echo -e "${RED}!!! ĐÃ LƯU MNEMONIC CHƯA? !!!${NC}"
        read -p "Nhấn [Enter] để tiếp tục..."
    fi
    
    # --- BƯỚC 3: HIỂN THỊ ĐỊA CHỈ (INTERACTIVE) ---
    echo -e "\n${YELLOW}>> Nhập mật khẩu ví để lấy địa chỉ Faucet:${NC}"
    # In thẳng ra màn hình để tránh lỗi script ẩn dòng nhập pass
    run_docker exec -it $NODE_NAME republicd keys show $WALLET_NAME -a --home $CONTAINER_HOME
    
    echo -e "\n${GREEN}>>> HÃY FAUCET 1.1 RAI VÀO ĐỊA CHỈ TRÊN.${NC}"
    read -p "Sau khi Faucet xong, nhấn [Enter] để tạo Validator..."

    # --- BƯỚC 4: TẠO VALIDATOR (INTERACTIVE) ---
    echo -e "Đang khởi tạo Validator..."
    
    # Lấy lại tên Moniker từ file config
    MONIKER=$(grep 'moniker =' "$HOST_DIR/config/config.toml" | cut -d'"' -f2)
    PUBKEY=$(run_docker exec $NODE_NAME republicd comet show-validator --home $CONTAINER_HOME)
    
    # Tạo file json cấu hình validator
    cat <<EOF | sudo tee "$HOST_DIR/validator.json" > /dev/null
{
  "pubkey": $PUBKEY,
  "amount": "100000000000000000arai",
  "moniker": "$MONIKER",
  "identity": "",
  "website": "",
  "security": "",
  "details": "Node $i",
  "commission-rate": "0.1",
  "commission-max-rate": "0.2",
  "commission-max-change-rate": "0.01",
  "min-self-delegation": "1"
}
EOF
    sudo chown 1001:1001 "$HOST_DIR/validator.json"

    echo -e "${YELLOW}>> Nhập lại mật khẩu ví để KÝ GIAO DỊCH Validator:${NC}"
    run_docker exec -it $NODE_NAME republicd tx staking create-validator \
      $CONTAINER_HOME/validator.json \
      --from $WALLET_NAME \
      --chain-id $CHAIN_ID \
      --gas-prices="2500000000arai" \
      --gas-adjustment=1.5 \
      --gas=auto \
      --home $CONTAINER_HOME \
      -y
    
    echo -e "${GREEN}>>> HOÀN TẤT NODE ${i}!${NC}"
done

echo -e "\n${GREEN}=== CHÚC MỪNG! HỆ THỐNG ĐÃ HOÀN THIỆN ===${NC}"

