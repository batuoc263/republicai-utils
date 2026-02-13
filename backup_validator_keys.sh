#!/bin/bash

# --- CẤU HÌNH ---
CONTAINER_HOME="/home/republic/.republicd"
BACKUP_DIR="$HOME/republic_validator_backup_$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="republic_validator_keys_$(date +%Y%m%d_%H%M%S).tar.gz"

# Màu sắc
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}   REPUBLIC AI: BACKUP VALIDATOR KEYS                         ${NC}"
echo -e "${GREEN}==============================================================${NC}"

# Wrapper Docker
run_docker() {
    if groups | grep -q "docker"; then docker "$@"; else sudo docker "$@"; fi
}

# 1. NHẬP THÔNG TIN VỀ NODE
read -p "Bắt đầu từ Node số mấy? (Ví dụ: 1): " START_NUM
read -p "Số lượng Node? (Ví dụ: 10): " COUNT

if [[ -z "$START_NUM" || -z "$COUNT" ]]; then
    echo -e "${RED}Thiếu thông tin!${NC}"; exit 1
fi

END_NUM=$((START_NUM + COUNT - 1))

# 2. TẠO BACKUP DIRECTORY
mkdir -p "$BACKUP_DIR"
echo -e "${BLUE}>>> Backup Directory: $BACKUP_DIR${NC}\n"

# 3. COPY CÁC FILE VALIDATOR KEYS
echo -e "${CYAN}>>> ĐANG BACKUP CÁC FILE VALIDATOR KEYS...${NC}"

for (( i=$START_NUM; i<=$END_NUM; i++ ))
do
    NODE_NAME="republicd_node${i}"
    NODE_BACKUP_DIR="$BACKUP_DIR/node${i}"
    
    echo -ne "${YELLOW}► Processing Node $i...${NC} "
    
    # Kiểm tra container tồn tại
    if ! run_docker ps -a --format '{{.Names}}' | grep -q "^${NODE_NAME}$"; then
        echo -e "${RED}❌ Container $NODE_NAME không tồn tại!${NC}"
        continue
    fi
    
    # Tạo thư mục node
    mkdir -p "$NODE_BACKUP_DIR"
    
    # Copy priv_validator_key.json
    if run_docker exec $NODE_NAME test -f "$CONTAINER_HOME/config/priv_validator_key.json"; then
        run_docker cp "$NODE_NAME:$CONTAINER_HOME/config/priv_validator_key.json" "$NODE_BACKUP_DIR/"
        
        # Copy thêm các file liên quan khác
        if run_docker exec $NODE_NAME test -f "$CONTAINER_HOME/config/node_key.json"; then
            run_docker cp "$NODE_NAME:$CONTAINER_HOME/config/node_key.json" "$NODE_BACKUP_DIR/"
        fi
        
        # Copy validator.json nếu tồn tại
        if run_docker exec $NODE_NAME test -f "$CONTAINER_HOME/validator.json"; then
            run_docker cp "$NODE_NAME:$CONTAINER_HOME/validator.json" "$NODE_BACKUP_DIR/"
        fi
        
        # Copy config.toml cho reference
        if run_docker exec $NODE_NAME test -f "$CONTAINER_HOME/config/config.toml"; then
            run_docker cp "$NODE_NAME:$CONTAINER_HOME/config/config.toml" "$NODE_BACKUP_DIR/"
        fi
        
        # Lấy node ID
        NODE_ID=$(run_docker exec $NODE_NAME republicd comet show-node-id --home $CONTAINER_HOME 2>/dev/null)
        if [[ -n "$NODE_ID" ]]; then
            echo "$NODE_ID" > "$NODE_BACKUP_DIR/node_id.txt"
        fi
        
        # Lấy validator address
        VALIDATOR_ADDR=$(run_docker exec $NODE_NAME republicd comet show-validator --home $CONTAINER_HOME 2>/dev/null)
        if [[ -n "$VALIDATOR_ADDR" ]]; then
            echo "$VALIDATOR_ADDR" > "$NODE_BACKUP_DIR/validator_pubkey.json"
        fi
        
        echo -e "${GREEN}✓ Complete${NC}"
    else
        echo -e "${RED}❌ priv_validator_key.json không tìm thấy!${NC}"
    fi
done

