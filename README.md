# Callender · Crystal Loans

Lịch làm việc, bảng lương, hồ sơ khách vay, Rules chứng từ và thuật ngữ trong một trang web. Dùng được trên máy tính và điện thoại, có tiếng Việt và tiếng Anh, giao diện sáng và tối.

- Chưa đăng nhập: bản xem công khai. Ai có link cũng xem được mọi thông tin của công ty có tên trùng một **tag công khai** (bảng `public_tags`, hiện là Crystal Loans): Client's Profile, Công việc, Master Data, Rules, Thuật ngữ và Lịch. Chỉ xem; tiền công, kỳ lương, thiết lập và các công ty khác đều ẩn. Không kết nối được Supabase thì dùng dữ liệu lưu trên máy như trước.
- Đăng nhập: dữ liệu là của riêng tài khoản, lưu trên Supabase, mở ở máy nào cũng thấy.
- Lịch chung: ai mở trang cũng xem được các ca mọi người đã đặt (chỉ xem). Mỗi người tự chọn ca của mình hiện bao nhiêu chi tiết, chung hoặc riêng từng công ty.
- Tạo ca làm cần đăng nhập.
- Admin: khoá / mở khoá tài khoản, thêm / bỏ tag công khai, xoá ca của người khác trên lịch chung.

## File

| File | Là gì |
|---|---|
| `lich-cong-luong.html` | Bản gốc của app, sửa ở đây |
| `index.html` | Bản để đưa lên web, dựng từ bản gốc bằng `python tools/build.py` |
| `supabase/schema.sql` | Toàn bộ database: bảng, quyền (RLS), hàm |
| `tools/serve.py` | Chạy thử trên máy: `python tools/serve.py` → http://localhost:5500 |
| `tools/build.py` | Dựng lại `index.html` sau khi sửa bản gốc |

## Cài Supabase

1. Supabase → **SQL Editor** → dán toàn bộ `supabase/schema.sql` → **Run**. Chạy lại nhiều lần cũng không sao.
2. **Authentication → URL Configuration**: đặt **Site URL** và thêm vào **Redirect URLs** địa chỉ trang (ví dụ `http://localhost:5500` hoặc địa chỉ GitHub Pages), để link xác nhận email và link đặt lại mật khẩu mở đúng trang.
3. Tài khoản mới luôn là **member**. Đặt **admin** chỉ làm trong Supabase:
   ```sql
   update public.profiles set role = 'admin' where email = 'ten@congty.com';
   ```
4. Tag công khai: admin sửa trong app (Thiết lập → Tag công khai) hoặc ngay trong Supabase:
   ```sql
   insert into public.public_tags (tag) values ('Crystal Loans');
   delete from public.public_tags where tag = 'Crystal Loans';
   ```

Trong trang chỉ có URL và khoá **publishable** của Supabase (được phép công khai; quyền thật do RLS quyết định). Khoá **secret** để trong `.env` trên máy, không bao giờ đưa lên repo.

## Đưa lên web (GitHub Pages)

Repo → **Settings → Pages** → Source: *Deploy from a branch* → Branch `main`, thư mục `/ (root)`. Trang chạy từ `index.html`. Nhớ thêm địa chỉ Pages vào Redirect URLs của Supabase (bước 2 ở trên).
