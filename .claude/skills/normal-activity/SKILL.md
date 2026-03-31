---
name: normal-activity
description: Run both log ingest scripts in normal (healthy) mode. Kills any currently running instances first.
disable-model-invocation: true
allowed-tools: Bash
---

Kill any currently running instances of the log ingest scripts, then start both in normal mode.

Run these steps in order:

1. Kill any existing processes:
   ```
   pkill -f "aws_cloudwatch_logs.sh" 2>/dev/null; pkill -f "onprem_kafka_logs.sh" 2>/dev/null
   ```

2. Start both scripts in the background from the project root:
   ```
   ./aws_cloudwatch_logs.sh &
   ./onprem_kafka_logs.sh &
   ```

Confirm to the user that both scripts are now running in normal/healthy mode.