# 4. TẠO FILE INFO
echo -e "\n${CYAN}>>> TẠO FILE THÔNG TIN...${NC}"
cat > "$BACKUP_DIR/BACKUP_INFO.txt" << EOF
========================================
REPUBLIC AI VALIDATOR KEYS BACKUP
========================================

Backup Date: $(date)
Nodes Backed Up: $(for (( i=$START_NUM; i<=$END_NUM; i++ )); do echo -n "node$i "; done)

BACKUP STRUCTURE:
/node1/
  - priv_validator_key.json (Validator Private Key - ⚠️ BẢO MẬT)
  - node_key.json (Node Private Key)
  - validator.json (Validator Configuration)
  - config.toml (Node Configuration - Reference)
  - node_id.txt (Node ID)
  - validator_pubkey.json (Validator Public Key)
/node2/
  ... (same structure)
...

⚠️  QUAN TRỌNG:
- Giữ file này ở nơi an toàn (mã hóa / encrypted storage)
- priv_validator_key.json là SECRET - không chia sẻ với ai
- Nếu node bị leak hoặc bị hack, cần thay đổi mật khẩu
- Giữ backup này offsite cho an toàn

========================================
EOF

# 5. HIỂN THỊ DANH SÁCH FILE
echo -e "\n${CYAN}>>> DANH SÁCH CÁC FILE ĐÃ BACKUP:${NC}"
find "$BACKUP_DIR" -type f | while read file; do
    size=$(du -h "$file" | cut -f1)
    rel_path="${file#$BACKUP_DIR/}"
    echo -e "  ${GREEN}✓${NC} $rel_path ($size)"
done

# 6. NÉN BACKUP
echo -e "\n${CYAN}>>> ĐANG NÉN DỮ LIỆU...${NC}"
cd "$HOME"
tar -czf "$BACKUP_FILE" "republic_validator_backup_$(date +%Y%m%d_%H%M%S)/" 2>/dev/null

# Nếu lệnh trên thất bại, thử cách khác
if [ ! -f "$HOME/$BACKUP_FILE" ]; then
    tar -czf "$BACKUP_FILE" -C "$BACKUP_DIR" . 2>/dev/null
    if [ -f "$BACKUP_FILE" ]; then
        mv "$BACKUP_FILE" "$HOME/$BACKUP_FILE"
    fi
fi

# 7. HIỂN THỊ KẾT QUẢ
if [ -f "$HOME/$BACKUP_FILE" ]; then
    FILE_SIZE=$(du -h "$HOME/$BACKUP_FILE" | cut -f1)
    echo -e "${GREEN}✓ Nén hoàn tất!${NC}"
    echo -e "\n${GREEN}=== BACKUP HOÀN THIỆN ===${NC}"
    echo -e "Backup Directory: ${BLUE}$BACKUP_DIR${NC}"
    echo -e "Compressed File:  ${BLUE}$HOME/$BACKUP_FILE${NC}"
    echo -e "File Size:        ${YELLOW}$FILE_SIZE${NC}"
    echo -e "\n${YELLOW}Bạn có thể tải xuống file:${NC}"
    echo -e "  ${CYAN}$BACKUP_FILE${NC}"
    echo -e "\n${RED}⚠️  CẢNH BÁO: GIỮ FILE TẠI NƠI AN TOÀN - CÓ CHỨA PRIVATE KEY${NC}"
else
    echo -e "${RED}✗ Nén thất bại!${NC}"
    echo -e "Directory vẫn tồn tại tại: ${BLUE}$BACKUP_DIR${NC}"
    exit 1
fi

# 8. HIỂN THỊ HƯỚNG DẪN RESTORE (OPTIONAL)
echo -e "\n${CYAN}>>> HƯỚNG DẪN RESTORE (NẾU CẦN):${NC}"
cat << 'EOF'

Để restore lại các validator keys:

1. Giải nén backup:
   tar -xzf republic_validator_keys_*.tar.gz

2. Copy priv_validator_key.json vào container:
   docker cp republic_validator_backup_*/node1/priv_validator_key.json \
     republicd_node1:/home/republic/.republicd/config/

3. Fix permission:
   docker exec republicd_node1 chown 1001:1001 /home/republic/.republicd/config/priv_validator_key.json

4. Restart container:
   docker restart republicd_node1

EOF

echo -e "${GREEN}✓ Script hoàn tất!${NC}\n"
