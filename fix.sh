#!/bin/bash
# ============================================================
# AMS 수정 스크립트 v2 - 출석API 500오류 수정 + GitHub 푸시
# ============================================================
set -e
APP_DIR="$HOME/AMS"
BACKEND="$APP_DIR/backend/app.py"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="thelab-bobkim/AMS"

echo "================================================"
echo " AMS v2 수정 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "================================================"

# ── 1단계: 오류 진단 ────────────────────────────
echo "[1] 현재 오류 확인..."
docker logs attendance-backend --tail=20 2>&1 | grep -E "Error|error|Traceback|500" | tail -10 || true

# ── 2단계: 출석 API 500 오류 수정 ───────────────
echo "[2] 출석 API 수정 (rec.to_dict() → 직접 속성 접근)..."
python3 - << 'PYEOF'
import sys, os, re

path = os.path.expanduser('~/AMS/backend/app.py')
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# record_map = {} 라인 찾기
rm_line = None
for i, ln in enumerate(lines):
    if re.match(r'\s+record_map\s*=\s*\{\}', ln):
        rm_line = i
        break

if rm_line is None:
    print("  [오류] record_map 라인 미발견")
    sys.exit(1)

# return jsonify( 라인 찾기 (code: 200 이든 result 이든)
ret_line = None
for i in range(rm_line, min(rm_line + 25, len(lines))):
    if re.search(r'return jsonify\(', lines[i]):
        ret_line = i
        break

if ret_line is None:
    print("  [오류] return jsonify 라인 미발견")
    sys.exit(1)

print(f"  교체 범위: {rm_line+1} ~ {ret_line+1}줄")
print(f"  현재 코드 (문제부분):")
for i in range(rm_line, ret_line+1):
    print(f"    {i+1}: {lines[i].rstrip()}")

# 들여쓰기 감지
indent = len(lines[rm_line]) - len(lines[rm_line].lstrip())
p  = ' ' * indent
p2 = p + '    '

# ✅ 수정: to_dict() 대신 직접 속성 접근 + strftime으로 시간 직렬화
new_block = (
    f"{p}record_map = {{}}\n"
    f"{p}for rec in attendance_records:\n"
    f"{p2}day_key = str(rec.date.day)\n"
    f"{p2}try:\n"
    f"{p2}    cin = rec.check_in_time.strftime('%H:%M') if rec.check_in_time else ''\n"
    f"{p2}except Exception:\n"
    f"{p2}    cin = str(rec.check_in_time) if rec.check_in_time else ''\n"
    f"{p2}record_map.setdefault(rec.employee_id, {{}})[day_key] = {{\n"
    f"{p2}    'check_in': cin,\n"
    f"{p2}    'type': rec.record_type or 'normal',\n"
    f"{p2}    'note': rec.note or '',\n"
    f"{p2}    'source': rec.data_source or 'manual'\n"
    f"{p2}}}\n"
    f"{p}result = []\n"
    f"{p}for emp in employees:\n"
    f"{p2}result.append({{\n"
    f"{p2}    'id': emp.id,\n"
    f"{p2}    'name': emp.name,\n"
    f"{p2}    'department': emp.department or '',\n"
    f"{p2}    'days': record_map.get(emp.id, {{}})\n"
    f"{p2}}})\n"
    f"{p}return jsonify({{'code': 200, 'data': result, 'year': year, 'month': month}})\n"
)

new_lines = lines[:rm_line] + [new_block] + lines[ret_line+1:]
with open(path, 'w', encoding='utf-8') as f:
    f.writelines(new_lines)

print("  [✓] 출석 API 수정 완료 (직접 속성 접근 방식)")
PYEOF

echo "[✓] Step 2: 출석 API 수정 완료"

# ── 3단계: sync_all 엔드포인트 교체 (더 안정적인 방식) ──
echo "[3] sync_all 업그레이드 (werkzeug → URL map 기반)..."
python3 - << 'PYEOF'
import sys, os, re

path = os.path.expanduser('~/AMS/backend/app.py')
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# sync_all 함수 전체 교체
# 기존 sync_all 찾기
start_pat = re.compile(r"@app\.route\('/api/sync/all'.*?\ndef sync_all\(\):", re.DOTALL)
m = start_pat.search(content)
if not m:
    print("  [스킵] sync_all 미발견")
    sys.exit(0)

# 함수 끝 찾기 (다음 @app.route 또는 # == 라인)
func_start = m.start()
next_marker = re.search(r'\n@app\.route|\n# [═=]{10}', content[m.end():])
if next_marker:
    func_end = m.end() + next_marker.start()
else:
    func_end = len(content)

old_func = content[func_start:func_end]
print(f"  sync_all 발견: {len(old_func)}자")

