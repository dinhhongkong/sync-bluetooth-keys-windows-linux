# Đồng bộ khóa Bluetooth giữa Windows và Ubuntu

Hai hệ điều hành dùng cùng một adapter Bluetooth nhưng mặc định tạo hai khóa ghép đôi khác nhau. Các script trong thư mục này xuất khóa do Windows tạo rồi ghi khóa đó vào hồ sơ BlueZ của Ubuntu, nhờ vậy không phải xóa và ghép đôi lại tai nghe mỗi khi đổi hệ điều hành.

## Các file

- `windows-export-bluetooth-key.ps1`: chạy trên Windows để xuất Registry bằng tài khoản `SYSTEM`.
- `linux-sync-bluetooth-key.sh`: chạy trên Ubuntu để cập nhật mục `[LinkKey]` của BlueZ.
- `keys.reg` hoặc `keys.txt`: file trung gian chứa khóa bí mật; không đưa lên Git hoặc chia sẻ cho người khác.

Quy trình này áp dụng cho thiết bị Bluetooth Classic có `LinkKey`, bao gồm phần lớn tai nghe Bluetooth. Script Linux cố ý không tự đoán cấu hình đối với thiết bị chỉ dùng Bluetooth Low Energy.

## Thứ tự thực hiện

Thứ tự ghép đôi rất quan trọng:

1. Ghép tai nghe với Ubuntu ít nhất một lần để BlueZ tạo hồ sơ thiết bị.
2. Khởi động vào Windows, ghép tai nghe lần cuối và kiểm tra tai nghe kết nối được.
3. Xuất khóa trên Windows bằng script PowerShell.
4. Chép `keys.reg` sang Ubuntu.
5. Chạy script Linux để thay khóa Ubuntu bằng khóa Windows.

Nếu tai nghe đã có hồ sơ trên Ubuntu và file Windows vừa xuất còn hiệu lực, có thể bắt đầu từ bước 3.

## 1. Xuất khóa trên Windows

Mở **PowerShell bằng Run as administrator**, chuyển đến thư mục chứa script rồi chạy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows-export-bluetooth-key.ps1
```

Script sẽ:

1. Tạo `C:\ProgramData\BTKeyExport`.
2. Chỉ giữ quyền truy cập đầy đủ cho `SYSTEM` và nhóm `Administrators`.
3. Tạo một scheduled task tạm thời chạy bằng `SYSTEM`.
4. Xuất Registry `BTHPORT\Parameters\Keys` thành `keys.reg`.
5. Kiểm tra kết quả và tự xóa scheduled task, kể cả khi xuất key thất bại.

Khi thành công, file nằm tại:

```text
C:\ProgramData\BTKeyExport\keys.reg
```

Chép file này sang thư mục chứa script Linux. Không sửa nội dung hoặc đổi encoding của file. Có thể giữ tên `keys.reg`; script Linux không yêu cầu phần mở rộng cụ thể.

Do thư mục được bảo vệ, hãy chép file bằng chính cửa sổ PowerShell Administrator. Ví dụ, thay `D:\` bằng USB hoặc vị trí đích của bạn:

```powershell
Copy-Item 'C:\ProgramData\BTKeyExport\keys.reg' 'D:\keys.reg'
```

## 2. Đồng bộ khóa trên Ubuntu

Mở terminal tại thư mục chứa hai file rồi chạy:

```bash
chmod 700 linux-sync-bluetooth-key.sh
chmod 600 keys.reg
sudo ./linux-sync-bluetooth-key.sh keys.reg
```

Nếu đang dùng file tên `keys.txt`:

```bash
chmod 600 keys.txt
sudo ./linux-sync-bluetooth-key.sh keys.txt
```

Script Linux sẽ tự động:

- giải mã file Registry UTF-16;
- đọc địa chỉ adapter, địa chỉ thiết bị và `LinkKey` mà không in khóa ra màn hình;
- xác nhận hồ sơ BlueZ tương ứng đã tồn tại;
- sao lưu file `info` với hậu tố `.bak-YYYYMMDD-HHMMSS`;
- dừng Bluetooth, cập nhật riêng dòng `Key=` trong `[LinkKey]`, rồi khởi động lại dịch vụ.

Sau khi thành công, bật tai nghe và dùng địa chỉ thiết bị mà script hiển thị:

```bash
bluetoothctl trust XX:XX:XX:XX:XX:XX
bluetoothctl connect XX:XX:XX:XX:XX:XX
```

Từ lần khởi động sau, Windows và Ubuntu sẽ dùng cùng một khóa và không cần ghép đôi lại.

## Xử lý lỗi thường gặp

### `BlueZ profile does not exist`

Ubuntu chưa có hồ sơ cho địa chỉ thiết bị trong file Windows. Thực hiện lại đúng thứ tự:

1. Ghép đôi trên Ubuntu.
2. Khởi động Windows và ghép đôi lại lần cuối.
3. Xuất một file `keys.reg` mới.
4. Quay lại Ubuntu và chạy script Linux.

### `no [LinkKey] Key entry`

Thiết bị có thể đang dùng Bluetooth Low Energy hoặc hồ sơ Ubuntu chưa hoàn chỉnh. Script dừng lại để tránh ghi sai loại khóa.

### File chứa nhiều thiết bị Bluetooth

Nếu file Registry có nhiều `LinkKey`, script sẽ liệt kê các địa chỉ và dừng lại thay vì tự chọn. Chạy lại với MAC của tai nghe làm tham số thứ hai:

```bash
sudo ./linux-sync-bluetooth-key.sh keys.reg XX:XX:XX:XX:XX:XX
```

## Khôi phục bản sao lưu

Đường dẫn bản sao lưu được in ra sau mỗi lần cập nhật. Để khôi phục, thay đường dẫn bên dưới bằng đường dẫn thực tế mà script đã báo:

```bash
sudo systemctl stop bluetooth
sudo cp /var/lib/bluetooth/ADAPTER/DEVICE/info.bak-YYYYMMDD-HHMMSS \
  /var/lib/bluetooth/ADAPTER/DEVICE/info
sudo systemctl start bluetooth
```

## Bảo mật

- Không commit `keys.reg`, `keys.txt` hoặc bản sao nội dung của chúng vào Git.
- File `.gitignore` đi kèm đã loại trừ hai tên file này, nhưng vẫn nên kiểm tra trước mỗi lần commit.
- Giữ quyền file trên Ubuntu ở mức `600`.
- Sau khi đồng bộ thành công và đã lưu bản sao an toàn nếu cần, có thể xóa file xuất trên Windows và Ubuntu.
- Nếu ghép đôi lại tai nghe trên một hệ điều hành, khóa có thể thay đổi; khi đó cần xuất và đồng bộ lại.
