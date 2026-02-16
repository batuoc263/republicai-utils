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
    echo -e "1. Tạo ví mới (wallet)\n2. Khôi phục ví (wallet)\n3. Xem danh sách ví\n4. Kiểm tra số dư (Balance)\n5. Import ví từ file (Batch Clone)\n6. Gửi token (Send Token)"
    read -p "Chọn: " wopt
    case $wopt in
        1) d_exec "$id" keys add "wallet" --keyring-backend test ;;
        2) d_exec "$id" keys add "wallet" --recover --keyring-backend test ;;
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
        --from "wallet" \
        --chain-id "$CHAIN_ID" \
        --gas-prices="2500000000arai" \
        --gas-adjustment=1.5 \
        --gas=auto \
        --home $CONTAINER_HOME \
        --keyring-backend test \
        -y
}

list_all_addresses() {
    # Get all running republicd_node containers, sorted by node_id (version sort)
    containers=$(sudo docker ps --filter "name=republicd_node" --format "{{.Names}}" | sort -V)
    
    if [[ -z "$containers" ]]; then
        err "Không tìm thấy node nào đang chạy!"
        return 1
    fi
    
    msg "Đang lấy dữ liệu từ các container..."
    
    echo -e "\n${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}       TẤT CẢ ĐỊA CHỈ VÍ & VALIDATOR (SẮP XẾP THEO NODE_ID)${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}\n"
    
    for container in $containers; do
        # Extract node_id from container name (e.g., republicd_node1 -> 1)
        node_id=${container##republicd_node}
        
        echo -e "${YELLOW}NODE $node_id:${NC}"
        echo "─────────────────────────────────────────────────"
        
        # Get and display all wallet addresses
        wallet_count=0
        while IFS= read -r line; do
            if [[ $line == *"name:"* ]]; then
                wallet_name=$(echo "$line" | grep -oP '(?<=name:\s+)\S+')
                wallet_count=$((wallet_count + 1))
            fi
            if [[ $line == *"address:"* && -n "$wallet_name" ]]; then
                address=$(echo "$line" | grep -oP '(?<=address:\s+)(republic\S+)')
                if [[ -n "$address" ]]; then
                    printf "${CYAN}  • %-20s${NC} %s\n" "$wallet_name" "$address"
                fi
                wallet_name=""
            fi
        done < <(sudo docker exec "$container" republicd keys list --keyring-backend test 2>/dev/null)
        
        if [[ $wallet_count -eq 0 ]]; then
            echo -e "${RED}  (Không có ví)${NC}"
        fi
        
        # Get validator info if exists
        validator_address=$(sudo docker exec "$container" republicd keys show wallet --bech val -a --keyring-backend test --home $CONTAINER_HOME 2>/dev/null)
        
        if [[ -n "$validator_address" && "$validator_address" != "null" ]]; then
            printf "${GREEN}  • %-20s${NC} %s\n" "validator" "$validator_address"
        fi
        
        echo ""
    done
    
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}\n"
}

upgrade_binary_single() {
    read -p "Nhập ID node để upgrade binary: " id
    read -p "Nhập link binary (direct or github redirect): " url

    if [[ -z "$id" || -z "$url" ]]; then
        err "Vui lòng nhập ID node và URL!"
        return 1
    fi

    # 1. Tải về máy host
    msg "Tải binary về máy chủ tạm..."
    tmpfile="/tmp/republicd_new_$id"
    if ! curl -L -f -o "$tmpfile" "$url"; then
        err "Tải binary thất bại!"
        return 1
    fi
    chmod +x "$tmpfile"

    # 2. Kiểm tra container tồn tại
    if ! sudo docker ps -a --format '{{.Names}}' | grep -q "republicd_node$id"; then
        err "Container republicd_node$id không tồn tại!"
        rm -f "$tmpfile"
        return 1
    fi

    # 3. DỪNG CONTAINER - Bắt buộc để tránh Text file busy
    msg "Đang dừng container republicd_node$id..."
    sudo docker stop "republicd_node$id" >/dev/null 2>&1

    # 4. CẬP NHẬT FILE BẰNG DOCKER CP (Hoạt động cả khi container đang dừng)
    msg "Đang nạp binary mới vào container..."
    if sudo docker cp "$tmpfile" "republicd_node$id":/usr/local/bin/republicd; then
        msg "Đã copy thành công."
        
        # 5. KHỞI ĐỘNG LẠI CONTAINER
        msg "Đang khởi động lại node..."
        sudo docker start "republicd_node$id" >/dev/null 2>&1
        
        # 6. KIỂM TRA PHIÊN BẢN (Sau khi start mới exec được)
        sleep 2
        if sudo docker ps --filter "name=republicd_node$id" --format '{{.Status}}' | grep -q "Up"; then
            new_version=$(sudo docker exec "republicd_node$id" republicd version 2>/dev/null)
            msg "Cập nhật thành công! Phiên bản hiện tại: $new_version"
        else
            err "Container không thể khởi động sau khi cập nhật. Vui lòng check logs!"
        fi
    else
        err "Không thể copy binary vào container!"
        sudo docker start "republicd_node$id" # Cố gắng khởi chạy lại bản cũ
    fi

    rm -f "$tmpfile"
}

