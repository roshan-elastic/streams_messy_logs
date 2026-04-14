#!/usr/bin/env python3
"""GCP Managed Services System Log Ingest — Cloud Run + Cloud SQL.

Simulates native GCP Cloud Logging `LogEntry`-shaped documents for two GCP
managed services and ships them to Elastic's `logs.ecs` bulk endpoint. Elastic
Wired Streams maps the GCP fields to ECS on ingest.

Services simulated:
  - Cloud Run revision `payment-gateway` — PLATFORM / SYSTEM events only
    (cold starts, instance scaling, deploys, readiness probes, container OOM).
    No application payloads — those live in gke-edot-logs.sh.
  - Cloud SQL for PostgreSQL 15 instance `catalog-db` — where the
    product-catalog service persists its data. Emits postgres server log
    messages (checkpoints, autovacuum, connections, backups, slow queries,
    replication lag, etc.).

Ships to: $ELASTIC_URL/logs.ecs/_bulk   (NOT an OTLP endpoint)
"""

import argparse
import json
import os
import random
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib import request, error


def load_elastic_env():
    here = Path(__file__).resolve().parent
    for candidate in (here / "elastic.env", here.parent / "elastic.env"):
        if candidate.is_file():
            for raw in candidate.read_text().splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip().strip("'").strip('"'))
            return
    sys.exit(
        "Missing elastic.env. Copy elastic.env.template to elastic.env "
        "and set ELASTIC_URL and API_KEY."
    )


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def insert_id():
    return "s" + uuid.uuid4().hex[:20]


def cloud_run_entry(project, region, failing):
    ts = now_iso()
    rev = f"payment-gateway-0004{random.randint(0, 9)}-{''.join(random.choices('abcdef', k=3))}"
    entry = {
        "@timestamp": ts,
        "insertId": insert_id(),
        "timestamp": ts,
        "receiveTimestamp": ts,
        "resource": {
            "type": "cloud_run_revision",
            "labels": {
                "project_id": project,
                "location": region,
                "service_name": "payment-gateway",
                "revision_name": rev,
                "configuration_name": "payment-gateway",
            },
        },
        "labels": {"managed-by": "cloud-run", "env": "prod"},
        "logName": f"projects/{project}/logs/run.googleapis.com%2Fvarlog%2Fsystem",
    }

    if failing:
        scenario = random.choice(["oom", "health", "startfail", "scalebusy"])
        if scenario == "oom":
            entry["severity"] = "ERROR"
            entry["logName"] = f"projects/{project}/logs/run.googleapis.com%2Fstderr"
            entry["jsonPayload"] = {
                "message": "Container terminated: memory limit of 512Mi exceeded",
                "event_type": "container_oom",
                "revision_name": rev,
                "instance_id": uuid.uuid4().hex,
            }
        elif scenario == "health":
            entry["severity"] = "ERROR"
            entry["jsonPayload"] = {
                "message": "Readiness probe failed: HTTP probe failed with statuscode: 503",
                "event_type": "readiness_probe_failed",
                "revision_name": rev,
            }
        elif scenario == "startfail":
            entry["severity"] = "ERROR"
            entry["logName"] = f"projects/{project}/logs/cloudaudit.googleapis.com%2Factivity"
            entry["jsonPayload"] = {
                "message": f"Revision {rev} failed to become ready within 240s",
                "event_type": "revision_failed",
                "revision_name": rev,
            }
        else:
            entry["severity"] = "WARNING"
            entry["jsonPayload"] = {
                "message": (
                    "The request was aborted because there was no available instance. "
                    "See https://cloud.google.com/run/docs/troubleshooting#scaling"
                ),
                "event_type": "no_available_instance",
                "revision_name": rev,
            }
    else:
        scenario = random.choice(["cold", "scaleup", "scaledown", "deploy", "ready"])
        if scenario == "cold":
            entry["severity"] = "INFO"
            entry["jsonPayload"] = {
                "message": "Cold start detected. Initializing runtime environment.",
                "event_type": "cold_start",
                "revision_name": rev,
                "container_image": "gcr.io/ecommerce-prod/payment-gateway:v1.8.3",
                "cpu_limit": "1000m",
                "memory_limit": "512Mi",
                "startup_ms": random.randint(800, 3200),
            }
        elif scenario == "scaleup":
            entry["severity"] = "NOTICE"
            entry["jsonPayload"] = {
                "message": f"Successfully spun up {random.randint(1, 3)} instance(s).",
                "event_type": "instance_scaling",
                "revision_name": rev,
                "current_instances": random.randint(2, 12),
            }
        elif scenario == "scaledown":
            entry["severity"] = "NOTICE"
            entry["jsonPayload"] = {
                "message": "Scaled down towards minimum instance count.",
                "event_type": "instance_scaling",
                "revision_name": rev,
                "current_instances": random.randint(0, 2),
            }
        elif scenario == "deploy":
            entry["severity"] = "NOTICE"
            entry["logName"] = f"projects/{project}/logs/cloudaudit.googleapis.com%2Factivity"
            entry["jsonPayload"] = {
                "message": f"Revision {rev} deployed; traffic migrated to 100%.",
                "event_type": "revision_deployed",
                "revision_name": rev,
            }
        else:
            entry["severity"] = "INFO"
            entry["jsonPayload"] = {
                "message": "Readiness probe succeeded",
                "event_type": "readiness_probe_ok",
                "revision_name": rev,
            }
    return entry


