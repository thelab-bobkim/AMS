from flask import Flask, jsonify, request, send_file
from flask_cors import CORS
from datetime import datetime, timedelta
from models import db, Employee, AttendanceRecord
from config import Config
from dauoffice_api import DauofficeAPIClient
import io
from openpyxl import Workbook
from openpyxl.styles import Font, Alignment, PatternFill, Border, Side
import calendar

app = Flask(__name__)
app.config.from_object(Config)

# CORS 설정
CORS(app)

# 데이터베이스 초기화
db.init_app(app)

# 다우오피스 API 클라이언트 (OAuth2 Client Credentials)
dauoffice_client = None
client_id = Config.get_client_id()
client_secret = Config.get_client_secret()
if client_id:
    dauoffice_client = DauofficeAPIClient(
        client_id=client_id,
        client_secret=client_secret,
        api_url=app.config.get('DAUOFFICE_API_URL', 'https://api.daouoffice.com')
    )
    print(f"[App] DauofficeAPIClient 초기화 완료 (client_id: {client_id[:8]}...)")
else:
    print("[App] 다우오피스 API 키가 설정되지 않았습니다.")

with app.app_context():
    db.create_all()





# ==================== SenseLink 안면인식 연동 ====================

import os as _os
import requests as _req
import calendar as _cal
from collections import defaultdict as _defaultdict

SENSELINK_RELAY_URL = _os.environ.get('SENSELINK_RELAY_URL', 'http://175.198.93.89:8765')


@app.route('/api/senselink/sync', methods=['POST'])
def senselink_sync():
    """SenseLink relay /attendance 에서 출근 데이터 수집
    
    relay 응답 필드:
      user_name      : 직원명
      sign_time_str  : "YYYY-MM-DD HH:MM:SS"
      type           : "1"=직원, "3"=기타
      device_direction: "0"=입장, "1"=퇴장
    로직: type="1" + 하루 중 최초 sign_time_str = 출근시각
    """
    data  = request.json or {}
    year  = data.get('year',  datetime.now().year)
    month = data.get('month', datetime.now().month)

    date_prefix  = f"{year:04d}-{month:02d}-"
    cutoff_start = f"{year:04d}-{month:02d}-01"
    _, last_d    = calendar.monthrange(year, month)
    cutoff_end   = f"{year:04d}-{month:02d}-{last_d:02d} 23:59:59"

    HEADERS = {
        'ngrok-skip-browser-warning': 'true',
        'User-Agent': 'AMS-Server/1.0'
    }

    all_recs = []
    page = 1
    size = 100
    errors = []
    pages_fetched = 0
    MAX_PAGES = 200  # 최대 200페이지 (2만 건) 방어

    while pages_fetched < MAX_PAGES:
        try:
            resp = _req.get(
                f"{SENSELINK_RELAY_URL}/attendance",
                params={
                    'page': page, 'size': size,
                    'year': year, 'month': month,
                    'start': cutoff_start[:10],
                    'end':   cutoff_end[:10]
                },
                headers=HEADERS,
                timeout=30
            )
            if resp.status_code != 200:
                errors.append(f"relay HTTP {resp.status_code}")
                break

            body = resp.json()
            raw  = body.get('data', body)
            recs = raw if isinstance(raw, list) else []
            total = body.get('total', 0)

            pages_fetched += 1

            if not recs:
                break

            # 해당 월 레코드만 수집
            for r in recs:
                st = r.get('sign_time_str', '')
                if st.startswith(date_prefix):
                    all_recs.append(r)

            # 마지막 레코드 시각이 목표 월보다 이전이면 중단 (내림차순 정렬 가정)
            oldest_sign = min((r.get('sign_time_str','') for r in recs), default='')
            if oldest_sign and oldest_sign < cutoff_start:
                break

            if page * size >= total:
                break
            page += 1

        except Exception as e:
            errors.append(str(e))
            break

    # ── 하루 최초 입장 기록 선택 ──────────────────
    # key: (user_name, date_str "YYYY-MM-DD")
    # type="1" 직원만, device_direction="0" 입장 우선
    best: dict = {}   # key → 최조 sign_time_str 레코드

    for rec in all_recs:
        uname = (rec.get('user_name') or '').strip()
        stime = rec.get('sign_time_str', '')
        rtype = str(rec.get('type', ''))

        if not uname or not stime or rtype != '1':
            continue
        if not stime.startswith(date_prefix):
            continue

        dkey = stime[:10]
        key  = (uname, dkey)

        direction = str(rec.get('device_direction', '0'))
        cur_best  = best.get(key)

        if cur_best is None:
            best[key] = rec
        else:
            # 입장(0) 레코드 우선 선택, 같은 direction이면 더 이른 시각
            cur_dir = str(cur_best.get('device_direction', '0'))
            if direction == '0' and cur_dir != '0':
                best[key] = rec
            elif direction == cur_dir and stime < cur_best.get('sign_time_str', ''):
                best[key] = rec

    # ── DB 저장 ───────────────────────────────────
    synced, save_errors = 0, []
    for (uname, dkey), rec in best.items():
        try:
            emp = Employee.query.filter_by(name=uname, is_active=True).first()
            if not emp:
                continue
            work_date = datetime.strptime(dkey, '%Y-%m-%d').date()
            stime     = rec.get('sign_time_str', '')
            ci_time   = None
            if len(stime) >= 19:
                ci_time = datetime.strptime(stime[:19], '%Y-%m-%d %H:%M:%S').time()

            existing = AttendanceRecord.query.filter_by(
                employee_id=emp.id, date=work_date).first()
            if existing:
                if ci_time:
                    existing.check_in_time = ci_time
                existing.data_source = 'senselink'
            else:
                db.session.add(AttendanceRecord(
                    employee_id=emp.id,
                    date=work_date,
                    check_in_time=ci_time,
                    record_type='normal',
                    data_source='senselink'
                ))
            synced += 1
        except Exception as e:
            save_errors.append(str(e))

    db.session.commit()

    return jsonify({
        'code':    200,
        'message': f'{synced}건 동기화 완료',
        'synced':  synced,
        'fetched': len(all_recs),
        'pages':   pages_fetched,
        'total_relay': body.get('total', 0) if 'body' in dir() else 0,
        'relay_url': SENSELINK_RELAY_URL,
        'period':  f"{date_prefix}01 ~ {date_prefix}{last_d:02d}",
        'errors':  (errors + save_errors)[:5]
    })