new_func = '''@app.route('/api/sync/all', methods=['POST'])
def sync_all():
    """다우오피스 직원 동기화 + SenseLink 근태 동기화 통합"""
    from datetime import datetime as _dt
    import json as _json
    results = {}

    # 1) 다우오피스 직원 동기화 - URL map에서 함수 동적 탐색
    try:
        dauoffice_func = None
        for rule in app.url_map.iter_rules():
            if ('sync' in rule.rule and 'employee' in rule.rule
                    and 'POST' in rule.methods and 'dauoffice' in rule.rule):
                dauoffice_func = app.view_functions.get(rule.endpoint)
                break
        if dauoffice_func:
            with app.test_request_context(method='POST',
                                          content_type='application/json'):
                from flask import g
                resp = dauoffice_func()
                try:
                    results['dauoffice'] = resp.get_json()
                except Exception:
                    results['dauoffice'] = {'status': 'called'}
        else:
            results['dauoffice'] = {'error': '다우오피스 sync 함수 미발견'}
    except Exception as ex:
        results['dauoffice'] = {'error': str(ex)}

    # 2) SenseLink 근태 동기화 - senselink_sync 직접 호출
    try:
        now = _dt.now()
        with app.test_request_context(
                '/api/senselink/sync', method='POST',
                data=_json.dumps({'year': now.year, 'month': now.month}),
                content_type='application/json'):
            resp2 = senselink_sync()
            try:
                results['senselink'] = resp2.get_json()
            except Exception:
                results['senselink'] = {'status': 'called'}
    except Exception as ex:
        results['senselink'] = {'error': str(ex)}

    return jsonify({'results': results, 'message': '통합 동기화 완료'})

'''

content = content[:func_start] + new_func + content[func_end:]
with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("  [✓] sync_all 안정화 완료")
PYEOF

echo "[✓] Step 3: sync_all 업그레이드 완료"

# ── 4단계: 배포 ──────────────────────────────────
echo "[4] 컨테이너 배포..."
docker cp "$BACKEND" attendance-backend:/app/app.py
docker restart attendance-backend
echo "[✓] 재시작 완료, 20초 대기..."
sleep 20

# ── 5단계: 검증 ──────────────────────────────────
echo ""
echo "=== 검증 ==="

# 출석 API 테스트
echo "  [출석 API]"
ATTEND=$(curl -s -w "\nHTTP_STATUS:%{http_code}" "http://localhost:5000/api/attendance?year=2026&month=2" 2>/dev/null)
HTTP_CODE=$(echo "$ATTEND" | grep "HTTP_STATUS:" | cut -d: -f2)
BODY=$(echo "$ATTEND" | grep -v "HTTP_STATUS:")

echo "  HTTP 상태: $HTTP_CODE"
echo "$BODY" | python3 - << 'PYEOF'
import sys, json
try:
    d = json.load(sys.stdin)
    items = d.get('data', d) if isinstance(d, dict) else d
    print(f"  총 직원: {len(items)}명")
    if items:
        f = items[0]
        ok = all(k in f for k in ['id','name','department','days'])
        print(f"  필드 검증: {'✅ id/name/department/days 모두 있음' if ok else '❌ ' + str(list(f.keys()))}")
        if f.get('name'):
            print(f"  샘플: {f['name']} / {f.get('department','')}")
        days = f.get('days', {})
        print(f"  days 타입: {type(days).__name__}, 레코드수: {len(days)}")
except json.JSONDecodeError as e:
    print(f"  ❌ JSON 오류: {e}")
    print(f"  응답 앞부분: {sys.stdin.read()[:200] if hasattr(sys.stdin,'read') else ''}")
except Exception as e:
    print(f"  ❌ 오류: {e}")
PYEOF

# SenseLink 상태
SL=$(curl -s "http://localhost:5000/api/senselink/status" 2>/dev/null)
echo "  [SenseLink] $SL"

# 통합동기화 엔드포인트 확인
SYNC=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:5000/api/sync/all" \
  -H "Content-Type: application/json" 2>/dev/null)
echo "  [통합동기화 /api/sync/all] HTTP $SYNC"

# ── 6단계: GitHub 푸시 ────────────────────────────
echo ""
echo "=== GitHub 푸시 ==="
cd "$APP_DIR"
git config user.email "thelab-bobkim@users.noreply.github.com"
git config user.name  "thelab-bobkim"
git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"

# 원격 최신 가져오기 후 rebase
echo "  원격 동기화 중..."
git fetch origin 2>/dev/null || true
git rebase origin/main 2>/dev/null || git merge --no-edit origin/main 2>/dev/null || true

git add -A
git diff --cached --quiet 2>/dev/null || \
  git commit -m "fix(v2): 출석API직렬화오류수정+sync_all안정화 [$(date '+%Y-%m-%d %H:%M')]"

git push -u origin main 2>&1 | tail -5

echo ""
echo "================================================"
echo "  ✅ v2 수정 완료!"
echo "  🌐 http://13.125.163.126  (Ctrl+Shift+R)"
echo "  📦 https://github.com/${GITHUB_REPO}"
echo "================================================"
