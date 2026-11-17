#!/usr/bin/env bash
# End-to-end check of the deployed API, database, S3 upload and async notifier.
# Usage (in a [REAL AWS] terminal):  scripts/smoke-test.sh [run-id]
set -euo pipefail
RUN="${1:-run-$(date -u +%H%M)}"
STACK=dso303-exam-namgyelw-app
out() { aws cloudformation describe-stacks --stack-name "$STACK" \
          --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
API=$(out ApiUrl); TABLE=$(out TableName); BUCKET=$(out SubmissionsBucketName); NOTIFIER_LOGS=$(out NotifierLogGroup)
STUDENT="s0291-$RUN"
FILE="/tmp/$RUN-assignment.pdf"

date -u
echo "run=$RUN student=$STUDENT api=$API"

echo; echo "== 1. GET /exam/demo (questions only - no answer key)"
curl -sS "$API/exam/demo?studentId=$STUDENT"; echo

echo; echo "== 2. PUT /exam/demo/autosave"
curl -sS -X PUT "$API/exam/demo/autosave" -H 'content-type: application/json' \
  -d "{\"studentId\":\"$STUDENT\",\"answers\":{\"q1\":\"A\",\"q4\":\"draft saved by $RUN\"}}"; echo

echo; echo "== 3. GET /exam/demo again - the autosaved answers come back (resume after refresh)"
curl -sS "$API/exam/demo?studentId=$STUDENT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["saved"])'

echo; echo "== 4. POST /exam/demo/submit - MCQs auto-marked"
curl -sS -X POST "$API/exam/demo/submit" -H 'content-type: application/json' \
  -d "{\"studentId\":\"$STUDENT\",\"answers\":{\"q1\":\"A\",\"q2\":\"B\",\"q3\":\"C\",\"q4\":\"final answer from $RUN\"}}"; echo

echo; echo "== 5. POST /upload-url, then upload a 2 MB PDF straight to S3 (not through the API)"
head -c 2097152 /dev/urandom > "$FILE"
RESP=$(curl -sS -X POST "$API/upload-url" -H 'content-type: application/json' \
  -d "{\"studentId\":\"$STUDENT\",\"filename\":\"$RUN-assignment.pdf\"}")
KEY=$(echo "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
echo "key=$KEY"
echo "$RESP" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k, v in d["fields"].items():
    print("form = \"%s=%s\"" % (k, v))
print("url = \"%s\"" % d["url"])' > "/tmp/$RUN-upload.curlrc"
curl -sS -o /dev/null -w "S3 upload HTTP status: %{http_code} (204 = stored)\n" \
  -K "/tmp/$RUN-upload.curlrc" -F "file=@$FILE;type=application/pdf"
rm -f "/tmp/$RUN-upload.curlrc"   # it held short-lived signed credentials

echo; echo "== 6. A disallowed file type is rejected"
curl -sS -X POST "$API/upload-url" -H 'content-type: application/json' \
  -d "{\"studentId\":\"$STUDENT\",\"filename\":\"setup.exe\"}"; echo

echo; echo "== 7. Waiting 20 s for S3 -> SQS -> notifier -> SNS ..."
sleep 20
echo "-- object in S3:"
aws s3 ls "s3://$BUCKET/$KEY"
echo "-- DynamoDB: attempt items (autosave/final answers + result)"
aws dynamodb query --table-name "$TABLE" --key-condition-expression 'pk = :p' \
  --expression-attribute-values "{\":p\":{\"S\":\"ATTEMPT#demo#$STUDENT\"}}" \
  --query 'Items[].{sk:sk.S,savedAt:savedAt.S,final:final.BOOL,score:mcqScore.N,total:mcqTotal.N}'
echo "-- DynamoDB: upload record written by the async notifier"
aws dynamodb get-item --table-name "$TABLE" \
  --key "{\"pk\":{\"S\":\"UPLOAD#$STUDENT\"},\"sk\":{\"S\":\"$KEY\"}}" \
  --query 'Item.{key:sk.S,sizeBytes:sizeBytes.N,uploadedAt:uploadedAt.S}'
echo "-- notifier log lines for this run:"
aws logs filter-log-events --log-group-name "$NOTIFIER_LOGS" --filter-pattern "\"$STUDENT\"" \
  --query 'events[].message' --output text
echo; echo "Done. Inbox should show: [DSO303 exams] New upload from $STUDENT"
