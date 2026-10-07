# Runs the real worker with ffmpeg stubbed out (the "bake" copies the source
# to the output) so the Dart client can be tested against it. Prints the port.
import importlib.util
import os
import shutil
import sys
import threading
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    'kazumi_bake_worker',
    os.path.join(HERE, '..', '..', 'server', 'cloud', 'kazumi_bake_worker.py'))
kbw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(kbw)


def fake_ffmpeg(cmd, on_line):
    source = cmd[cmd.index('-i') + 1]
    on_line('out_time_us=500000')
    shutil.copyfile(source, cmd[-1])
    return 0, ''


worker = kbw.Worker(sys.argv[1], sys.argv[2], cap_sec=3600)
worker.run_ffmpeg = fake_ffmpeg
worker.ready('ffmpeg', kbw.NVENC)
for _ in range(kbw.SLOTS):
    threading.Thread(target=worker.slot, daemon=True).start()
server = ThreadingHTTPServer(('127.0.0.1', 0), kbw.make_handler(worker, lambda: None))
server.daemon_threads = True
print(server.server_address[1], flush=True)
server.serve_forever()
