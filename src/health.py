"""GET /health - proves Lambda -> DynamoDB write + read works in one call."""
import json
import os
from datetime import datetime, timezone

import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def handler(event, context):
    now = datetime.now(timezone.utc).isoformat()
    try:
        item = table.update_item(
            Key={"pk": "HEALTH", "sk": "CHECK"},
            UpdateExpression="ADD hits :one SET last_check = :now",
            ExpressionAttributeValues={":one": 1, ":now": now},
            ReturnValues="ALL_NEW",
        )["Attributes"]
        body = {
            "status": "ok",
            "table": table.name,
            "hits": int(item["hits"]),
            "last_check": item["last_check"],
            "region": os.environ["AWS_REGION"],
        }
        status = 200
    except Exception as exc:
        print(f"health check failed: {exc!r}")
        body = {"status": "error", "error": type(exc).__name__}
        status = 503
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }
