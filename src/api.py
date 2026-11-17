"""Exam API - one Lambda with a small router (HTTP API, payload v2).

GET  /exam/{examId}            questions (never the answer key) + any autosaved answers
PUT  /exam/{examId}/autosave   overwrite the student's saved answers (page calls it every 30 s)
POST /exam/{examId}/submit     save final answers, auto-mark MCQs, store the result
POST /upload-url               presigned S3 POST for a PDF/ZIP: max 50 MB, valid 5 minutes
"""
import base64
import json
import os
import re
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

import boto3

REGION = os.environ["AWS_REGION"]
TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
BUCKET = os.environ["BUCKET_NAME"]
# Regional endpoint: avoids redirects for newly created buckets
S3 = boto3.client("s3", region_name=REGION, endpoint_url=f"https://s3.{REGION}.amazonaws.com")
DEMO = json.loads((Path(__file__).parent / "demo_exam.json").read_text())

MAX_UPLOAD_BYTES = 50 * 1024 * 1024
ALLOWED_UPLOADS = {".pdf": "application/pdf", ".zip": "application/zip"}
ID_RE = re.compile(r"^[A-Za-z0-9-]{1,40}$")


def now():
    return datetime.now(timezone.utc).isoformat()


def to_json(o):
    if isinstance(o, Decimal):
        return int(o) if o == o.to_integral_value() else float(o)
    return str(o)


def reply(status, body):
    return {"statusCode": status, "headers": {"content-type": "application/json"},
            "body": json.dumps(body, default=to_json)}


def attempt_pk(exam_id, student):
    return f"ATTEMPT#{exam_id}#{student}"


def load_exam(exam_id):
    """Return the exam; seed the demo exam from code on first use (no manual step)."""
    if exam_id != DEMO["examId"]:
        return None
    item = TABLE.get_item(Key={"pk": f"EXAM#{exam_id}", "sk": "META"}).get("Item")
    if item is None:
        item = {"pk": f"EXAM#{exam_id}", "sk": "META", "title": DEMO["title"],
                "durationMinutes": DEMO["durationMinutes"], "questions": DEMO["questions"]}
        TABLE.put_item(Item=item)
        TABLE.put_item(Item={"pk": f"EXAM#{exam_id}", "sk": "KEY", "answers": DEMO["answerKey"]})
    return item


def save_answers(exam_id, data, final):
    student, answers = data.get("studentId", ""), data.get("answers")
    if not ID_RE.match(str(student)) or not isinstance(answers, dict) or len(json.dumps(answers)) > 20000:
        return None
    clean = {str(k)[:10]: str(v)[:2000] for k, v in answers.items()}
    item = {"pk": attempt_pk(exam_id, student), "sk": "ANSWERS",
            "answers": clean, "savedAt": now(), "final": final}
    TABLE.put_item(Item=item)
    return item


def get_exam(exam_id, query):
    exam = load_exam(exam_id)
    if exam is None:
        return reply(404, {"error": "exam not found"})
    saved = {}
    student = query.get("studentId", "")
    if ID_RE.match(student):
        saved = TABLE.get_item(Key={"pk": attempt_pk(exam_id, student), "sk": "ANSWERS"}).get("Item") or {}
    return reply(200, {"examId": exam_id, "title": exam["title"],
                       "durationMinutes": exam["durationMinutes"], "questions": exam["questions"],
                       "saved": {"answers": saved.get("answers", {}), "savedAt": saved.get("savedAt")}})


def autosave(exam_id, data):
    if load_exam(exam_id) is None:
        return reply(404, {"error": "exam not found"})
    item = save_answers(exam_id, data, final=False)
    if item is None:
        return reply(400, {"error": "studentId and an answers object are required"})
    return reply(200, {"saved": True, "savedAt": item["savedAt"]})


def submit(exam_id, data):
    exam = load_exam(exam_id)
    if exam is None:
        return reply(404, {"error": "exam not found"})
    item = save_answers(exam_id, data, final=True)
    if item is None:
        return reply(400, {"error": "studentId and an answers object are required"})
    key = TABLE.get_item(Key={"pk": f"EXAM#{exam_id}", "sk": "KEY"})["Item"]["answers"]
    mcqs = [q for q in exam["questions"] if q["type"] == "mcq"]
    correct = sum(1 for q in mcqs if item["answers"].get(q["id"]) == key.get(q["id"]))
    result = {"pk": item["pk"], "sk": "RESULT", "mcqScore": correct, "mcqTotal": len(mcqs),
              "shortAnswers": "awaiting tutor marking", "markedAt": now()}
    TABLE.put_item(Item=result)
    return reply(200, {"submitted": True, "mcqScore": correct, "mcqTotal": len(mcqs),
                       "shortAnswers": result["shortAnswers"], "markedAt": result["markedAt"]})


def upload_url(data):
    student, filename = str(data.get("studentId", "")), str(data.get("filename", ""))
    ext = os.path.splitext(filename.lower())[1]
    if not ID_RE.match(student) or ext not in ALLOWED_UPLOADS:
        return reply(400, {"error": "studentId and a .pdf or .zip filename are required"})
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(filename))[:100]
    key = f"submissions/{student}/{uuid.uuid4().hex[:8]}-{safe}"
    ctype = ALLOWED_UPLOADS[ext]
    post = S3.generate_presigned_post(
        BUCKET, key,
        Fields={"Content-Type": ctype},
        Conditions=[{"Content-Type": ctype}, ["content-length-range", 1, MAX_UPLOAD_BYTES]],
        ExpiresIn=300,
    )
    return reply(200, {"key": key, "url": post["url"], "fields": post["fields"],
                       "maxBytes": MAX_UPLOAD_BYTES, "expiresInSeconds": 300})


def handler(event, context):
    route = event.get("routeKey", "")
    exam_id = (event.get("pathParameters") or {}).get("examId", "")
    query = event.get("queryStringParameters") or {}
    try:
        raw = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw).decode()
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError
    except (ValueError, UnicodeDecodeError):
        return reply(400, {"error": "body must be a JSON object"})

    print(json.dumps({"route": route, "examId": exam_id,
                      "studentId": data.get("studentId") or query.get("studentId")}))

    if route == "GET /exam/{examId}":
        return get_exam(exam_id, query)
    if route == "PUT /exam/{examId}/autosave":
        return autosave(exam_id, data)
    if route == "POST /exam/{examId}/submit":
        return submit(exam_id, data)
    if route == "POST /upload-url":
        return upload_url(data)
    return reply(404, {"error": f"no route {route}"})
