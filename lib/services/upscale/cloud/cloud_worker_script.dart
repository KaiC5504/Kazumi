export 'cloud_worker_packed.dart';

/// Runpod accepted an 8 KB env value when this was measured (2026-10-06).
const maxPackedWorkerLength = 8000;

/// The pod has no copy of the worker, so [packedCloudWorker] travels in its env.
const cloudWorkerStartCommand =
    r'echo "$KAZUMI_WORKER" | base64 -d | gunzip > /kazumi_worker.py'
    r' && exec python3 -u /kazumi_worker.py';
