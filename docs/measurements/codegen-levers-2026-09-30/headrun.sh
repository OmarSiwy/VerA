cd /tmp/claude-1000/-home-omare-Documents-Projects-Zig-VerA/8e3fb2cc-fae4-4ce7-b84a-3ddbec9744d1/scratchpad/cl
for i in 1 2 3; do
  while [ "$(cut -d' ' -f1 /proc/loadavg | cut -d. -f1)" -gt 60 ]; do sleep 20; done
  python3 run.py res/head.jsonl 1 @head.spec > res/head.$i.log 2>&1
  python3 runsplit.py res/headsplit.jsonl 1 headsplit.spec > res/headsplit.$i.log 2>&1
done
echo done