@app.route('/api/senselink/status', methods=['GET'])
def senselink_status():
    """SenseLink 연동 상태 + relay 연결 확인"""
    total = AttendanceRecord.query.filter_by(data_source='senselink').count()
    relay_ok = False
    relay_msg = ''
    try:
        r = _req.get(
            f"{SENSELINK_RELAY_URL}/attendance",
            params={'page': 1, 'size': 1},
            headers={'ngrok-skip-browser-warning': 'true'},
            timeout=5
        )
        relay_ok  = (r.status_code == 200)
        relay_msg = f"HTTP {r.status_code}"
        if relay_ok:
            d = r.json()
            relay_msg += f", total={d.get('total', '?')}"
    except Exception as e:
        relay_msg = str(e)[:80]

    return jsonify({
        'code': 200,
        'relay_url':      SENSELINK_RELAY_URL,
        'relay_reachable': relay_ok,
        'relay_status':   relay_msg,
        'total_senselink_records': total
    })


@app.route('/api/senselink/preview', methods=['GET'])
def senselink_preview():
    """SenseLink 최근 데이터 미리보기"""
    year  = request.args.get('year',  datetime.now().year,  type=int)
    month = request.args.get('month', datetime.now().month, type=int)
    recs  = AttendanceRecord.query.filter(
        AttendanceRecord.data_source == 'senselink',
        db.extract('year',  AttendanceRecord.date) == year,
        db.extract('month', AttendanceRecord.date) == month
    ).limit(20).all()
    return jsonify({'code': 200, 'count': len(recs),
                    'records': [r.to_dict() for r in recs]})



# ==================== 다우오피스 라우트 별칭 (프론트엔드 /api/daou/ 호환) ====================

@app.route('/api/daou/sync/employees', methods=['POST'])

def daou_sync_employees_alias():

    return sync_employees()



@app.route('/api/daou/sync/attendance', methods=['POST'])

def daou_sync_attendance_alias():

    return sync_attendance()


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
