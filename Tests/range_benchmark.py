"""Self-owned synthetic data only. No remote video or account is accessed."""
import hashlib, http.server, json, pathlib, re, subprocess, threading, time

root = pathlib.Path(__file__).resolve().parents[1]
work = root / 'work' / ('range-test-' + str(time.time_ns()))
work.mkdir()
payload = bytes(range(256)) * 65536
metrics = {'active': 0, 'peak': 0, 'ranges': 0}
lock = threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def do_GET(self):
        data = payload if self.path == '/fixture.bin' else (root / 'work/test-merged.mp4').read_bytes()
        start, end = 0, len(data)-1
        range_header = self.headers.get('Range')
        if range_header:
            match = re.fullmatch(r'bytes=(\d+)-(\d*)', range_header)
            if not match: self.send_error(416); return
            start = int(match[1]); end = min(end, int(match[2]) if match[2] else end)
        self.send_response(206 if range_header else 200)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Type', 'application/octet-stream' if self.path.endswith('.bin') else 'video/mp4')
        self.send_header('Content-Length', str(end-start+1))
        if range_header: self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        with lock:
            metrics['active'] += 1
            metrics['peak'] = max(metrics['peak'], metrics['active'])
            metrics['ranges'] += bool(range_header)
        try:
            for offset in range(start, end+1, 65536):
                self.wfile.write(data[offset:min(end+1, offset+65536)]); self.wfile.flush()
                if self.path.endswith('.bin'): time.sleep(0.035)
        except (BrokenPipeError, ConnectionResetError): pass
        finally:
            with lock: metrics['active'] -= 1

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f'http://127.0.0.1:{server.server_port}'
aria = root / 'work/deps/aria2c'
results = []
for connections in (1, 8):
    metrics.update(peak=0, ranges=0)
    out = work / f'connections-{connections}.bin'
    log = work / f'connections-{connections}.log'
    args = [str(aria), '--no-conf', '-x'+str(connections), '-s'+str(connections), '-k1M', '-j1',
            '--file-allocation=none', '--summary-interval=1', '--show-console-readout=true',
            '--human-readable=false', '--enable-color=false', '--console-log-level=warn',
            '--dir='+str(work), '--out='+out.name, url+'/fixture.bin']
    start = time.monotonic()
    with log.open('wb') as stream:
        process = subprocess.Popen(args, stdout=stream, stderr=subprocess.STDOUT)
        # A monitor is a separate process and must have no ownership of transfer.
        monitor = subprocess.Popen(['/usr/bin/tail', '-f', str(log)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.35); monitor.terminate(); monitor.wait(timeout=3)
        assert process.poll() is None, 'Closing log monitor stopped download'
        assert process.wait(timeout=35) == 0
    elapsed = time.monotonic()-start
    assert hashlib.sha256(out.read_bytes()).digest() == hashlib.sha256(payload).digest()
    results.append({'connections': connections, 'seconds': round(elapsed, 3), 'peak_connections': metrics['peak'], 'range_requests': metrics['ranges'], 'hash': 'PASS', 'monitor_closed_transfer_continued': True})
    time.sleep(0.1)
assert results[1]['peak_connections'] >= 2
assert results[1]['seconds'] < results[0]['seconds']
parallel = []
parallel_logs = []
for name in ('task-a', 'task-b'):
    handle = (work/(name+'.log')).open('wb'); parallel_logs.append(handle)
    process = subprocess.Popen([str(aria), '--no-conf', '-x4', '-s4', '-k1M', '--file-allocation=none',
        '--console-log-level=warn', '--dir='+str(work), '--out='+name+'.bin', url+'/fixture.bin'], stdout=handle, stderr=subprocess.STDOUT)
    parallel.append((process, work/(name+'.bin')))
time.sleep(0.3)
assert all(process.poll() is None for process, _ in parallel), 'Two tasks were not running together'
for process, path in parallel:
    assert process.wait(timeout=35) == 0
    assert hashlib.sha256(path.read_bytes()).digest() == hashlib.sha256(payload).digest()
for handle in parallel_logs: handle.close()
with (work/'ytdlp.log').open('wb') as stream:
    subprocess.run([str(root/'work/deps/yt-dlp'), '--ignore-config', '--no-plugin-dirs', '--no-cache-dir', '--no-playlist',
        '--downloader', 'http,https:'+str(aria), '--downloader-args',
        'aria2c:-x8 -s8 -j1 -k1M --summary-interval=1 --show-console-readout=true --human-readable=false --enable-color=false',
        '-o', str(work/'pipeline.mp4'), url+'/fixture.mp4'], stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=80)
assert (work/'pipeline.mp4').read_bytes() == (root/'work/test-merged.mp4').read_bytes()
report = {'synthetic_local_only': True, 'results': results, 'two_concurrent_tasks_hash': 'PASS', 'yt_dlp_aria2_pipeline_hash': 'PASS', 'speedup_local': round(results[0]['seconds']/results[1]['seconds'], 2), 'logs': str(work)}
(root/'work/range-benchmark.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
server.shutdown()
