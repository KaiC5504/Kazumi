"""Turns a netprobe test into a readable report with a diagnosis.

    python summarize.py            # latest test
    python summarize.py <test id>

Fetches the per-server JSON from both boxes over ssh (aliases below).
"""

import json
import re
import statistics
import subprocess
import sys

HOSTS = {"hk": "KaiCHK", "sg": "KaiCVPS"}
LABELS = {"hk": "Hong Kong (DMIT)", "sg": "Singapore (Hetzner)"}


def ssh(host: str, command: str) -> str:
    return subprocess.run(
        ["ssh", host, command], capture_output=True, text=True, timeout=60
    ).stdout


def latest_id() -> str:
    out = ssh(HOSTS["hk"], "sudo ls -t /var/lib/netprobe/ | grep -v '^pc-' | head -1")
    return out.strip().rsplit(".", 2)[0]


def load(test_id: str) -> dict:
    tests = {}
    for name, host in HOSTS.items():
        raw = ssh(host, f"sudo cat /var/lib/netprobe/{test_id}.{name}.json 2>/dev/null")
        if raw.strip():
            tests[name] = json.loads(raw)
    return tests


def tcp_summary(samples: list) -> dict:
    """Last snapshot of each connection, from the server's side."""
    connections = {}
    rtts = []
    for sample in samples:
        lines = sample["ss"]
        for header, info in zip(lines[::2], lines[1::2]):
            peer = header.split()[-1]
            stats = dict(re.findall(r"(\w+):([\d.]+)", info))
            rtt = re.search(r"rtt:([\d.]+)/", info)
            if rtt:
                rtts.append(float(rtt.group(1)))
                stats["rtt"] = rtt.group(1)
            stats["state"] = header.split()[0]
            connections[peer] = stats
    sent = sum(int(c.get("bytes_sent", 0)) for c in connections.values())
    retrans = sum(int(c.get("bytes_retrans", 0)) for c in connections.values())
    return {
        "connections": len(connections),
        "bytesSent": sent,
        "retransPct": 100 * retrans / sent if sent else None,
        "rttMin": min(rtts) if rtts else None,
        "rttMedian": statistics.median(rtts) if rtts else None,
        "rttMax": max(rtts) if rtts else None,
    }


def mtr_rows(report: str | None) -> list[dict]:
    rows = []
    for line in (report or "").splitlines():
        m = re.match(r"\s*(\d+)\.\s+(AS\S+)\s+(\S+)\s+([\d.]+)%?\s+(\d+)\s+"
                     r"([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)", line)
        if m:
            rows.append({
                "hop": int(m[1]), "asn": m[2], "ip": m[3], "loss": float(m[4]),
                "avg": float(m[7]), "worst": float(m[9]),
            })
    return rows


def real_loss_from(rows: list[dict]) -> dict | None:
    """First hop from which every later hop shows loss too.

    Loss at one hop that later hops don't show is a router rate-limiting its
    own replies, not traffic being dropped.
    """
    answering = [r for r in rows if r["ip"] != "???"]
    if len(answering) < 2 or answering[-1]["loss"] < 2:
        return None
    floor = answering[-1]["loss"] * 0.7
    start = None
    for row in reversed(answering):
        if row["loss"] < floor:
            break
        start = row
    return start


def mbps(value):
    return "-" if value is None else f"{value:.1f} Mbps"


def ms(value):
    return "-" if value is None else f"{value:.0f} ms"


