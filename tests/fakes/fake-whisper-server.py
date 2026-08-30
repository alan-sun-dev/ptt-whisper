#!/usr/bin/env python3
"""假的 whisper-server：可分別設定 /health 與 /inference 的行為。

環境變數：
  FAKE_HEALTH_MODE   ok | loading | notfound | foreign | malformed | error
  FAKE_INFER_MODE    ok | error | empty | json | slow
  FAKE_REQLOG        把收到的 /inference multipart 欄位寫成 JSON 一行
  FAKE_SERVER_TEXT   /inference 成功時回的文字
用法： fake-whisper-server.py <port>
"""
import http.server, sys, os, json, re, time

HEALTH = os.environ.get('FAKE_HEALTH_MODE', 'ok')
INFER  = os.environ.get('FAKE_INFER_MODE', 'ok')
REQLOG = os.environ.get('FAKE_REQLOG', '')
TEXT   = os.environ.get('FAKE_SERVER_TEXT', 'server transcription result')

HEALTH_RESPONSES = {
    # mode        -> (status, body)
    'ok':        (200, b'{"status":"ok"}'),
    'loading':   (503, b'{"status":"loading model"}'),
    'notfound':  (404, b'Not Found'),
    'foreign':   (200, b'<html><body>Welcome to nginx!</body></html>'),
    'malformed': (200, b'{"unexpected":"shape"}'),
    'error':     (500, b'internal error'),
}


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _send(self, status, body):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith('/health'):
            self._send(*HEALTH_RESPONSES.get(HEALTH, HEALTH_RESPONSES['ok']))
        else:
            self._send(200, b'ok')

    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n)
        if REQLOG:
            self._log_fields(body)
        if INFER == 'slow':
            time.sleep(5)
        if INFER == 'error':
            self._send(500, b'boom'); return
        if INFER == 'empty':
            self._send(200, b''); return
        if INFER == 'json':
            self._send(200, json.dumps({'text': 'json shaped'}).encode()); return
        self._send(200, (TEXT + '\n').encode())

    def _log_fields(self, body):
        """粗略解析 multipart，記錄非檔案欄位的名稱與值。"""
        fields = {}
        ctype = self.headers.get('Content-Type', '')
        m = re.search(r'boundary=(?:"([^"]+)"|([^;]+))', ctype)
        if not m:
            return
        boundary = (m.group(1) or m.group(2)).strip().encode()
        for part in body.split(b'--' + boundary):
            if b'\r\n\r\n' not in part:
                continue
            head, val = part.split(b'\r\n\r\n', 1)
            nm = re.search(rb'name="([^"]*)"', head)
            if not nm:
                continue
            name = nm.group(1).decode()
            if b'filename=' in head:
                fields[name] = '<file:%d bytes>' % len(val.rstrip(b'\r\n-'))
            else:
                fields[name] = val.rstrip(b'\r\n-').decode('utf-8', 'replace')
        with open(REQLOG, 'a') as f:
            f.write(json.dumps({'path': self.path, 'fields': fields},
                               ensure_ascii=False) + '\n')


if __name__ == '__main__':
    srv = http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H)
    srv.serve_forever()