def cloud_sql_entry(project, region, failing):
    ts = now_iso()
    database_id = f"{project}:catalog-db"
    entry = {
        "@timestamp": ts,
        "insertId": insert_id(),
        "timestamp": ts,
        "receiveTimestamp": ts,
        "resource": {
            "type": "cloudsql_database",
            "labels": {
                "project_id": project,
                "region": region,
                "database_id": database_id,
            },
        },
        "labels": {"database_engine": "POSTGRES_15", "tier": "db-custom-4-16384"},
        "logName": f"projects/{project}/logs/cloudsql.googleapis.com%2Fpostgres.log",
    }

    if failing:
        scenario = random.choice(["clients", "slow", "lag", "checkpoint", "timeout"])
        if scenario == "clients":
            entry["severity"] = "ERROR"
            entry["textPayload"] = "FATAL:  sorry, too many clients already"
        elif scenario == "slow":
            entry["severity"] = "WARNING"
            entry["textPayload"] = (
                f"LOG:  duration: {random.randint(2000, 8000)}.{random.randint(100, 999)} ms  "
                "statement: SELECT p.*, s.qty FROM products p JOIN stock s "
                "ON s.sku = p.sku WHERE p.category = 'electronics'"
            )
        elif scenario == "lag":
            entry["severity"] = "WARNING"
            entry["textPayload"] = (
                "LOG:  replication lag on standby 'catalog-db-replica-1': "
                f"{random.randint(15, 180)}s"
            )
        elif scenario == "checkpoint":
            entry["severity"] = "WARNING"
            entry["textPayload"] = (
                "LOG:  checkpoints are occurring too frequently "
                f"({random.randint(5, 12)} seconds apart)"
            )
        else:
            entry["severity"] = "ERROR"
            entry["textPayload"] = "ERROR:  canceling statement due to statement timeout"
    else:
        scenario = random.choice(
            ["checkpoint", "vacuum", "connect", "disconnect", "backup", "ready"]
        )
        if scenario == "checkpoint":
            entry["severity"] = "INFO"
            entry["textPayload"] = (
                f"LOG:  checkpoint complete: wrote {random.randint(500, 4000)} buffers "
                f"({random.randint(1, 30)}.{random.randint(0, 9)}%); "
                f"write={random.randint(1, 15)}.{random.randint(100, 999)} s, "
                f"sync=0.00{random.randint(1, 9)} s, "
                f"total={random.randint(1, 16)}.{random.randint(100, 999)} s"
            )
        elif scenario == "vacuum":
            table = random.choice(
                ["products", "product_categories", "product_inventory", "product_reviews"]
            )
            entry["severity"] = "INFO"
            entry["textPayload"] = (
                f'LOG:  automatic vacuum of table "catalog.public.{table}": '
                f'index scans: 1, pages: {random.randint(10, 500)} removed, '
                f'tuples: {random.randint(50, 2000)} removed, '
                f'{random.randint(10000, 200000)} remain'
            )
        elif scenario == "connect":
            entry["severity"] = "INFO"
            entry["textPayload"] = (
                "LOG:  connection authorized: user=catalog_app database=catalog "
                "application_name=product-catalog-svc"
            )
        elif scenario == "disconnect":
            entry["severity"] = "INFO"
            entry["textPayload"] = (
                f"LOG:  disconnection: session time: 0:00:{random.randint(1, 59):02d}."
                f"{random.randint(100, 999)} user=catalog_app database=catalog"
            )
        elif scenario == "backup":
            entry["severity"] = "NOTICE"
            entry["textPayload"] = (
                f"LOG:  automated backup completed successfully "
                f"(size: {random.randint(3, 8)}.{random.randint(0, 9)} GB, "
                f"duration: 00:0{random.randint(1, 5)}:{random.randint(10, 59)})"
            )
        else:
            entry["severity"] = "INFO"
            entry["textPayload"] = "LOG:  database system is ready to accept connections"
    return entry


