---
name: abnormal-activity
description: Run both log ingest scripts in failure mode. Kills any currently running instances first.
disable-model-invocation: true
allowed-tools: Bash
---

Kill any currently running instances of the log ingest scripts, then start both in failure mode.

Run these steps in order:

1. Kill any existing processes:
   ```
   pkill -f "aws_cloudwatch_logs.sh" 2>/dev/null; pkill -f "onprem_kafka_logs.sh" 2>/dev/null
   ```

2. Start both scripts in failure mode from the project root:
   ```
   ./aws_cloudwatch_logs.sh --mode failure &
   ./onprem_kafka_logs.sh --mode failure &
   ```

Confirm to the user that both scripts are now running in failure mode.
