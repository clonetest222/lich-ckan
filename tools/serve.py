# Chạy trang trên máy: python tools/serve.py  →  http://localhost:5500
# Chỉ phục vụ đúng file trang (không phục vụ cả thư mục, để .env không lộ), chỉ nghe trên máy này.
# Mỗi lần tải lại trang là dựng lại từ file mới nhất (giống index.html trên web).
import http.server, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build import build
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5500

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0].split("#")[0] in ("/", "/index.html", "/lich-cong-luong.html"):
            body = build().encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, fmt, *args):
        sys.stdout.write("%s %s\n" % (self.log_date_time_string(), fmt % args))
        sys.stdout.flush()

print("Callender: http://localhost:%d" % PORT, flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
