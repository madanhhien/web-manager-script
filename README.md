# WebManager v4 — Hướng dẫn nhanh (CentOS 7)

## Chạy script

```bash
sudo -i
mkdir -p /root/webserver-manager
cp /duong/dan/den/webmanager-v4.sh /root/webserver-manager/
cd /root/webserver-manager
bash -n webmanager-v4.sh
chmod +x webmanager-v4.sh
./webmanager-v4.sh
```

Chú ý: đường dẫn `/duong/dan/den/` là **ví dụ**, thay bằng nơi bạn đã chép file lên CentOS. Cần cài đặt Apache (`httpd`), BIND (`bind`, `bind-utils`) và thiết lập DNS theo môi trường CentOS 7. Nên sử dụng IP tĩnh và cấu hình máy thử nghiệm truy vấn DNS BIND của server; tên miền nội bộ không phải tên miền công khai.

## Thử chức năng 6

1. Chọn `6`.
2. Domain: `demo2.test` (nên dùng tên chưa tồn tại).
3. Thư mục cha: `/srv/websites` (hoặc Enter để dùng mặc định).
4. IP web server: dùng IP thực tế của máy 
5. Chọn `1` để xác nhận hoặc `0` để hủy.
6. Kiểm tra `http://demo2.test/` trên Firefox của CentOS sử dụng DNS BIND nội bộ.

## Thử backup / delete / restore

1. Chọn `7` để tạo backup.
2. Chọn `10`, nhập `demo2.test`, gõ **YES** để xóa. Website sẽ ngừng truy cập.
3. Chọn `8`, nhập **tên file** backup vừa tạo, gõ `yes` để khôi phục.
4. Tải lại Firefox; website phải hoạt động lại.

Backup v4 lấy thêm các đường dẫn website từ các VirtualHost `webmanager-*.conf`. Khi khôi phục, script kiểm tra file backup và DocumentRoot để hạn chế giải nén ngoài danh sách website quản lý. Trước khi thao tác với dữ liệu quan trọng, nên có snapshot VMware/bản backup riêng.

## Lưu ý về thư mục tùy chọn

- Nhập đường dẫn **tuyệt đối** đến thư mục website; không nhập đường dẫn file `index.html` và không cần thêm domain vào cuối.
- Không dùng các thư mục hệ thống nhạy cảm (`/etc`, `/root`, `/usr`, `/tmp`, ...), đường dẫn có symlink hoặc sử dụng lại thư mục website đã tồn tại.
- Apache cần quyền đi qua các thư mục website. Ví dụ `/home/ten-user` hay có quyền `700`, Apache sẽ không truy cập được nếu không sửa quyền phù hợp. Để dễ demo, nên dùng `/srv/websites` hoặc `/var/www/webmanager-sites`.
- Trên CentOS 7 bật SELinux, website ở thư mục tùy chọn có thể cần thêm cấu hình bối cảnh SELinux cho thư mục cha; script có gán nhãn `httpd_sys_content_t` cho thư mục website nhưng không tự sửa quyền/nhãn của toàn bộ thư mục website.
- Không có tên miền nào được tạo công khai trên Internet; các máy truy cập cần dùng DNS BIND nội bộ.
- CentOS 7 đã hết hỗ trợ; `yum` có thể gặp lỗi kho phần mềm trên máy mới.