def report_server(name: str, test: dict, client: dict | None) -> list[str]:
    out = [f"== {LABELS[name]} =="]
    findings = []
    if client is None or client.get("unreachable"):
        out.append(f"  phone could not reach it: {client and client.get('unreachable')}")
        return out
    p = client["ping"]
    first = client.get("firstRequest") or {}
    out.append(f"  ping      median {ms(p['median'])}, p90 {ms(p['p90'])}, "
               f"jitter {ms(p['jitter'])}, timeouts {p['failures']}/{len(p['samples']) + p['failures']}")
    out.append(f"  first req total {ms(first.get('total'))} (dns {ms(first.get('dns'))}, "
               f"tcp {ms(first.get('connect'))}, tls {ms(first.get('tls'))}, "
               f"first byte {ms(first.get('firstByte'))}, {first.get('protocol')})")
    d1, d8 = client["download1"], client["downloadMulti"]
    shared = first.get("protocol") == "h2"
    out.append(f"  download  1 conn {mbps(d1['mbps'])} (peak {mbps(d1['peakMbps'])}, "
               f"stalled {d1['stallSeconds']}s) | {d8['connections']} conn {mbps(d8['mbps'])} "
               f"(peak {mbps(d8['peakMbps'])}, stalled {d8['stallSeconds']}s)"
               + ("  [h2: the browser shared one TCP connection]" if shared else ""))
    out.append(f"            per second, 1 conn: {d1['perSecondMbps']}")
    out.append(f"            per second, {d8['connections']} conn: {d8['perSecondMbps']}")
    load = client["pingUnderLoad"]
    out.append(f"  ping while downloading: median {ms(load['median'])}, p90 {ms(load['p90'])}, "
               f"timeouts {load['failures']}")
    u1, u4 = client["upload1"], client["upload4"]
    out.append(f"  upload    1 conn {mbps(u1['mbps'])} | 4 conn {mbps(u4['mbps'])}")

    tcp = tcp_summary(test.get("tcp", []))
    if tcp["retransPct"] is not None:
        out.append(f"  server TCP: {tcp['connections']} connections, "
                   f"{tcp['bytesSent'] / 1e6:.0f} MB sent, {tcp['retransPct']:.2f}% resent, "
                   f"rtt {ms(tcp['rttMin'])}..{ms(tcp['rttMax'])} (median {ms(tcp['rttMedian'])})")
    rows = mtr_rows(test.get("mtr"))
    if rows:
        out.append("  route back to her (server side):")
        for r in rows:
            out.append(f"    {r['hop']:>2} {r['asn']:<9} {r['ip']:<16} loss {r['loss']:>5.1f}%  "
                       f"avg {r['avg']:>6.1f} ms  worst {r['worst']:>6.1f} ms")

    if p["failures"]:
        findings.append(f"{p['failures']} of the idle pings timed out: requests are being lost outright")
    if tcp["retransPct"] is not None and tcp["retransPct"] > 1:
        findings.append(f"{tcp['retransPct']:.1f}% of data had to be resent: the path drops packets, "
                        "which is what keeps each connection slow")
    lossy = real_loss_from(rows)
    real_loss = tcp["retransPct"] is not None and tcp["retransPct"] > 0.5
    if lossy and real_loss:
        findings.append(f"loss starts at hop {lossy['hop']} ({lossy['asn']} {lossy['ip']}) "
                        "and carries through to the end")
    # Over h2 the pings queue behind the download inside the same connection,
    # so a rise there says nothing about the network.
    if load["median"] and p["median"] and load["median"] > p["median"] + 150 and not shared:
        findings.append(f"ping rises from {ms(p['median'])} to {ms(load['median'])} under load: "
                        "a buffer on the way fills up (bufferbloat)")
    if d1["mbps"] and d8["mbps"] and d8["mbps"] > 2.5 * d1["mbps"] and not shared:
        findings.append(f"{d8['connections']} connections are {d8['mbps'] / d1['mbps']:.1f}x one: "
                        "the limit is per connection (loss/latency), not her line, so the "
                        "app's parallel downloads help")
    if d8["stallSeconds"] or d1["stallSeconds"]:
        findings.append(f"downloads stalled for {d1['stallSeconds'] + d8['stallSeconds']}s in total")
    if not findings:
        findings.append("nothing wrong found on this route")
    out.append("  diagnosis:")
    out.extend(f"    - {f}" for f in findings)
    return out


def main() -> None:
    test_id = sys.argv[1] if len(sys.argv) > 1 else latest_id()
    tests = load(test_id)
    if not tests:
        raise SystemExit(f"no results for {test_id}")
    any_test = next(iter(tests.values()))
    client = any_test.get("client") or {}
    print(f"test {test_id}  from {any_test['ip']}  started {any_test['startedAt']}")
    print(f"phone: {client.get('localTime')}  network: {client.get('network')}")
    print(f"agent: {any_test['userAgent']}")
    by_server = {s["server"]: s for s in client.get("servers", [])}
    for name in HOSTS:
        print()
        if name not in tests:
            print(f"== {LABELS[name]} ==\n  no server-side record")
            continue
        print("\n".join(report_server(name, tests[name], by_server.get(name))))


if __name__ == "__main__":
    main()
