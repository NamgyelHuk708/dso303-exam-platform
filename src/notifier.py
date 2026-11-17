"""Async step: S3 ObjectCreated (submissions/) -> SQS -> this Lambda -> DynamoDB record + SNS email.

An exception makes SQS redeliver the message; after 3 failures it moves to the dead-letter queue.
"""
import json
import os
import urllib.parse

import boto3

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
SNS = boto3.client("sns")
TOPIC = os.environ["TOPIC_ARN"]


def handler(event, context):
    for message in event["Records"]:
        body = json.loads(message["body"])
        if body.get("Event") == "s3:TestEvent":  # S3 sends this once when the notification is configured
            print("ignoring s3:TestEvent")
            continue
        for rec in body.get("Records", []):
            key = urllib.parse.unquote_plus(rec["s3"]["object"]["key"])
            size = rec["s3"]["object"].get("size", 0)
            parts = key.split("/")
            student = parts[1] if len(parts) > 2 else "unknown"
            when = rec.get("eventTime", "")
            TABLE.put_item(Item={"pk": f"UPLOAD#{student}", "sk": key, "sizeBytes": size,
                                 "uploadedAt": when, "bucket": rec["s3"]["bucket"]["name"]})
            SNS.publish(
                TopicArn=TOPIC,
                Subject=f"[DSO303 exams] New upload from {student}"[:100],
                Message=(f"New assignment submission\n\nStudent: {student}\nFile: {parts[-1]}\n"
                         f"Size: {size / 1048576:.1f} MB\nS3 key: {key}\nUploaded: {when}\n"),
            )
            print(json.dumps({"notified": True, "student": student, "key": key, "sizeBytes": size}))
