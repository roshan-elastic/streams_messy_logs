---
name: normal-activity
description: Run both log ingest scripts in normal (healthy) mode. Kills any currently running instances first. Default bulk path is POST /logs/_bulk; use --preferred-schema otel or ecs when the user asks for wired streams (9.4.0+).
disable-model-invocation: true
allowed-tools: Bash
---

Kill any currently running instances of the log ingest scripts, then start both in normal mode.

Run these steps in order:

1. Kill any existing processes (use **`|| true`** so a “no such process” exit status does not abort under `set -e`):
   ```
   pkill -f "aws_cloudwatch_logs.sh" 2>/dev/null || true; pkill -f "onprem_kafka_logs.sh" 2>/dev/null || true
   ```

2. Start both scripts in the background from the project root.

   **Default** (no preferred schema — `POST /logs/_bulk` on both; yellow INFO about 9.4.0+ deprecation):
   ```
   ./aws_cloudwatch_logs.sh &
   ./onprem_kafka_logs.sh &
   ```

   **If the user asks for OpenTelemetry / OTel / `logs.otel` / wired streams with OTel** — add **`--preferred-schema otel`** to **both** commands (green INFO shows target URL):
   ```
   ./aws_cloudwatch_logs.sh --preferred-schema otel &
   ./onprem_kafka_logs.sh --preferred-schema otel &
   ```

   **If the user asks for ECS / `logs.ecs`** — use **`--preferred-schema ecs`** on **both**:
   ```
   ./aws_cloudwatch_logs.sh --preferred-schema ecs &
   ./onprem_kafka_logs.sh --preferred-schema ecs &
   ```

Confirm to the user which bulk path is in use (default vs otel vs ecs) and that both scripts are running in normal/healthy mode.
