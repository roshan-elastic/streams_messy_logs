---
name: kill-demo
description: Kill any running instances of the log ingest demo scripts.
disable-model-invocation: true
allowed-tools: Bash
---

Kill any currently running instances of the log ingest scripts:

```
pkill -f "aws_cloudwatch_logs.sh" 2>/dev/null; pkill -f "onprem_kafka_logs.sh" 2>/dev/null
```

Confirm to the user that the demo scripts have been stopped.