def entry_short(entry):
    if "jsonPayload" in entry:
        msg = entry["jsonPayload"].get("message", "")
    else:
        msg = entry.get("textPayload", "")
    sev = entry.get("severity", "")
    return f"[{sev}] {msg}"[:90]


def render_board(mode, state, batch, status, url, samples, err):
    sys.stdout.write("\033[2J\033[H")
    print(
        f"☁️  GCP MANAGED SERVICES INGEST | MODE: {mode} | STATE: {state} "
        f"| BATCH: {batch} | HTTP: {status}"
    )
    print(f"API: POST {url}")
    print("-" * 100)
    print(f"{'RESOURCE':<42} | {'LATEST SAMPLE':<55}")
    print("-" * 100)
    print(f"{'cloud_run_revision / payment-gateway':<42} | {samples['cloud_run']:<55}")
    print(f"{'cloudsql_database / catalog-db':<42} | {samples['cloud_sql']:<55}")
    if status != 200:
        print(f"\n❌ API ERROR ({status}): {err}")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", default="normal", choices=["normal", "failure"])
    parser.add_argument("--logs-per-request", type=int, default=100)
    args = parser.parse_args()

    load_elastic_env()
    elastic_url = os.environ.get("ELASTIC_URL")
    api_key = os.environ.get("API_KEY")
    if not elastic_url or not api_key:
        sys.exit("ELASTIC_URL and API_KEY must be set in elastic.env.")

    project = "ecommerce-prod"
    region = "us-west1"
    bulk_url = f"{elastic_url.rstrip('/')}/logs.ecs/_bulk"
    failing = args.mode == "failure"
    state = "FAILING" if failing else "HEALTHY"
    samples = {"cloud_run": "", "cloud_sql": ""}

    while True:
        lines = []
        for _ in range(args.logs_per_request):
            if random.random() < 0.5:
                e = cloud_run_entry(project, region, failing)
                samples["cloud_run"] = entry_short(e)
            else:
                e = cloud_sql_entry(project, region, failing)
                samples["cloud_sql"] = entry_short(e)
            lines.append('{"create": {}}')
            lines.append(json.dumps(e))
        payload = ("\n".join(lines) + "\n").encode()

        req = request.Request(
            bulk_url,
            data=payload,
            method="POST",
            headers={
                "Authorization": f"ApiKey {api_key}",
                "Content-Type": "application/x-ndjson",
            },
        )
        status, err_body = None, ""
        try:
            with request.urlopen(req, timeout=30) as resp:
                status = resp.status
        except error.HTTPError as e:
            status = e.code
            try:
                err_body = e.read().decode(errors="replace")
            except Exception:
                err_body = str(e)
        except Exception as e:
            err_body = str(e)

        render_board(args.mode, state, args.logs_per_request, status, bulk_url, samples, err_body)
        time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
