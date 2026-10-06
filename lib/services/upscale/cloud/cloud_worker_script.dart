import 'dart:convert';
import 'dart:io';

const cloudWorkerAsset = 'assets/cloud/kazumi_bake_worker.py';

/// Runpod accepted an 8 KB env value when this was measured (2026-10-06).
const maxPackedWorkerLength = 8000;

/// The pod has no copy of the worker, so it travels in its env.
String packWorkerScript(String source) =>
    base64.encode(GZipCodec(level: 9).encode(utf8.encode(source)));

const cloudWorkerStartCommand =
    r'echo "$KAZUMI_WORKER" | base64 -d | gunzip > /kazumi_worker.py'
    r' && exec python3 -u /kazumi_worker.py';
