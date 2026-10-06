# Dựng index.html từ lich-cong-luong.html: thêm phần đầu tài liệu chuẩn (doctype, mã chữ, khổ màn hình điện thoại)
# để đưa lên web (GitHub Pages…). lich-cong-luong.html giữ nguyên làm bản gốc.
#   python tools/build.py
import io, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
HEAD = """<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#2563EB">
</head>
<body>
"""

def build():
    src = io.open(os.path.join(ROOT, "lich-cong-luong.html"), encoding="utf-8").read()
    # hai thẻ meta trong bản gốc đã nằm ở phần đầu tài liệu: bỏ cho khỏi lặp
    src = src.replace('<meta charset="utf-8">\n', "", 1).replace('<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n', "", 1)
    return HEAD + src + "\n</body>\n</html>\n"

if __name__ == "__main__":
    out = os.path.join(ROOT, "index.html")
    io.open(out, "w", encoding="utf-8", newline="\n").write(build())
    print("built", os.path.normpath(out))
