#!/usr/bin/env python3
"""Minimal client for a GhidraMCP headless server's HTTP API.

The MCP bridge only auto-discovers one instance, so when several headless servers
are running (one per binary, see start-server-for-file.bat) it is simpler to talk
to the right port directly.

Usage:
  python ghidra_api.py <port> <endpoint> [k=v ...]
  python ghidra_api.py 8090 /search_strings search_term=PCIeTunnel limit=20
"""
import json
import sys
import urllib.parse
import urllib.request

def call(port, endpoint, **params):
    url = f"http://127.0.0.1:{port}{endpoint}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=120) as r:
        body = r.read().decode("utf-8", "replace")
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body

if __name__ == "__main__":
    port, endpoint = sys.argv[1], sys.argv[2]
    kw = dict(a.split("=", 1) for a in sys.argv[3:])
    res = call(port, endpoint, **kw)
    print(json.dumps(res, indent=2) if not isinstance(res, str) else res)
