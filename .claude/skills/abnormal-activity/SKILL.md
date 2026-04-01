---
name: abnormal-activity
description: Run both log ingest scripts in failure mode. Kills any currently running instances first. Same --preferred-schema rules as normal-activity (default /logs/_bulk, or otel/ecs when requested).
disable-model-invocation: true
allowed-tools: Bash
---

Kill any currently running instances of the log ingest scripts, then start both in failure mode.

Run these steps in order:

1. Kill any existing processes (**`|| true`** avoids `set -e` failure when nothing is running):
   ```
   pkill -f "aws_cloudwatch_logs.sh" 2>/dev/null || true; pkill -f "onprem_kafka_logs.sh" 2>/dev/null || true
   ```

2. Start both scripts in failure mode from the project root.

   **Default** (`POST /logs/_bulk`):
   ```
   ./aws_cloudwatch_logs.sh --mode failure &
   ./onprem_kafka_logs.sh --mode failure &
   ```

   **With OpenTelemetry wired stream** (`logs.otel`):
   ```
   ./aws_cloudwatch_logs.sh --mode failure --preferred-schema otel &
   ./onprem_kafka_logs.sh --mode failure --preferred-schema otel &
   ```

   **With ECS wired stream** (`logs.ecs`):
   ```
   ./aws_cloudwatch_logs.sh --mode failure --preferred-schema ecs &
   ./onprem_kafka_logs.sh --mode failure --preferred-schema ecs &
   ```

Confirm to the user which bulk path is in use and that both scripts are now running in failure mode.
