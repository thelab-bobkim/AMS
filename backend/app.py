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


# ==================== 직원 관리 API ====================

@app.route('/api/employees', methods=['GET'])
def get_employees():
    """전체 직원 목록 조회"""
    employees = Employee.query.filter_by(is_active=True).all()
    return jsonify([emp.to_dict() for emp in employees])

@app.route('/api/employees', methods=['POST'])
def create_employee():
    """직원 추가 (수동 입력용)"""
    data = request.json
    
    employee = Employee(
        name=data['name'],
        department=data.get('department', ''),
        data_source='manual'
    )
    
    db.session.add(employee)
    db.session.commit()
    
    return jsonify(employee.to_dict()), 201

@app.route('/api/employees/<int:employee_id>', methods=['PUT'])
def update_employee(employee_id):
    """직원 정보 수정"""
    employee = Employee.query.get_or_404(employee_id)
    data = request.json
    
    employee.name = data.get('name', employee.name)
    employee.department = data.get('department', employee.department)
    
    db.session.commit()
    
    return jsonify(employee.to_dict())

@app.route('/api/employees/<int:employee_id>', methods=['DELETE'])
def delete_employee(employee_id):
    """직원 삭제 (소프트 삭제)"""
    employee = Employee.query.get_or_404(employee_id)
    employee.is_active = False
    
    db.session.commit()
    
    return jsonify({'message': '직원이 삭제되었습니다.'})


# ==================== 출근 기록 API ====================

@app.route('/api/attendance', methods=['GET'])
def get_attendance_records():
    """출근 기록 조회 (월별) - 부서 필터 지원, N+1 쿼리 개선"""
    year = request.args.get('year', type=int)
    month = request.args.get('month', type=int)
    department = request.args.get('department', '')

    if not year or not month:
        return jsonify({'error': '년도와 월을 지정해주세요.'}), 400

    start_date = datetime(year, month, 1).date()
    _, last_day = calendar.monthrange(year, month)
    end_date = datetime(year, month, last_day).date()

    # 1) 직원 목록 (부서 필터 + 정렬)
    emp_query = Employee.query.filter_by(is_active=True)
    if department:
        emp_query = emp_query.filter_by(department=department)
    employees = emp_query.order_by(Employee.department, Employee.name).all()

    if not employees:
        return jsonify([])

    # 2) 해당 월 전체 출근기록 한 번에 조회 (N+1 방지)
    emp_ids = [e.id for e in employees]
    all_records = AttendanceRecord.query.filter(
        AttendanceRecord.employee_id.in_(emp_ids),
        AttendanceRecord.date >= start_date,
        AttendanceRecord.date <= end_date
    ).all()

    # 3) {employee_id: {day: record_dict}} 맵핑
    record_map = {}
    for rec in attendance_records:
        day_key = str(rec.date.day)
        rd = rec.to_dict()
        record_map.setdefault(rec.employee_id, {})[day_key] = {
            'check_in': rd.get('check_in_time', rd.get('check_in', '')),
            'type': rd.get('record_type', 'normal'),
            'note': rd.get('note', ''),
            'source': rd.get('data_source', 'manual')
        }
    result = []
    for emp in employees:
        result.append({
            'id': emp.id,
            'name': emp.name,
            'department': emp.department or '',
            'days': record_map.get(emp.id, {})
        })
    return jsonify({'code': 200, 'data': result, 'year': year, 'month': month})

@app.route('/api/attendance', methods=['POST'])
def create_attendance_record():
    """출근 기록 추가 (수동 입력)"""
    data = request.json
    
    employee_id = data['employee_id']
    date_str = data['date']  # YYYY-MM-DD
    check_in_time_str = data.get('check_in_time')  # HH:MM:SS
    record_type = data.get('record_type', 'normal')
    note = data.get('note', '')
    
    # 날짜 파싱
    date_obj = datetime.strptime(date_str, '%Y-%m-%d').date()
    
    # 시간 파싱
    check_in_time = None
    if check_in_time_str:
        check_in_time = datetime.strptime(check_in_time_str, '%H:%M:%S').time()
    
    # 중복 체크
    existing = AttendanceRecord.query.filter_by(
        employee_id=employee_id,
        date=date_obj
    ).first()
    
    if existing:
        # 업데이트
        existing.check_in_time = check_in_time
        existing.record_type = record_type
        existing.note = note
        existing.data_source = 'manual'
        db.session.commit()
        return jsonify(existing.to_dict())
    else:
        # 새 레코드 생성
        record = AttendanceRecord(
            employee_id=employee_id,
            date=date_obj,
            check_in_time=check_in_time,
            record_type=record_type,
            note=note,
            data_source='manual'
        )
        db.session.add(record)
        db.session.commit()
        return jsonify(record.to_dict()), 201

