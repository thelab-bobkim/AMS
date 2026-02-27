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

SENSELINK_RELAY_URL = _os.environ.get('SENSELINK_RELAY_URL', 'http://175.198.93.89:8765')


def _parse_senselink_time(rec):
    """SenseLink 레코드에서 시각 추출 (passTime / signTime / time / eventTime)"""
    for field in ('passTime', 'signTime', 'time', 'eventTime', 'captureTime', 'recordTime'):
        val = rec.get(field)
        if not val:
            continue
        # Unix timestamp (int/float)
        if isinstance(val, (int, float)):
            try:
                from datetime import datetime as _dt
                return _dt.fromtimestamp(val).time()
            except Exception:
                continue
        # 문자열 datetime "YYYY-MM-DD HH:MM:SS" or "YYYY-MM-DDTHH:MM:SS"
        if isinstance(val, str) and len(val) >= 16:
            for fmt in ('%Y-%m-%d %H:%M:%S', '%Y-%m-%dT%H:%M:%S',
                        '%Y-%m-%d %H:%M',   '%Y-%m-%dT%H:%M'):
                try:
                    from datetime import datetime as _dt
                    return _dt.strptime(val[:19], fmt).time()
                except Exception:
                    continue
    return None


def _parse_senselink_date(rec):
    """SenseLink 레코드에서 날짜(date) 추출"""
    for field in ('passTime', 'signTime', 'time', 'eventTime', 'captureTime', 'recordTime'):
        val = rec.get(field)
        if not val:
            continue
        if isinstance(val, (int, float)):
            try:
                from datetime import datetime as _dt
                return _dt.fromtimestamp(val).date()
            except Exception:
                continue
        if isinstance(val, str) and len(val) >= 10:
            try:
                from datetime import datetime as _dt
                return _dt.strptime(val[:10], '%Y-%m-%d').date()
            except Exception:
                continue
    return None


@app.route('/api/senselink/sync', methods=['POST'])
def senselink_sync():
    """SenseLink /sl/api/v5/records 에서 출근 데이터 수집"""
    data   = request.json or {}
    year   = data.get('year',  datetime.now().year)
    month  = data.get('month', datetime.now().month)

    _, last_day = calendar.monthrange(year, month)
    dt_from = f"{year:04d}-{month:02d}-01 00:00:00"
    dt_to   = f"{year:04d}-{month:02d}-{last_day:02d} 23:59:59"

    all_records = []
    page = 1
    size = 100
    errors = []

    # 릴레이를 통해 SenseLink API 호출 (페이지네이션)
    while True:
        try:
            resp = _req.get(
                f"{SENSELINK_RELAY_URL}/sl/api/v5/records",
                params={
                    'dateTimeFrom': dt_from,
                    'dateTimeTo':   dt_to,
                    'order': 1,
                    'page':  page,
                    'size':  size
                },
                timeout=30
            )
            if resp.status_code != 200:
                errors.append(f"릴레이 HTTP {resp.status_code}")
                break
            body = resp.json()
            # code 확인
            code = str(body.get('code', ''))
            if code not in ('200', '0', ''):
                errors.append(f"SenseLink API 오류: {body.get('message', code)}")
                break
            # data.list 또는 data 직접
            d = body.get('data', body)
            if isinstance(d, list):
                recs = d
                total = len(d)
            else:
                recs  = d.get('list', d.get('records', d.get('data', [])))
                total = d.get('total', d.get('totalCount', len(recs)))

            if not recs:
                break
            all_records.extend(recs)
            if len(all_records) >= total or len(recs) < size:
                break
            page += 1

        except Exception as e:
            errors.append(f"릴레이 연결 오류: {str(e)}")
            break

    if errors and not all_records:
        return jsonify({
            'code': 200,
            'message': '릴레이 연결 실패 - 릴레이 서버를 확인하세요',
            'relay_url': SENSELINK_RELAY_URL,
            'errors': errors,
            'synced': 0
        })

    # DB 저장
    synced = 0
    save_errors = []
    for rec in all_records:
        try:
            user_name = (rec.get('userName') or rec.get('name') or '').strip()
            if not user_name:
                continue
            emp = Employee.query.filter_by(name=user_name, is_active=True).first()
            if not emp:
                continue
            work_date = _parse_senselink_date(rec)
            if not work_date:
                continue
            ci_time = _parse_senselink_time(rec)

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
        'message': f'{synced}건 동기화 완료 (SenseLink {len(all_records)}건 수신)',
        'synced':  synced,
        'fetched': len(all_records),
        'errors':  (errors + save_errors)[:5],
        'relay_url': SENSELINK_RELAY_URL,
        'period':  f"{dt_from[:10]} ~ {dt_to[:10]}"
    })


@app.route('/api/senselink/status', methods=['GET'])
def senselink_status():
    """SenseLink 연동 상태"""
    total = AttendanceRecord.query.filter_by(data_source='senselink').count()
    relay_ok = False
    try:
        r = _req.get(f"{SENSELINK_RELAY_URL}/sl/api/v5/records",
                     params={'page': 1, 'size': 1}, timeout=5)
        relay_ok = (r.status_code < 500)
    except Exception:
        relay_ok = False
    return jsonify({
        'code': 200,
        'relay_url': SENSELINK_RELAY_URL,
        'relay_reachable': relay_ok,
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
