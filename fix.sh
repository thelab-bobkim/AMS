#!/bin/bash
# ============================================================
# AMS 통합 수정 스크립트 v3.0
# 수정: 출석API flat구조 + SenseLink + 통합동기화 + GitHub 푸시
# ============================================================
set -e
APP_DIR="$HOME/AMS"
BACKEND="$APP_DIR/backend/app.py"
FRONTEND_DIR="$APP_DIR/frontend"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="thelab-bobkim/AMS"

echo "================================================"
echo " AMS 통합 수정 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "================================================"

# ── 백업 ──────────────────────────────────────────
cp "$BACKEND" "${BACKEND}.bak.$(date +%Y%m%d_%H%M%S)"
echo "[✓] 백업 완료"

# ── Step 1: 출석 API flat 구조 수정 ──────────────
python3 - << 'PYEOF'
import sys, os, re

path = os.path.expanduser('~/AMS/backend/app.py')
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# record_map = {} 라인 탐색
rm_line = None
for i, ln in enumerate(lines):
    if re.match(r'\s+record_map\s*=\s*\{\}', ln):
        rm_line = i
        break

if rm_line is None:
    print("  [이미수정됨] record_map 없음 — 스킵")
    sys.exit(0)

# return jsonify(result) 탐색
ret_line = None
for i in range(rm_line, min(rm_line + 20, len(lines))):
    if 'return jsonify(result)' in lines[i]:
        ret_line = i
        break

if ret_line is None:
    print("  [스킵] return jsonify(result) 미발견")
    sys.exit(0)

indent = len(lines[rm_line]) - len(lines[rm_line].lstrip())
p = ' ' * indent
p2 = p + '    '