@app.route('/api/attendance/<int:record_id>', methods=['PUT'])
def update_attendance_record(record_id):
    """출근 기록 수정"""
    record = AttendanceRecord.query.get_or_404(record_id)
    data = request.json
    
    if 'check_in_time' in data and data['check_in_time']:
        record.check_in_time = datetime.strptime(data['check_in_time'], '%H:%M:%S').time()
    
    if 'record_type' in data:
        record.record_type = data['record_type']
    
    if 'note' in data:
        record.note = data['note']
    
    db.session.commit()
    
    return jsonify(record.to_dict())

@app.route('/api/attendance/<int:record_id>', methods=['DELETE'])
def delete_attendance_record(record_id):
    """출근 기록 삭제"""
    record = AttendanceRecord.query.get_or_404(record_id)
    db.session.delete(record)
    db.session.commit()
    
    return jsonify({'message': '출근 기록이 삭제되었습니다.'})


# ==================== 다우오피스 연동 API ====================

@app.route('/api/dauoffice/sync-employees', methods=['POST'])
def sync_employees():
    """다우오피스에서 직원 정보 동기화"""
    if not dauoffice_client:
        return jsonify({'error': '다우오피스 API가 설정되지 않았습니다.'}), 400
    
    try:
        count = dauoffice_client.sync_employees_from_dauoffice()
        return jsonify({
            'message': f'{count}명의 직원 정보가 동기화되었습니다.',
            'count': count
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/dauoffice/sync-attendance', methods=['POST'])
def sync_attendance():
    """다우오피스에서 출근 기록 가져오기"""
    if not dauoffice_client:
        return jsonify({'error': '다우오피스 API가 설정되지 않았습니다.'}), 400
    
    data = request.json
    year = data.get('year')
    month = data.get('month')
    
    if not year or not month:
        return jsonify({'error': '년도와 월을 지정해주세요.'}), 400
    
    try:
        # dauoffice_api.py에 구현된 sync_attendance_from_dauoffice 메서드 사용
        count = dauoffice_client.sync_attendance_from_dauoffice(year, month)
        
        return jsonify({
            'message': f'{count}개의 출근 기록이 동기화되었습니다.',
            'count': count
        })
    
    except Exception as e:
        print(f"근태 동기화 오류: {str(e)}")
        return jsonify({'error': str(e)}), 500


# ==================== 엑셀 내보내기 API ====================

@app.route('/api/export/excel', methods=['GET'])
def export_excel():
    """엑셀 파일 내보내기 (기존 형식)"""
    year = request.args.get('year', type=int)
    month = request.args.get('month', type=int)
    
    if not year or not month:
        return jsonify({'error': '년도와 월을 지정해주세요.'}), 400
    
    # 워크북 생성
    wb = Workbook()
    ws = wb.active
    ws.title = "SUM"
    
    # 스타일 정의
    header_font = Font(bold=True)
    center_alignment = Alignment(horizontal='center', vertical='center')
    
    # 헤더 작성
    headers = ['성 명 ', '부 서 / 팀']
    
    # 해당 월의 일수
    _, last_day = calendar.monthrange(year, month)
    
    # 날짜 헤더 추가
    for day in range(1, last_day + 1):
        date_obj = datetime(year, month, day)
        weekday = ['월', '화', '수', '목', '금', '토', '일'][date_obj.weekday()]
        headers.append(f"{month}-{day:02d}({weekday})")
    
    ws.append(headers)
    
    # 헤더 스타일 적용
    for cell in ws[1]:
        cell.font = header_font
        cell.alignment = center_alignment
    
    # 직원별 데이터 작성
    department_filter = request.args.get('department', '')
    query = Employee.query.filter_by(is_active=True)
    if department_filter:
        query = query.filter_by(department=department_filter)
    employees = query.order_by(Employee.department, Employee.name).all()
    
    # 엑셀 파일명에 부서 반영
    filename = f"출근기록_{year}.{month:02d}_{department_filter or '전체'}.xlsx"
    
    for emp in employees:
        row_data = [emp.name, emp.department or '']
        
        # 해당 월의 출근 기록 조회
        for day in range(1, last_day + 1):
            date_obj = datetime(year, month, day).date()
            
            record = AttendanceRecord.query.filter_by(
                employee_id=emp.id,
                date=date_obj
            ).first()
            
            cell_value = ''
            
            if record:
                if record.record_type == 'annual_leave':
                    cell_value = '연 차'
                elif record.record_type == 'half_leave':
                    cell_value = '반 차'
                elif record.record_type == 'substitute_holiday':
                    cell_value = '대체휴무'
                elif record.record_type == 'business_trip':
                    cell_value = f"출장-{record.note}" if record.note else '출 장'
                elif record.check_in_time:
                    cell_value = record.check_in_time.strftime('%H:%M:%S')
                    if record.note:
                        cell_value = f"{cell_value} / {record.note}"
            
            row_data.append(cell_value)
        
        ws.append(row_data)
    
    # 파일을 메모리에 저장
    output = io.BytesIO()
    wb.save(output)
    output.seek(0)
    
    # 파일명
    # filename = f"출근기록_{year}.{month:02d}.xlsx"  # 위에서 이미 설정됨
    
    return send_file(
        output,
        mimetype='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        as_attachment=True,
        download_name=filename
    )


# ==================== 헬스 체크 ====================

@app.route('/api/health', methods=['GET'])
def health_check():
    """서버 상태 확인"""
    return jsonify({
        'status': 'ok',
        'dauoffice_api_configured': dauoffice_client is not None
    })





# ==================== SenseLink 안면인식 연동 ====================

import os as _os

import requests as _req



SENSELINK_RELAY_URL = _os.environ.get('SENSELINK_RELAY_URL', 'http://175.198.93.89:8765')



@app.route('/api/senselink/sync', methods=['POST'])

def senselink_sync():

    """SenseLink 안면인식 데이터 동기화 (push/pull 겸용)"""

    data = request.json or {}

    year  = data.get('year',  datetime.now().year)

    month = data.get('month', datetime.now().month)

    records = data.get('records', [])



    # records가 없으면 relay_server에서 pull 시도

    if not records:

        try:

            r = _req.post(f"{SENSELINK_RELAY_URL}/sync",

                          json={"year": year, "month": month}, timeout=30)

            if r.status_code == 200:

                records = r.json().get('records', [])

        except Exception as e:

            return jsonify({'code': 200, 'message': f'릴레이 연결 실패: {e}',

                            'synced': 0, 'year': year, 'month': month})



    synced, errors = 0, []

    for rec in records:

        try:

            emp_name = rec.get('name') or rec.get('employee_name', '')

            emp = Employee.query.filter_by(name=emp_name, is_active=True).first()

            if not emp:

                continue

            date_str = rec.get('date') or rec.get('work_date', '')

            if not date_str:

                continue

            work_date = datetime.strptime(date_str[:10], '%Y-%m-%d').date()

            ci_str = rec.get('check_in') or rec.get('check_in_time', '') or ''

            ci_time = None

            if ci_str:

                ci = ci_str.strip()

                try:    ci_time = datetime.strptime(ci[:8], '%H:%M:%S').time()

                except:

                    try: ci_time = datetime.strptime(ci[:5], '%H:%M').time()

                    except: pass

            rtype = rec.get('type') or rec.get('record_type', 'normal')

            note  = rec.get('note', '')

            existing = AttendanceRecord.query.filter_by(

                employee_id=emp.id, date=work_date).first()

            if existing:

                existing.check_in_time = ci_time

                existing.record_type   = rtype

                existing.note          = note

                existing.data_source   = 'senselink'

            else:

                db.session.add(AttendanceRecord(

                    employee_id=emp.id, date=work_date,

                    check_in_time=ci_time, record_type=rtype,

                    note=note, data_source='senselink'))

            synced += 1

        except Exception as e:

            errors.append(str(e))

    db.session.commit()

    return jsonify({'code': 200, 'message': f'{synced}건 동기화 완료',

                    'synced': synced, 'errors': errors[:5],

                    'year': year, 'month': month})





@app.route('/api/senselink/status', methods=['GET'])

def senselink_status():

    """SenseLink 연동 상태"""

    total = AttendanceRecord.query.filter_by(data_source='senselink').count()

    return jsonify({'code': 200, 'relay_url': SENSELINK_RELAY_URL,

                    'total_senselink_records': total})





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
