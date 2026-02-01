# RepublicAI All in one Toolkit

## Clone
```
git clone https://github.com/batuoc263/republicai-utils.git
cd republicai-utils
```

## Run
```
./republic-mgr.sh
```

Menu:
```
1. Cài đặt Node (Binary + StateSync)
2. Tối ưu node (cấu hình pruning và tắt indexer)
3. Quản lý Ví (Tạo/Khôi phục/Ví phụ)
4. Tạo Validator
5. Delegate (Self/Check balance ví phụ/Auto)
6. Kiểm tra Sync Status
7. Xem Logs (Systemd)
8. Export Peer Info (Lấy info node này)
9. Import Peers (Dán info node khác vào)
0. Thoát
```

Sử dụng chức năng 1 để cài đặt node
Chúc năng 2 để tối ưu node (nếu cần)
Sử dụng chức năng 6 để kiểm tra xem node đã sync chưa
Sau khi node sync, hãy tạo ví (key name là `wallet`) để faucet (hoặc vào kênh discord xin mod - hên xui)
Có balance rồi thì tạo validator (chú ý amount và min-self-delegate)