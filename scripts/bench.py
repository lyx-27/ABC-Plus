#!/usr/bin/env python3
"""Latency/quality check of the local model server, mimicking typing.
Usage: python3 scripts/bench.py ["some text to type"]"""
import json, os, re, sys, time, urllib.request

KEY = open(os.path.expanduser("~/Library/Application Support/ABCPlus/api_key")).read().strip()
URL = os.environ.get("ST_URL", "http://127.0.0.1:39281") + "/completion"
N_PREDICT = int(os.environ.get("ST_N", "16"))
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # bypass system proxy


def split(ctx):  # same rules as TextLogic.split in the IME
    m = re.search(r"[A-Za-z0-9'’]+$", ctx)
    partial = m.group(0) if m else ""
    before = ctx[: len(ctx) - len(partial)]
    if partial:
        if before.endswith(" ") and not before.endswith("  "):
            return before[:-1], " " + partial
        return before, partial
    if ctx.endswith(" ") and not ctx.endswith("  "):
        return ctx[:-1], " "
    return ctx, ""


def grammar(f, last):  # same rules as TextLogic.grammar in the IME
    if f == " " or (not f and last and last in ".!?,;:"):
        return "root ::= \" \" [A-Z\"'(] [ -~]*" if last and last in ".!?" else 'root ::= " " [!-~] [ -~]*'
    esc = f.replace("\\", "\\\\").replace('"', '\\"')
    return "root ::= [ -~]*" if not f else f'root ::= "{esc}" [ -~]*'


def complete(ctx, n=N_PREDICT):
    base, forced = split(ctx)
    body = dict(prompt=base, grammar=grammar(forced, base[-1:]), n_predict=n, temperature=0, top_k=1,
                cache_prompt=True, stop=["\n"])
    req = urllib.request.Request(URL, json.dumps(body).encode(), {
        "Content-Type": "application/json", "Authorization": "Bearer " + KEY})
    t = time.time()
    with OPENER.open(req, timeout=15) as r:
        out = json.load(r)
    c = out["content"]
    ghost = c[len(forced):] if c.startswith(forced) else "<?>" + c
    return (time.time() - t) * 1000, ghost, out.get("timings", {})


if __name__ == "__main__":
    text = sys.argv[1] if len(sys.argv) > 1 else "Hi Tom, thanks for your quick reply. I will send you the report by tomorrow"
    complete("warm up")
    lat = []
    for i in range(3, len(text) + 1):
        ms, ghost, tm = complete(text[:i])
        lat.append(ms)
        if text[i - 1] == " " or i == len(text) or i % 7 == 0:
            print(f"{ms:6.0f}ms  pp={tm.get('prompt_n', '?'):>3}  {text[:i]!r:<60} -> {ghost!r}")
    lat.sort()
    print(f"requests={len(lat)} p50={lat[len(lat)//2]:.0f}ms p90={lat[int(len(lat)*.9)]:.0f}ms max={lat[-1]:.0f}ms")
