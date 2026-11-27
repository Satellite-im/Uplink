#!/usr/bin/env python3
"""A stand-in for a carrier's MMSC, for an emulator: keeps what is posted, answers m-send-conf, serves files to fetch."""
import http.server, os, sys, time
DIR = sys.argv[1]
N = [0]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        print(time.strftime('%H:%M:%S'), self.command, self.path, f % a, flush=True)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        N[0] += 1
        open(os.path.join(DIR, 'post-%d.bin' % N[0]), 'wb').write(body)
        open(os.path.join(DIR, 'post-%d.headers' % N[0]), 'w').write(str(self.headers))
        tid = b'T0'
        i = body.find(b'\x98')
        if i >= 0 and i < 8:
            tid = body[i + 1: body.index(b'\x00', i)]
        kind = body[1] if len(body) > 1 else 0
        # `echo 4 > flaky`: the next four messages sent meet a server in trouble (HTTP 503), then it mends.
        flaky = os.path.join(DIR, 'flaky')
        if kind == 0x80 and os.path.exists(flaky):
            left = int((open(flaky).read().strip() or '0'))
            if left > 0:
                open(flaky, 'w').write(str(left - 1))
                self.send_response(503); self.end_headers(); return
        if kind == 0x80 and os.path.exists(os.path.join(DIR, 'refuse')):   # the carrier takes it and says no
            conf = b'\x8c\x81\x98' + tid + b'\x00\x8d\x92\x92\x84\x93Unknown subscriber\x00'
        elif kind == 0x80:    # m-send-req -> m-send-conf, response-status ok, a message id
            conf = b'\x8c\x81\x98' + tid + b'\x00\x8d\x92\x92\x80\x8b' + ('fake-%d@mmsc' % N[0]).encode() + b'\x00'
        else:                 # an acknowledgement (m-notifyresp-ind, m-acknowledge-ind): nothing to say
            conf = b''
        self.send_response(200)
        self.send_header('Content-Type', 'application/vnd.wap.mms-message')
        self.send_header('Content-Length', str(len(conf)))
        self.end_headers()
        self.wfile.write(conf)
    def do_GET(self):
        # A carrier that announces an address stopping at "=" and wants the transaction id after it (Verizon):
        # `/m?message-id=<id>` serves serve/<id>, and with nothing after the "=" it is "not found".
        name = self.path.split('message-id=', 1)[1] if 'message-id=' in self.path else os.path.basename(self.path)
        path = os.path.join(DIR, 'serve', os.path.basename(name) or '-')
        if os.path.exists(os.path.join(DIR, 'down')):      # the carrier's server is having a bad minute
            self.send_response(503); self.end_headers(); return
        if not os.path.isfile(path):
            self.send_response(404); self.end_headers(); return
        data = open(path, 'rb').read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/vnd.wap.mms-message')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
http.server.ThreadingHTTPServer(('0.0.0.0', 18765), H).serve_forever()
