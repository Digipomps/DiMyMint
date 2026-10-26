#!/usr/bin/env python3
"""Run the exact-source release gate against a new, loopback-only test cluster.

Requires PostgreSQL tools on PATH. Never uses an existing database or removes
files. The temporary cluster and receipt remain available for failure analysis.
"""

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    binaries = {}
    for name in ("initdb", "pg_ctl", "createdb", "psql"):
        binaries[name] = shutil.which(name)
        if binaries[name] is None:
            raise SystemExit(f"Required PostgreSQL tool is unavailable: {name}")
    source = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repo, text=True
    ).strip()
    if os.environ.get("DIMYMINT_EXPECTED_SOURCE_SHA") != source:
        raise SystemExit("DIMYMINT_EXPECTED_SOURCE_SHA must match this checkout")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=repo):
        raise SystemExit("Disposable release gate requires a clean checkout")

    root = Path(tempfile.mkdtemp(prefix="dimymint-postgres-"))
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("PG")
           and not key.startswith("DIMYMINT_TEST_POSTGRES")}
    passfile = root / "empty.pgpass"
    passfile.touch(mode=0o600)
    env["PGPASSFILE"] = str(passfile)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    data = root / "data"
    receipt = {"source": source, "root": str(root), "port": port,
               "gateExit": None, "stopped": False}
    # The runner is disposable and the only network listener is loopback.
    # Random port selection failing to bind is an error, never a fallback to
    # another database. The short socket path avoids macOS sockaddr_un limits.
    socket_dir = Path(tempfile.mkdtemp(prefix="mint-pg-", dir="/tmp"))
    receipt["socketDirectory"] = str(socket_dir)
    started = False
    try:
        with (root / "init.log").open("w") as log:
            subprocess.run(
                [binaries["initdb"], "-D", str(data), "-U", "security_gate",
                 "--auth-local=trust", "--auth-host=trust", "--no-locale",
                 "-E", "UTF8"], env=env, stdout=log,
                stderr=subprocess.STDOUT, check=True
            )
        options = (f"-h 127.0.0.1 -p {port} -k {socket_dir} "
                   "-c shared_buffers=16MB -c max_connections=32")
        started = True
        subprocess.run(
            [binaries["pg_ctl"], "-D", str(data), "-l", str(root / "postgres.log"),
             "-o", options, "-w", "start"], env=env, check=True
        )
        subprocess.run(
            [binaries["createdb"], "-h", "127.0.0.1", "-p", str(port),
             "-U", "security_gate", "security_gate"], env=env, check=True
        )
        env["DIMYMINT_TEST_POSTGRES_URL"] = (
            f"postgresql://security_gate@127.0.0.1:{port}/security_gate?sslmode=disable"
        )
        env["DIMYMINT_TEST_POSTGRES_PSQL_URL"] = env["DIMYMINT_TEST_POSTGRES_URL"]
        env["DIMYMINT_TEST_POSTGRES_URL"] += "&minimum_connections=1&maximum_connections=20"
        env["DIMYMINT_TEST_POSTGRES_DISPOSABLE"] = "YES"
        result = subprocess.run(
            ["/bin/bash", "scripts/verify-stripe-entitlement-provider.sh", "release"],
            cwd=repo, env=env, timeout=1500
        )
        receipt["gateExit"] = result.returncode
    finally:
        if started and (data / "postmaster.pid").exists():
            stop = subprocess.run(
                [binaries["pg_ctl"], "-D", str(data), "-m", "fast", "-w", "stop"],
                env=env, timeout=60
            )
            receipt["stopped"] = stop.returncode == 0
        else:
            receipt["stopped"] = True
        (root / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt), flush=True)
    return receipt["gateExit"] if receipt["stopped"] else 1


if __name__ == "__main__":
    sys.exit(main())