upgrade_binary_all() {
    read -p "Nhập link binary cho tất cả nodes: " url

    if [[ -z "$url" ]]; then
        err "Vui lòng nhập URL!"
        return 1
    fi

    containers=$(sudo docker ps --filter "name=republicd_node" --format "{{.Names}}" | sort -V)
    if [[ -z "$containers" ]]; then
        err "Không tìm thấy container republicd_node nào!"
        return 1
    fi

    msg "Tải binary về máy chủ tạm (một lần)..."
    tmpfile="/tmp/republicd_new_all"
    if ! curl -L -f -o "$tmpfile" "$url"; then
        err "Tải binary thất bại từ: $url"
        rm -f "$tmpfile" 2>/dev/null
        return 1
    fi
    chmod +x "$tmpfile" 2>/dev/null || true

    for container in $containers; do
        node_id=${container##republicd_node}
        msg "---- Upgrading $container (node $node_id) ----"

        # Stop container to avoid text file busy and to allow replacing binary
        msg "Đang dừng $container..."
        sudo docker stop "$container" >/dev/null 2>&1

        msg "Đang nạp binary mới vào $container..."
        if sudo docker cp "$tmpfile" "$container":/usr/local/bin/republicd; then
            msg "Đã copy thành công vào $container"
            msg "Đang khởi động lại $container..."
            sudo docker start "$container" >/dev/null 2>&1
            sleep 2
            if sudo docker ps --filter "name=$container" --format '{{.Status}}' | grep -q "Up"; then
                new_version=$(sudo docker exec "$container" republicd version 2>/dev/null)
                msg "Cập nhật thành công cho $container. Phiên bản: $new_version"
            else
                err "$container không thể khởi động sau khi cập nhật. Vui lòng kiểm tra logs"
            fi
        else
            err "Không thể copy binary vào $container"
            # Try to start container to restore previous state
            sudo docker start "$container" >/dev/null 2>&1 || true
        fi
    done

    rm -f "$tmpfile"
    msg "Hoàn tất upgrade binary cho tất cả nodes."
}

upgrade_binary_menu() {
    echo -e "1. Upgrade single node\n2. Upgrade all nodes"
    read -p "Chọn: " uopt
    case $uopt in
        1) upgrade_binary_single ;;
        2) upgrade_binary_all ;;
    esac
}

update_peers_single() {
    read -p "Nhập ID node để update peers: " id
    read -p "Nhập peers mới (format: node_id@host:port,node_id@host:port,...): " peers

    if [[ -z "$id" || -z "$peers" ]]; then
        err "Vui lòng nhập ID node và peers!"
        return 1
    fi

    # 1. Kiểm tra container tồn tại
    if ! sudo docker ps -a --format '{{.Names}}' | grep -q "republicd_node$id"; then
        err "Container republicd_node$id không tồn tại!"
        return 1
    fi

    msg "Đang dừng container republicd_node$id..."
    sudo docker stop "republicd_node$id" >/dev/null 2>&1

    msg "Đang backup config.toml..."
    sudo docker exec "republicd_node$id" bash -c 'cp '"$CONTAINER_HOME"'/config/config.toml '"$CONTAINER_HOME"'/config/config.toml.bak' 2>/dev/null || true

    msg "Đang cập nhật peers..."
    # Escape slashes in peers string for sed
    peers_escaped=$(printf '%s\n' "$peers" | sed -e 's/[\/&]/\\&/g')
    sudo docker exec "republicd_node$id" sed -i 's/^persistent_peers = .*/persistent_peers = "'"$peers_escaped"'"/' "$CONTAINER_HOME/config/config.toml"

    if [[ $? -eq 0 ]]; then
        msg "Đã cập nhật peers thành công."
        msg "Đang khởi động lại container republicd_node$id..."
        sudo docker start "republicd_node$id" >/dev/null 2>&1
        sleep 2
        if sudo docker ps --filter "name=republicd_node$id" --format '{{.Status}}' | grep -q "Up"; then
            msg "Container khởi động thành công! Peers đã được cập nhật."
            # Show current peers
            current_peers=$(sudo docker exec "republicd_node$id" grep "persistent_peers" "$CONTAINER_HOME/config/config.toml" | cut -d'"' -f2)
            msg "Peers hiện tại: $current_peers"
        else
            err "Container không thể khởi động. Vui lòng kiểm tra logs!"
        fi
    else
        err "Cập nhật peers thất bại, khởi động lại container..."
        sudo docker start "republicd_node$id" >/dev/null 2>&1
        return 1
    fi
}

