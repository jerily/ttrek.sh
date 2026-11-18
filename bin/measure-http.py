#!/usr/bin/env python3
"""Small sequential anonymous GET benchmark; curl reuses connections per page."""
import argparse
import json
import math
import statistics
import subprocess
from urllib.parse import urlsplit


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://ttrek.sh")
    parser.add_argument("--samples", type=int, default=5, help="repeats after the first request per page")
    parser.add_argument("--output", help="write raw curl measurements as JSON")
    args = parser.parse_args()
    parsed = urlsplit(args.base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.query or parsed.fragment:
        parser.error("base URL must be an HTTP(S) origin or path, without query or fragment")
    if not 1 <= args.samples <= 20:
        parser.error("samples must be between 1 and 20")
    measurements = {}
    failed = False
    print("Page       First TTFB  Repeat TTFB p50/p95  Total p50   Wait p50  HTTP", flush=True)
    for path in ("/", "/forum", "/packages", "/docs", "/blog"):
        # One process per page: repeated transfers can reuse DNS/TCP/TLS.
        # No redirects: a redirect should be visible, not hidden in the timings.
        command = ["curl", "--silent", "--show-error", "--compressed",
                   "--connect-timeout", "10", "--max-time", "30", "--rate", "2/s",
                   "--write-out", "%{json}\n"]
        for _ in range(args.samples + 1):
            command += ["--output", "/dev/null", "--url", args.base_url.rstrip("/") + path]
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        measurements[path] = rows
        if result.stderr:
            print(result.stderr.strip())
        good = len(rows) == args.samples + 1 and all(
            row["http_code"] == 200 and row.get("exitcode", 0) == 0 for row in rows)
        if result.returncode or not good:
            failed = True
        if len(rows) < 2:
            print(f"{path:<10} insufficient measurements", flush=True)
            continue
        repeats = rows[1:]
        ttfb = [row["time_starttransfer"] * 1000 for row in repeats]
        total = [row["time_total"] * 1000 for row in repeats]
        wait = [(row["time_starttransfer"] - row["time_pretransfer"]) * 1000 for row in repeats]
        statuses = ",".join(str(code) for code in sorted({row["http_code"] for row in rows}))
        print(f"{path:<10} {rows[0]['time_starttransfer'] * 1000:8.1f}ms"
              f" {statistics.median(ttfb):8.1f}/{percentile(ttfb, .95):.1f}ms"
              f" {statistics.median(total):9.1f}ms {statistics.median(wait):8.1f}ms {statuses}", flush=True)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as output:
            json.dump(measurements, output, indent=2)
            output.write("\n")
    print("Wait includes network round-trip, gateway, and Lambda; it is not server execution time.")
    print("First means first client transfer, not a proven Lambda cold start. Small-sample p95 is descriptive.")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