new_block = (
    f"{p}record_map = {{}}\n"
    f"{p}for rec in attendance_records:\n"
    f"{p2}day_key = str(rec.date.day)\n"
    f"{p2}rd = rec.to_dict()\n"
    f"{p2}record_map.setdefault(rec.employee_id, {{}})[day_key] = {{\n"
    f"{p2}    'check_in': rd.get('check_in_time', rd.get('check_in', '')),\n"
    f"{p2}    'type': rd.get('record_type', 'normal'),\n"
    f"{p2}    'note': rd.get('note', ''),\n"
    f"{p2}    'source': rd.get('data_source', 'manual')\n"
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
print(f"  [✓] {rm_line+1}~{ret_line+1}줄 교체 완료")
PYEOF
echo "[✓] Step 1: 출석 API flat 구조 완료"

# ── Step 2: SenseLink + 통합동기화 엔드포인트 추가 ─
python3 - << 'PYEOF'
import sys, os, re

path = os.path.expanduser('~/AMS/backend/app.py')
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

if '/api/senselink/sync' in content:
    print("  [스킵] SenseLink 이미 존재")
    sys.exit(0)

new_code = '''
# ══════════════════════════════════════════════════
#  SenseLink 통합 엔드포인트
# ══════════════════════════════════════════════════
import os as _os
SENSELINK_RELAY_URL = _os.environ.get('SENSELINK_RELAY_URL', 'http://175.198.93.89:8765')


@app.route('/api/senselink/sync', methods=['POST'])
def senselink_sync():
    """SenseLink 얼굴인식 근태 데이터 동기화"""
    try:
        import requests as _rq
        from datetime import datetime as _dt
        body   = request.get_json() or {}
        year   = int(body.get('year',  _dt.now().year))
        month  = int(body.get('month', _dt.now().month))
        records = body.get('records', [])

        if not records:
            try:
                resp = _rq.get(f"{SENSELINK_RELAY_URL}/attendance",
                               params={'year': year, 'month': month}, timeout=10)
                if resp.status_code == 200:
                    raw = resp.json()
                    records = raw if isinstance(raw, list) else raw.get('records', [])
            except Exception as ex:
                return jsonify({'error': str(ex), 'count': 0}), 500

        count, errs = 0, []
        for rec in records:
            try:
                name      = (rec.get('name') or '').strip()
                date_str  = rec.get('date') or rec.get('work_date') or ''
                checkin_s = rec.get('check_in') or rec.get('checkin_time') or rec.get('time') or ''
                uid       = str(rec.get('user_id') or rec.get('loginId') or '')
                if not name or not date_str:
                    continue
                work_date = None
                for fmt in ('%Y-%m-%d', '%Y/%m/%d', '%Y%m%d'):
                    try:
                        work_date = _dt.strptime(date_str[:10], fmt).date(); break
                    except:
                        pass
                if not work_date:
                    continue
                cin = None
                for fmt in ('%H:%M:%S', '%H:%M', '%Y-%m-%d %H:%M:%S'):
                    try:
                        cin = _dt.strptime(checkin_s, fmt).time(); break
                    except:
                        pass
                emp = Employee.query.filter_by(name=name, is_active=True).first()
                if not emp and uid:
                    emp = Employee.query.filter_by(dauoffice_user_id=uid).first()
                if not emp:
                    emp = Employee(name=name, department=rec.get('department',''),
                                   data_source='senselink', is_active=True)
                    db.session.add(emp); db.session.flush()
                ex_rec = AttendanceRecord.query.filter_by(
                    employee_id=emp.id, date=work_date).first()
                if ex_rec:
                    if cin: ex_rec.check_in_time = cin
                    ex_rec.data_source = 'senselink'
                else:
                    db.session.add(AttendanceRecord(
                        employee_id=emp.id, date=work_date,
                        check_in_time=cin, record_type='normal',
                        data_source='senselink'))
                count += 1
            except Exception as ex:
                errs.append(str(ex))
        db.session.commit()
        return jsonify({'count': count, 'errors': errs[:5], 'year': year, 'month': month})
    except Exception as ex:
        return jsonify({'error': str(ex)}), 500


@app.route('/api/senselink/status', methods=['GET'])
def senselink_status():
    total = AttendanceRecord.query.filter_by(data_source='senselink').count()
    return jsonify({'status': 'ok', 'senselink_records': total})


@app.route('/api/senselink/preview', methods=['GET'])
def senselink_preview():
    try:
        import requests as _rq
        from datetime import datetime as _dt
        year  = request.args.get('year',  _dt.now().year)
        month = request.args.get('month', _dt.now().month)
        r = _rq.get(f"{SENSELINK_RELAY_URL}/attendance",
                    params={'year': year, 'month': month}, timeout=10)
        if r.status_code == 200:
            raw  = r.json()
            recs = raw if isinstance(raw, list) else raw.get('records', [])
            return jsonify({'count': len(recs), 'sample': recs[:5]})
    except Exception as ex:
        return jsonify({'error': str(ex)}), 500
    return jsonify({'count': 0})


# ══════════════════════════════════════════════════
#  통합 동기화 (DaouOffice + SenseLink)
# ══════════════════════════════════════════════════
@app.route('/api/sync/all', methods=['POST'])
def sync_all():
    """다우오피스 직원 동기화 + SenseLink 근태 동기화 한 번에"""
    from datetime import datetime as _dt
    from werkzeug.test import Client as WClient
    import json as _json
    results = {}
    cl = WClient(app)

    # 1) 다우오피스 직원
    try:
        r1 = cl.post('/api/dauoffice/sync-employees',
                     content_type='application/json')
        results['dauoffice'] = _json.loads(r1.data)
    except Exception as ex:
        results['dauoffice'] = {'error': str(ex)}

    # 2) SenseLink 근태
    try:
        now = _dt.now()
        pl  = _json.dumps({'year': now.year, 'month': now.month})
        r2  = cl.post('/api/senselink/sync',
                      data=pl, content_type='application/json')
        results['senselink'] = _json.loads(r2.data)
    except Exception as ex:
        results['senselink'] = {'error': str(ex)}

    return jsonify({'results': results, 'message': '통합 동기화 완료'})


# ══════════════════════════════════════════════════
#  라우트 별칭 (프론트엔드 호환)
# ══════════════════════════════════════════════════
@app.route('/api/daou/sync/employees', methods=['POST'])
def daou_alias_employees():
    from werkzeug.test import Client as WClient
    r = WClient(app).post('/api/dauoffice/sync-employees',
                          content_type='application/json')
    return app.response_class(r.data, status=r.status_code,
                              mimetype='application/json')

'''

marker = "if __name__ == '__main__':"
idx = content.rfind(marker)
if idx == -1:
    content += new_code
else:
    content = content[:idx] + new_code + content[idx:]

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("  [✓] SenseLink + 통합동기화 엔드포인트 추가 완료")
PYEOF
echo "[✓] Step 2: SenseLink 엔드포인트 완료"

# ── Step 3: 프론트엔드 수정 ───────────────────────
echo "  프론트엔드 수정 중..."

# app.js / index.html 에서 다우오피스 동기화 → 통합 동기화
find "$FRONTEND_DIR" \( -name "*.js" -o -name "*.html" \) | while IFS= read -r f; do
    # 버튼 텍스트
    sed -i 's/다우오피스 동기화/통합 동기화/g'    "$f" 2>/dev/null || true
    sed -i 's/DaouOffice Sync/통합 동기화/g'      "$f" 2>/dev/null || true
    # 동기화 API 엔드포인트를 /api/sync/all 로 교체
    sed -i "s|/api/dauoffice/sync-employees|/api/sync/all|g" "$f" 2>/dev/null || true
done

echo "[✓] Step 3: 프론트엔드 메뉴 '통합 동기화' 변경 완료"

# ── Step 4: .gitignore 생성 (DB/인스턴스 제외) ────
cat > "$APP_DIR/.gitignore" << 'EOF'
backend/instance/
*.db
*.sqlite3
*.sqlite
*.pyc
__pycache__/
.env
*.log
*.bak*
EOF
echo "[✓] Step 4: .gitignore 생성 완료"

# ── Step 5: 백엔드 컨테이너 배포 ─────────────────
docker cp "$BACKEND" attendance-backend:/app/app.py
docker restart attendance-backend
echo "[✓] Step 5: attendance-backend 재시작 완료"

echo "  15초 대기 중..."
sleep 15

# ── Step 6: 검증 ──────────────────────────────────
echo ""
echo "=== 검증 ==="
curl -s "http://localhost:5000/api/attendance?year=2026&month=2" | python3 - << 'PYEOF'
import sys, json
try:
    d = json.load(sys.stdin)
    items = d.get('data', d) if isinstance(d, dict) else d
    print(f"  총 직원: {len(items)}명")
    if items:
        f = items[0]
        print(f"  응답 필드: {list(f.keys())}")
        ok = all(k in f for k in ['id','name','department','days'])
        print(f"  구조 검증: {'✅ OK' if ok else '❌ FAIL'}")
        if f.get('name'):
            print(f"  샘플: {f['name']} / {f['department']}")
except Exception as e:
    print(f"  검증 오류: {e}")
PYEOF

# SenseLink 엔드포인트 확인
SL_STATUS=$(curl -s "http://localhost:5000/api/senselink/status" 2>/dev/null || echo "{}")
echo "  SenseLink 상태: $SL_STATUS"

# ── Step 7: GitHub 푸시 ───────────────────────────
echo ""
echo "=== GitHub 푸시 ==="
cd "$APP_DIR"
git config user.email "thelab-bobkim@users.noreply.github.com"
git config user.name  "thelab-bobkim"

if [ ! -d ".git" ]; then
    echo "  Git 초기화 중..."
    git init
    git remote add origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
fi

git remote set-url origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"

git add -A
COMMIT_MSG="fix: 출석API flat구조+SenseLink통합+통합동기화메뉴 [$(date '+%Y-%m-%d %H:%M')]"
git commit -m "$COMMIT_MSG" 2>/dev/null || echo "  (변경사항 없음 또는 이미 커밋됨)"

# main → master 순서로 push 시도
git push -u origin main 2>/dev/null \
  || git push -u origin master 2>/dev/null \
  || git push -u origin HEAD:main 2>/dev/null \
  || echo "  ⚠ push 실패 — 로컬 수정은 적용됨"

echo ""
echo "================================================"
echo "  ✅ 모든 작업 완료!"
echo "  🌐 http://13.125.163.126"
echo "  🔄 브라우저: Ctrl+Shift+R 로 새로고침"
echo "  📦 GitHub: https://github.com/${GITHUB_REPO}"
echo "================================================"