update_peers_all() {
    read -p "Nhập peers mới cho tất cả nodes (format: node_id@host:port,node_id@host:port,...): " peers

    if [[ -z "$peers" ]]; then
        err "Vui lòng nhập peers!"
        return 1
    fi

    containers=$(sudo docker ps -a --filter "name=republicd_node" --format "{{.Names}}" | sort -V)
    if [[ -z "$containers" ]]; then
        err "Không tìm thấy container republicd_node nào!"
        return 1
    fi

    msg "Sẵn sàng: Tất cả container sẽ được cập nhật peers..."
    # Escape slashes in peers string for sed
    peers_escaped=$(printf '%s\n' "$peers" | sed -e 's/[\/&]/\\&/g')

    success_count=0
    fail_count=0

    for container in $containers; do
        node_id=${container##republicd_node}
        msg "---- Updating peers for $container (node $node_id) ----"

        # Stop container
        msg "Đang dừng $container..."
        sudo docker stop "$container" >/dev/null 2>&1

        # Backup config
        msg "Đang backup config.toml..."
        sudo docker exec "$container" bash -c 'cp '"$CONTAINER_HOME"'/config/config.toml '"$CONTAINER_HOME"'/config/config.toml.bak' 2>/dev/null || warn "Không thể backup cho $container"

        # Update peers
        msg "Đang cập nhật peers cho $container..."
        if sudo docker exec "$container" sed -i 's/^persistent_peers = .*/persistent_peers = "'"$peers_escaped"'"/' "$CONTAINER_HOME/config/config.toml" 2>/dev/null; then
            # Start container
            msg "Đang khởi động lại $container..."
            sudo docker start "$container" >/dev/null 2>&1
            sleep 2
            if sudo docker ps --filter "name=$container" --format '{{.Status}}' | grep -q "Up"; then
                msg "Container $container khởi động thành công! Peers đã được cập nhật."
                ((success_count++))
            else
                err "Container $container không thể khởi động. Vui lòng kiểm tra logs!"
                ((fail_count++))
            fi
        else
            err "Cập nhật peers thất bại cho $container, khởi động lại..."
            sudo docker start "$container" >/dev/null 2>&1 || true
            ((fail_count++))
        fi
    done

    msg "Hoàn tất cập nhật peers."
    msg "Thành công: $success_count, Thất bại: $fail_count"
}

update_peers_menu() {
    echo -e "1. Update peers single node\n2. Update peers all nodes"
    read -p "Chọn: " uopt
    case $uopt in
        1) update_peers_single ;;
        2) update_peers_all ;;
    esac
}

# --- Menu chính ---
while true; do
    echo -e "\n${GREEN}=== REPUBLIC AI docker ULTIMATE TOOL ===${NC}"
    echo "1. Triển khai Node mới (StateSync + Optimize)"
    echo "2. Quản lý Ví (Keys)"
    echo "3. Tạo Validator (JSON mode)"
    echo "4. Kiểm tra Sync Status"
    echo "5. Xem Logs"
    echo "6. Xuất tất cả địa chỉ"
    echo "7. Upgrade binary (Single node / All nodes)"
    echo "8. Update peers (Single node / All nodes)"
    echo "0. Thoát"
    read -p "Chọn option: " opt
    case $opt in
        1) deploy_node ;;
        2) wallet_mgr ;;
        3) validator_mgr ;;
        4) read -p "ID node: " id; d_exec "$id" status | jq .sync_info ;;
        5) read -p "ID node: " id; sudo docker logs -f -n 50 "republicd_node$id" ;;
        6) list_all_addresses ;;
        7) upgrade_binary_menu ;;
        8) update_peers_menu ;;
        0) exit 0 ;;
    esac
done