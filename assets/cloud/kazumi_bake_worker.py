# Kazumi cloud bake worker. Runs on a rented Runpod GPU: takes episodes over
# HTTP, bakes them with the same Anime4K chain and encoder settings as the PC,
# serves the results back, and deletes its own pod once the PC goes quiet.
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SLOTS = 2
ID_RE = re.compile(r'^[A-Za-z0-9_-]{1,64}$')
NVENC = (['-c:v', 'hevc_nvenc', '-preset', 'p5', '-rc', 'vbr', '-cq', '22', '-b:v', '0'], 'p010le')
VULKAN = (['-c:v', 'hevc_vulkan', '-rc_mode', 'cqp', '-qp', '19', '-tune', 'hq'], 'p010')
FFMPEG_RELEASES = 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest'
FFMPEG_FALLBACK = ('https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/'
                   'ffmpeg-n8.0-latest-linux64-gpl-8.0.tar.xz')


def log(message):
    print(time.strftime('%H:%M:%S'), message, flush=True)


class Worker:
    def __init__(self, root, token, cap_sec, idle_sec=600, clock=time.monotonic):
        self.root = root
        self.token = token
        self.cap_sec = cap_sec
        self.idle_sec = idle_sec
        self.clock = clock
        self.started = clock()
        self.last_contact = None
        self.state = 'booting'
        self.error = None
        self.ffmpeg = None
        self.encoder = None
        self.episodes = {}
        self.queue = []
        self.cond = threading.Condition()
        for name in ('in', 'out'):
            os.makedirs(os.path.join(root, name), exist_ok=True)

    def part_dir(self, ep):
        return os.path.join(self.root, 'in', ep)

    def source(self, ep):
        return os.path.join(self.root, 'in', ep + '.src')

    def output(self, ep):
        return os.path.join(self.root, 'out', ep + '.mp4')

    def ready(self, ffmpeg, encoder):
        self.ffmpeg, self.encoder = ffmpeg, encoder
        self.state = 'ready'
        self.last_contact = self.clock()

    def broken(self, error):
        self.state, self.error = 'broken', error
        self.last_contact = self.clock()

    def touch(self):
        # The idle clock only starts once boot is over; downloading ffmpeg can
        # take a while and nobody is talking to us yet.
        if self.last_contact is not None:
            self.last_contact = self.clock()

    def expired(self):
        now = self.clock()
        if now - self.started > self.cap_sec:
            return 'cap'
        if self.last_contact is not None and now - self.last_contact > self.idle_sec:
            return 'idle'
        return None

    def parts(self, ep):
        d = self.part_dir(ep)
        if not os.path.isdir(d):
            return {}
        return {int(n): os.path.getsize(os.path.join(d, n)) for n in os.listdir(d) if n.isdigit()}

    def put_part(self, ep, index, stream, length):
        d = self.part_dir(ep)
        os.makedirs(d, exist_ok=True)
        tmp = os.path.join(d, '%d.tmp' % index)
        left = length
        with open(tmp, 'wb') as f:
            while left > 0:
                chunk = stream.read(min(1 << 20, left))
                if not chunk:
                    break
                f.write(chunk)
                left -= len(chunk)
        if left:
            os.remove(tmp)
            raise IOError('part %d ended %d bytes early' % (index, left))
        os.replace(tmp, os.path.join(d, str(index)))
        with self.cond:
            self.episodes.setdefault(ep, self._entry('receiving'))

    def commit(self, ep, size, duration_sec, height):
        with self.cond:
            if self.episodes.get(ep, {}).get('state') in ('queued', 'baking', 'done'):
                return None
        if self.state != 'ready':
            return 'worker is %s' % self.state
        parts = self.parts(ep)
        total = sum(parts.values())
        if total != size or sorted(parts) != list(range(len(parts))):
            return 'have %d bytes in %d parts, expected %d' % (total, len(parts), size)
        with open(self.source(ep), 'wb') as out:
            for i in range(len(parts)):
                with open(os.path.join(self.part_dir(ep), str(i)), 'rb') as f:
                    shutil.copyfileobj(f, out, 1 << 20)
        shutil.rmtree(self.part_dir(ep), ignore_errors=True)
        with self.cond:
            entry = self._entry('queued')
            entry.update(durationSec=duration_sec, height=height)
            self.episodes[ep] = entry
            self.queue.append(ep)
            self.cond.notify()
        return None

    @staticmethod
    def _entry(state):
        return {'state': state, 'progress': 0.0, 'outBytes': 0, 'error': None}

    def status(self):
        with self.cond:
            episodes = {k: {f: v[f] for f in ('state', 'progress', 'outBytes', 'error')}
                        for k, v in self.episodes.items()}
        return {'state': self.state, 'error': self.error,
                'encoder': self.encoder[0][1] if self.encoder else None,
                'slots': SLOTS, 'uptimeSec': int(self.clock() - self.started),
                'capSec': self.cap_sec, 'episodes': episodes}

    def drop(self, ep):
        with self.cond:
            self.episodes.pop(ep, None)
        for p in (self.output(ep), self.source(ep)):
            try:
                os.remove(p)
            except OSError:
                pass

    def slot(self):
        while True:
            self.bake_next()

    def bake_next(self):
        with self.cond:
            while not self.queue:
                self.cond.wait()
            ep = self.queue.pop(0)
            info = self.episodes.get(ep)
            if info is None:
                return
            info['state'] = 'baking'
        error = None
        try:
            for copy_audio in (True, False):
                error = self.bake(ep, info, copy_audio)
                if error is None:
                    break
                log('%s failed (copy_audio=%s): %s' % (ep, copy_audio, error))
            size = os.path.getsize(self.output(ep)) if error is None else 0
        except Exception as e:
            # A dead slot would leave the episode "baking" while the pod bills.
            error = 'worker error: %s' % e
        try:
            os.remove(self.source(ep))
        except OSError:
            pass
        with self.cond:
            if error is None:
                info.update(state='done', progress=1.0, outBytes=size)
            else:
                info.update(state='failed', error=error)

    def bake(self, ep, info, copy_audio):
        args, fmt = self.encoder
        height = info['height']
        part = self.output(ep) + '.part'
        cmd = [self.ffmpeg, '-hide_banner', '-y', '-nostats', '-loglevel', 'error',
               '-init_hw_device', 'vulkan=vk', '-filter_hw_device', 'vk',
               '-i', self.source(ep), '-map', '0:v:0', '-map', '0:a:0?',
               '-vf', 'libplacebo=w=trunc(iw*%d/ih/2)*2:h=%d:custom_shader_path=shader.glsl:format=%s'
               % (height, height, fmt),
               *args, '-profile:v', 'main10', '-tag:v', 'hvc1',
               *(['-c:a', 'copy'] if copy_audio else ['-c:a', 'aac', '-b:a', '192k']),
               '-movflags', '+faststart', '-progress', 'pipe:1', '-f', 'mp4', part]
        duration_us = max(1.0, float(info['durationSec'])) * 1e6

        def on_line(line):
            if line.startswith('out_time_us='):
                try:
                    info['progress'] = min(1.0, max(0.0, int(line[12:]) / duration_us))
                except ValueError:
                    pass

        code, err = self.run_ffmpeg(cmd, on_line)
        if code != 0:
            lines = err.strip().splitlines()
            return 'ffmpeg %d: %s' % (code, lines[-1] if lines else '')
        os.replace(part, self.output(ep))
        return None

    def run_ffmpeg(self, cmd, on_line):
        p = subprocess.Popen(cmd, cwd=self.root, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        err = []
        reader = threading.Thread(target=lambda: err.append(p.stderr.read()))
        reader.start()
        for line in p.stdout:
            on_line(line.strip())
        p.wait()
        reader.join()
        return p.returncode, ''.join(err)


def terminate_pod(url='https://api.runpod.io/graphql'):
    # The pod's own key is refused by REST v2 but GraphQL accepts it, and
    # podTerminate is scoped to the account that owns the pod.
    pod = os.environ.get('RUNPOD_POD_ID', '')
    query = 'mutation { podTerminate(input: {podId: "%s"}) }' % pod
    req = urllib.request.Request(url, json.dumps({'query': query}).encode(), {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + os.environ.get('RUNPOD_API_KEY', ''),
    })
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.loads(r.read() or b'{}')
    if body.get('errors'):
        raise RuntimeError(body['errors'][0].get('message'))


def watchdog(worker, terminate=terminate_pod, interval=30, sleep=time.sleep):
    while True:
        reason = worker.expired()
        if reason:
            log('terminating pod (%s)' % reason)
            try:
                terminate()
                return
            except Exception as e:
                log('terminate failed: %s' % e)
        sleep(interval)


def fetch_ffmpeg(root):
    url = FFMPEG_FALLBACK
    try:
        with urllib.request.urlopen(FFMPEG_RELEASES, timeout=30) as r:
            assets = [a['browser_download_url'] for a in json.load(r)['assets']]
        # Master builds need a newer driver (610+) than Runpod hosts carry;
        # the n8.x release builds don't.
        found = [u for u in assets
                 if re.search(r'/ffmpeg-n8\.\d+-latest-linux64-gpl-8\.\d+\.tar\.xz$', u)]
        if found:
            url = sorted(found)[-1]
    except Exception as e:
        log('release lookup failed, using fallback: %s' % e)
    archive = os.path.join(root, 'ffmpeg.tar.xz')
    urllib.request.urlretrieve(url, archive)
    with tarfile.open(archive) as tar:
        member = next(m for m in tar.getmembers() if m.name.endswith('/bin/ffmpeg'))
        member.name = 'ffmpeg'
        tar.extract(member, root, filter='data')
    os.remove(archive)
    exe = os.path.join(root, 'ffmpeg')
    os.chmod(exe, 0o755)
    return exe


def write_icd(root):
    # The image's GLX ICD can't create a Vulkan instance without a display;
    # the EGL one can.
    path = os.path.join(root, 'egl_icd.json')
    with open(path, 'w') as f:
        json.dump({'file_format_version': '1.0.1',
                   'ICD': {'library_path': 'libEGL_nvidia.so.0', 'api_version': '1.4.312'}}, f)
    os.environ['VK_ICD_FILENAMES'] = path


def probe_encoder(ffmpeg, root):
    # Some hosts refuse NVENC sessions ("unsupported device"), so try a real
    # encode before trusting it.
    for args, fmt in (NVENC, VULKAN):
        cmd = [ffmpeg, '-hide_banner', '-loglevel', 'error',
               '-init_hw_device', 'vulkan=vk', '-filter_hw_device', 'vk',
               '-f', 'lavfi', '-i', 'testsrc2=s=1920x1080:d=2',
               '-vf', 'libplacebo=w=2560:h=1440:format=%s' % fmt,
               *args, '-profile:v', 'main10', '-f', 'null', '-']
        result = subprocess.run(cmd, cwd=root, stdin=subprocess.DEVNULL, capture_output=True)
        if result.returncode == 0:
            return args, fmt
        log('%s probe failed: %s' % (args[1], result.stderr.decode(errors='replace')[-300:]))
    return None


def boot(worker):
    try:
        ffmpeg = fetch_ffmpeg(worker.root)
        write_icd(worker.root)
        encoder = probe_encoder(ffmpeg, worker.root)
        if encoder is None:
            worker.broken('no working HEVC encoder (NVENC and Vulkan both failed)')
        else:
            worker.ready(ffmpeg, encoder)
    except Exception as e:
        worker.broken('boot failed: %s' % e)
    log('boot: %s %s' % (worker.state, worker.error or ''))


def make_handler(worker, terminate):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *args):
            pass

        def do_GET(self):
            self.route('GET')

        def do_HEAD(self):
            self.route('HEAD')

        def do_PUT(self):
            self.route('PUT')

        def do_POST(self):
            self.route('POST')

        def do_DELETE(self):
            self.route('DELETE')

        def reply(self, code, body=None):
            data = json.dumps(body if body is not None else {}).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            if code >= 400:
                # The request body may be unread; don't reuse the connection.
                self.send_header('Connection', 'close')
                self.close_connection = True
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(data)

        def body(self):
            return self.rfile.read(int(self.headers.get('Content-Length', 0)))

        def route(self, method):
            if not hmac.compare_digest(self.headers.get('X-Kazumi-Token', ''), worker.token):
                return self.reply(403, {'error': 'forbidden'})
            worker.touch()
            # http.server can't decode chunked bodies; reading Content-Length
            # would silently see an empty one.
            if 'chunked' in self.headers.get('Transfer-Encoding', '').lower():
                return self.reply(411, {'error': 'send Content-Length'})
            parts = self.path.split('?')[0].strip('/').split('/')
            try:
                if parts == ['status'] and method == 'GET':
                    return self.reply(200, worker.status())
                if parts == ['shader'] and method == 'PUT':
                    with open(os.path.join(worker.root, 'shader.glsl'), 'wb') as f:
                        f.write(self.body())
                    return self.reply(200)
                if parts == ['shutdown'] and method == 'POST':
                    self.reply(200)
                    threading.Thread(target=terminate, daemon=True).start()
                    return
                if len(parts) >= 2 and ID_RE.match(parts[1]):
                    ep = parts[1]
                    if parts[0] == 'in':
                        if parts[2:] == ['parts'] and method == 'GET':
                            return self.reply(200, {'parts': {str(k): v for k, v in worker.parts(ep).items()}})
                        if len(parts) == 4 and parts[2] == 'parts' and parts[3].isdigit() and method == 'PUT':
                            worker.put_part(ep, int(parts[3]), self.rfile,
                                            int(self.headers.get('Content-Length', 0)))
                            return self.reply(200)
                        if parts[2:] == ['commit'] and method == 'POST':
                            req = json.loads(self.body() or b'{}')
                            error = worker.commit(ep, int(req['size']), float(req.get('durationSec', 0)),
                                                  int(req.get('height', 1440)))
                            return self.reply(409 if error else 200, {'error': error})
                    if parts[0] == 'out' and len(parts) == 2:
                        if method in ('GET', 'HEAD'):
                            return self.send_output(ep)
                        if method == 'DELETE':
                            worker.drop(ep)
                            return self.reply(200)
                self.reply(404, {'error': 'not found'})
            except Exception as e:
                log('%s %s failed: %s' % (method, self.path, e))
                self.reply(500, {'error': str(e)})

        def send_output(self, ep):
            path = worker.output(ep)
            if not os.path.exists(path):
                return self.reply(404, {'error': 'not ready'})
            size = os.path.getsize(path)
            start, end = 0, size
            match = re.match(r'bytes=(\d+)-(\d*)$', self.headers.get('Range', ''))
            if match:
                start = int(match.group(1))
                end = min(size, int(match.group(2)) + 1 if match.group(2) else size)
            self.send_response(206 if match else 200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', str(end - start))
            self.send_header('Accept-Ranges', 'bytes')
            if match:
                self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end - 1, size))
            self.end_headers()
            if self.command == 'HEAD':
                return
            with open(path, 'rb') as f:
                f.seek(start)
                left = end - start
                while left > 0:
                    chunk = f.read(min(1 << 20, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)

    return Handler


def main():
    token = os.environ.get('KAZUMI_TOKEN', '')
    if len(token) < 32:
        sys.exit('KAZUMI_TOKEN missing')
    root = os.environ.get('KAZUMI_ROOT', '/root/kazumi')
    worker = Worker(root, token, int(os.environ.get('KAZUMI_CAP_SEC', '7200')))
    for _ in range(SLOTS):
        threading.Thread(target=worker.slot, daemon=True).start()
    threading.Thread(target=boot, args=(worker,), daemon=True).start()
    threading.Thread(target=watchdog, args=(worker,), daemon=True).start()
    server = ThreadingHTTPServer(('0.0.0.0', 8080), make_handler(worker, terminate_pod))
    server.daemon_threads = True
    log('listening on 8080')
    server.serve_forever()


if __name__ == '__main__':
    main()
