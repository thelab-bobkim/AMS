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

# 다우오피스 API 클라이언트
dauoffice_client = None
if app.config['DAUOFFICE_API_KEY']:
    dauoffice_client = DauofficeAPIClient(
        app.config['DAUOFFICE_API_KEY'],
        app.config['DAUOFFICE_API_URL'],
        app.config['DAUOFFICE_SERVER_IP']
    )

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
    """출근 기록 조회 (월별)"""
    year = request.args.get('year', type=int)
    month = request.args.get('month', type=int)
    
    if not year or not month:
        return jsonify({'error': '년도와 월을 지정해주세요.'}), 400
    
    # 해당 월의 시작일과 종료일
    start_date = datetime(year, month, 1).date()
    _, last_day = calendar.monthrange(year, month)
    end_date = datetime(year, month, last_day).date()
    
    # 직원별 출근 기록 조회
    employees = Employee.query.filter_by(is_active=True).all()
    result = []
    
    for emp in employees:
        records = AttendanceRecord.query.filter(
            AttendanceRecord.employee_id == emp.id,
            AttendanceRecord.date >= start_date,
            AttendanceRecord.date <= end_date
        ).all()
        
        # 날짜별로 매핑
        record_dict = {rec.date.day: rec.to_dict() for rec in records}
        
        result.append({
            'employee': emp.to_dict(),
            'records': record_dict
        })
    
    return jsonify(result)

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
        # 해당 월의 시작일과 종료일
        start_date = datetime(year, month, 1).date()
        _, last_day = calendar.monthrange(year, month)
        end_date = datetime(year, month, last_day).date()
        
        # 다우오피스에서 데이터 가져오기
        records = dauoffice_client.get_attendance_records(
            start_date.strftime('%Y-%m-%d'),
            end_date.strftime('%Y-%m-%d')
        )
        
        synced_count = 0
        
        for record_data in records:
            # 다우오피스 사용자 ID로 직원 찾기
            dauoffice_user_id = record_data.get('user_id')
            employee = Employee.query.filter_by(dauoffice_user_id=dauoffice_user_id).first()
            
            if not employee:
                continue
            
            # 날짜 파싱
            date_obj = datetime.strptime(record_data['date'], '%Y-%m-%d').date()
            
            # 시간 파싱
            check_in_time = None
            if record_data.get('check_in_time'):
                check_in_time = datetime.strptime(record_data['check_in_time'], '%H:%M:%S').time()
            
            # 중복 체크
            existing = AttendanceRecord.query.filter_by(
                employee_id=employee.id,
                date=date_obj
            ).first()
            
            if existing:
                # 다우오피스 데이터로 업데이트 (data_source가 dauoffice인 경우만)
                if existing.data_source == 'dauoffice':
                    existing.check_in_time = check_in_time
                    existing.record_type = record_data.get('record_type', 'normal')
                    existing.note = record_data.get('note', '')
                    synced_count += 1
            else:
                # 새 레코드 생성
                record = AttendanceRecord(
                    employee_id=employee.id,
                    date=date_obj,
                    check_in_time=check_in_time,
                    record_type=record_data.get('record_type', 'normal'),
                    note=record_data.get('note', ''),
                    data_source='dauoffice'
                )
                db.session.add(record)
                synced_count += 1
        
        db.session.commit()
        
        return jsonify({
            'message': f'{synced_count}개의 출근 기록이 동기화되었습니다.',
            'count': synced_count
        })
    
    except Exception as e:
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
    employees = Employee.query.filter_by(is_active=True).all()
    
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
    filename = f"출근기록_{year}.{month:02d}.xlsx"
    
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


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
