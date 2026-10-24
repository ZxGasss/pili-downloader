"""Resume an owned HTTP fixture after terminating its download process."""
import hashlib, http.server, json, pathlib, subprocess, threading, time

root = pathlib.Path(__file__).resolve().parents[1]
work = root / 'work' / ('resume-' + str(time.time_ns()))
work.mkdir(parents=True)
payload = bytes(range(256)) * 32768
ranges = []
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        raw = self.headers.get('Range', '')
        start = int(raw.split('=')[1].split('-')[0]) if raw else 0
        ranges.append(start)
        self.send_response(206 if raw else 200)
        self.send_header('Content-Length', str(len(payload) - start))
        self.send_header('Accept-Ranges', 'bytes')
        if raw: self.send_header('Content-Range', f'bytes {start}-{len(payload)-1}/{len(payload)}')
        self.end_headers()
        try:
            for i in range(start, len(payload), 65536):
                self.wfile.write(payload[i:i+65536]); self.wfile.flush(); time.sleep(0.012)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
args = [str(root/'work/deps/aria2c'), '--no-conf', '--continue=true', '--auto-save-interval=1',
        '--file-allocation=none', '-x1', '-s1', '--dir='+str(work), '--out=owned.bin',
        f'http://127.0.0.1:{server.server_port}/owned.bin']
with (work/'transfer.log').open('wb') as log:
    process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
    time.sleep(0.65)
    process.terminate(); process.wait(timeout=8)
    assert (work/'owned.bin.aria2').exists(), 'missing checkpoint'
    before = len(ranges)
    subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, timeout=20, check=True)
assert hashlib.sha256((work/'owned.bin').read_bytes()).digest() == hashlib.sha256(payload).digest()
assert any(offset > 0 for offset in ranges[before:]), 'resume did not request saved offset'
result = {'checkpoint': True, 'resumed_from_saved_bytes': True, 'hash': 'PASS', 'server_range_offsets': ranges, 'scope': 'owned localhost fixture; not Bilibili guarantee'}
(root/'work/resume-1.3.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result))
server.shutdown()
