"""Enforce review dates and the target-graph assumptions of the MLS policy."""
import datetime
import pathlib
import re
import subprocess
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[2]
policy = tomllib.loads((ROOT / "crypto/deny.toml").read_text())
today = datetime.datetime.now(datetime.timezone.utc).date()
for exception in policy["advisories"]["ignore"]:
    match = re.search(r"review by (\d{4}-\d{2}-\d{2})", exception["reason"])
    if not match or today >= datetime.date.fromisoformat(match[1]):
        raise SystemExit(f"Advisory exception requires review: {exception['id']}")

for workspace, target in [("crypto", "wasm32-unknown-unknown"), ("app/rust", "aarch64-linux-android")]:
    graph = subprocess.check_output(
        ["cargo", "tree", "--locked", "--target", target, "-e", "normal,build", "--prefix", "none"],
        cwd=ROOT / workspace, text=True,
    )
    if re.search(r"^libcrux-kem v0\.0\.9\b", graph, re.MULTILINE):
        raise SystemExit(f"Review hybrid KEM advisories for {workspace} on {target}")
