#! /bin/bash
#!/bin/bash
set -euo pipefail

YAML_FILE="bu-audit-k8s-crontask.yaml"
CRONJOB_NAME="bundleutils-audit"
SLEEP=10

echo "📋 Verifying CronJob exists:"
kubectl get cronjob "$CRONJOB_NAME"

echo "⏳ Waiting for the first job to be created..."
# Wait up to 2 minutes for the first job to appear
for i in {1..24}; do
  JOB_NAME=$(kubectl get jobs --sort-by=.metadata.creationTimestamp \
    --no-headers | grep "$CRONJOB_NAME" | tail -n 1 | awk '{print $1}') || true
  if [[ -n "$JOB_NAME" ]]; then
    echo "✅ Found job: $JOB_NAME"
    break
  fi
  sleep $SLEEP
done

if [[ -z "${JOB_NAME:-}" ]]; then
  echo "❌ Timed out waiting for job from CronJob '$CRONJOB_NAME'"
  exit 1
fi
sleep $SLEEP
kubectl logs -f $(kubectl get pods --selector=job-name=$(kubectl get jobs --sort-by=.metadata.creationTimestamp | grep $CRONJOB_NAME  | head -n 1 | awk '{print $1}') -o jsonpath='{.items[0].metadata.name}')
