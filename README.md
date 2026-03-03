# Streams Messy Logs

## Intro

This repository helps you send **synthetic logs** into Elastic: AWS-style logs (as if collected by CloudWatch) and on-premises-style logs from a variety of services and infrastructure. Use it to demo [Elastic Streams](https://www.elastic.co/docs/solutions/observability/streams/wired-streams), partitioning, processing, and AI-assisted troubleshooting without touching production systems.

The following diagram shows how data flows from the two simulated sources into Elastic wired streams:

![Architecture](Architecture.png)

- **AWS path**: The `aws_cloudwatch_logs.sh` script simulates logs that would normally be collected by **CloudWatch** from services like API Gateway, Lambda, EKS, WAF, CloudFront, SQS, DynamoDB, and VPC flow logs. These are sent directly to your Elastic cluster as bulk log documents.

- **On-prem path**: The `onprem_kafka_logs.sh` script simulates logs from a **centralised logs team** that aggregates logs from on-prem systems (load balancers, mainframe, Oracle, Active Directory, VMware, WebSphere MQ, Linux jumphosts, etc.) via a **Kafka bus** and then ships them to Elastic. The script plays the role of that pipeline, posting batches to the same wired streams endpoint.

Both scripts use the Elastic **Bulk API** to send data to wired streams endpoints (`logs.otel` or `logs.ecs`).

---

## Getting Started

### Prerequisites

- **zsh** (scripts are written for zsh)
- **Elastic Cloud** (or Elastic Stack 9.4+) with **wired streams enabled**
- **API key** with write access to your cluster

### Turn on wired streams

Before sending data, enable wired streams in your deployment:

1. In Kibana, go to **Streams** (via the navigation menu or global search), then open **Settings**.
2. Turn on **Enable wired streams**.

See the [official guide](https://www.elastic.co/docs/solutions/observability/streams/wired-streams#streams-wired-streams-enable) for details.

### Configure credentials

Credentials are not stored in the repo. Create a local config from the template:

```bash
cp elastic.env.template elastic.env
```

Edit `elastic.env` and set:

- **ELASTIC_URL** — your Elasticsearch endpoint (e.g. `https://your-deployment.es.region.gcp.elastic.cloud`)
- **API_KEY** — a base64 API key with index write permissions

The file `elastic.env` is gitignored and will not be committed.

### Run the scripts

**AWS-style (CloudWatch) logs:**

```bash
./aws_cloudwatch_logs.sh
```

**On-prem / Kafka-style logs:**

```bash
./onprem_kafka_logs.sh
```

You can run one or both. Each script sends batches to the wired streams Bulk API every second. The default target is `logs.otel` (OpenTelemetry-normalised format). To use ECS field names without transformation, pass `--preferred-schema ecs`:

```bash
./aws_cloudwatch_logs.sh --preferred-schema ecs
./onprem_kafka_logs.sh --preferred-schema ecs
```

---

## Demo

A good way to demo Streams and the AI assistant is to run a short “incident and resolution” cycle.

### 1. Baseline (normal)

Start one or both scripts in normal mode and let them run for a few minutes so the cluster has a baseline of “healthy” logs.

### 2. Inject failure

Stop the scripts and restart them with `--mode failure`:

```bash
./aws_cloudwatch_logs.sh --mode failure
./onprem_kafka_logs.sh --mode failure
```

Keep this running for a few minutes so there is a clear “during incident” window.

In failure mode:

- **AWS script**: injects 504 Gateway Timeouts and connection failures (e.g. payment/checkout paths), while other paths may still show 200 OK.
- **On-prem script**: switches services to a CRITICAL state (e.g. DB2 lock conflicts, Oracle TNS timeouts, F5 pool down, MQ queue depth warnings).

![Architecture - failure scenario](Architecture%20-%20failure%20scenario.png)

### 3. Ask the AI Assistant

Use the [Elastic AI Agent](https://www.elastic.co/docs/explore-analyze/ai-features/agent-builder/builtin-agents-reference#elastic-ai-agent) (or Observability-focused agent) in Agent Builder. For example:

- *“People are complaining they can’t make payments — tell me why.”*
- *“Show me visualisations of when the issue started.”*

### 4. Mitigate (back to normal)

Stop the scripts and run them again **without** `--mode failure` to simulate recovery.

### 5. Confirm resolution

Ask the assistant again:

- *“Is the payment problem resolved?”*
- *“Show me proof with a timeline of before, during, and after the incident.”*

Using Streams (partitioning, processing) and the AI assistant on the same data shows how structured logs and observability tools support detection, explanation, and proof of resolution.

---

## Reference

### Wired streams and the Bulk API

Data is sent to [Elastic wired streams](https://www.elastic.co/docs/solutions/observability/streams/wired-streams), which act as the entry point for log data. Two endpoints are used, depending on `--preferred-schema`:

- **`logs.otel`** — Data is normalised to OpenTelemetry-style fields (e.g. `message` → `body.text`, `log.level` → `severity_text`). See the [field naming table](https://www.elastic.co/docs/solutions/observability/streams/wired-streams#streams-wired-streams-field-naming).
- **`logs.ecs`** — Original ECS field names are preserved without transformation.

The scripts use the [Bulk API](https://www.elastic.co/docs/solutions/observability/streams/wired-streams#streams-wired-streams-ship) (`POST /logs.otel/_bulk` or `POST /logs.ecs/_bulk`) with `create` actions, as described in the [Ship data to streams](https://www.elastic.co/docs/solutions/observability/streams/wired-streams#streams-wired-streams-ship) documentation.

After data is in a wired stream, you can:

- **Partition** it into child streams (e.g. by source or team) for clearer organisation and different retention: [Partition data into child streams](https://www.elastic.co/docs/solutions/observability/streams/management/partitioning).
- **Process documents** (extract fields, parse, filter) so logs are structured and useful for users and agents: [Process documents](https://www.elastic.co/docs/solutions/observability/streams/management/extract).

### Command-line flags

| Flag | Description |
|------|-------------|
| `--mode failure` | Switch to a failure scenario (errors, timeouts, critical states). |
| `--logs-per-request N` | Number of log documents per bulk request (default: 100). |
| `--preferred-schema otel \| ecs` | Wired stream schema: `otel` (default) or `ecs`. |

### File layout

| File | Purpose |
|------|---------|
| `aws_cloudwatch_logs.sh` | Sends synthetic AWS/CloudWatch-style logs to wired streams. |
| `onprem_kafka_logs.sh` | Sends synthetic on-prem/Kafka-style logs to wired streams. |
| `elastic.env.template` | Template for `ELASTIC_URL` and `API_KEY`. Copy to `elastic.env` and fill in. |
| `elastic.env` | Local credentials (gitignored). Create from template; do not commit. |
| `Architecture.png` | Diagram of normal data flow. |
| `Architecture - failure scenario.png` | Diagram of failure scenario. |

### Links

- [Wired streams](https://www.elastic.co/docs/solutions/observability/streams/wired-streams)
- [Wired streams field naming](https://www.elastic.co/docs/solutions/observability/streams/wired-streams#streams-wired-streams-field-naming)
- [Turn on wired streams](https://www.elastic.co/docs/solutions/observability/streams/wired-streams#streams-wired-streams-enable)
- [Ship data to streams (Bulk API)](https://www.elastic.co/docs/solutions/observability/streams/wired-streams#streams-wired-streams-ship)
- [Partition data into child streams](https://www.elastic.co/docs/solutions/observability/streams/management/partitioning)
- [Process documents](https://www.elastic.co/docs/solutions/observability/streams/management/extract)
- [Elastic AI Agent (Agent Builder)](https://www.elastic.co/docs/explore-analyze/ai-features/agent-builder/builtin-agents-reference#elastic-ai-agent)
