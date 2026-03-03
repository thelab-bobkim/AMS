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
    for rec in all_records:
        day_key = str(rec.date.day)
        try:
            cin = rec.check_in_time.strftime('%H:%M') if rec.check_in_time else ''
        except Exception:
            cin = str(rec.check_in_time)[:5] if rec.check_in_time else ''
        record_map.setdefault(rec.employee_id, {})[day_key] = {
            'check_in': cin,
            'type':     (rec.record_type  or 'normal'),
            'note':     (rec.note         or ''),
            'source':   (rec.data_source  or 'manual'),
            'id':        rec.id
        }
    result = []
    for emp in employees:
        result.append({
            'id':         emp.id,
            'name':       (emp.name       or ''),
            'department': (emp.department or ''),
            'days':       record_map.get(emp.id, {})
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
        # 업데이트 (check_in_time이 명시적으로 전달된 경우만 덮어씀)
        if 'check_in_time' in (request.json or {}):
            existing.check_in_time = check_in_time
        # record_type이 비출근 유형이면 check_in_time 보존
        if record_type not in ('normal', 'remote_work'):
            pass  # check_in_time 유지
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



# ==================== 엑셀 내보내기 API (개선 버전) ====================

@app.route('/api/export/excel', methods=['GET'])
def export_excel():
    """엑셀 파일 내보내기 (디자인 개선 버전)"""
    from openpyxl import Workbook
    from openpyxl.styles import (Font, Alignment, PatternFill, Border, Side,
                                  GradientFill)
    from openpyxl.utils import get_column_letter
    from openpyxl.styles.differential import DifferentialStyle
    from openpyxl.formatting.rule import ColorScaleRule, CellIsRule, FormulaRule
    import calendar
    from datetime import datetime
    import io

    year = request.args.get('year', type=int)
    month = request.args.get('month', type=int)

    if not year or not month:
        return jsonify({'error': '년도와 월을 지정해주세요.'}), 400

    department_filter = request.args.get('department', '')
    _, last_day = calendar.monthrange(year, month)

    # ── 직원 조회 ──────────────────────────────────────────────────
    query = Employee.query.filter_by(is_active=True)
    if department_filter:
        query = query.filter_by(department=department_filter)
    employees = query.order_by(Employee.department, Employee.name).all()

    # ── 출근 기록 일괄 조회 (N+1 방지) ────────────────────────────
    from datetime import date as date_type
    start_date = date_type(year, month, 1)
    end_date   = date_type(year, month, last_day)
    emp_ids    = [e.id for e in employees]
    all_records = AttendanceRecord.query.filter(
        AttendanceRecord.employee_id.in_(emp_ids),
        AttendanceRecord.date >= start_date,
        AttendanceRecord.date <= end_date
    ).all()
    record_map = {}
    for rec in all_records:
        record_map.setdefault(rec.employee_id, {})[rec.date.day] = rec

    # ── 워크북 생성 ────────────────────────────────────────────────
    wb = Workbook()
    ws = wb.active
    ws.title = f"{year}.{month:02d} 근태"

    # ── 색상 팔레트 ────────────────────────────────────────────────
    C_TITLE_BG   = "1F4E79"   # 진한 네이비 (제목행)
    C_TITLE_FG   = "FFFFFF"
    C_SAT_BG     = "D6E4F7"   # 연한 파랑 (토요일)
    C_SUN_BG     = "FDECEA"   # 연한 빨강 (일요일)
    C_WEEK_BG    = "EBF3FB"   # 매우 연한 파랑 (평일 날짜행)
    C_SUBHDR_BG  = "2E75B6"   # 중간 파랑 (성명/부서 헤더)
    C_DEPT_BG    = "D9E1F2"   # 연보라 (부서 그룹행)
    C_LEAVE_BG   = "FFF2CC"   # 연노랑 (연차/반차)
    C_TRIP_BG    = "E2EFDA"   # 연초록 (출장)
    C_TIME_FG    = "1F4E79"   # 출근시각 글자색
    C_LATE_BG    = "FCE4D6"   # 연주황 (지각: 09:30 이후)
    C_ODD_BG     = "F8FBFF"   # 홀수행 배경
    C_EVEN_BG    = "FFFFFF"   # 짝수행 배경
    C_BORDER     = "B8CCE4"   # 테두리

    def fill(hex_color):
        return PatternFill("solid", fgColor=hex_color)

    def font(bold=False, color="000000", size=10, name="Malgun Gothic"):
        return Font(bold=bold, color=color, size=size, name=name)

    def center(wrap=False):
        return Alignment(horizontal='center', vertical='center',
                         wrap_text=wrap)

    def border(color=C_BORDER, style='thin'):
        s = Side(style=style, color=color)
        return Border(left=s, right=s, top=s, bottom=s)

    def med_border(color=C_BORDER):
        thin = Side(style='thin',   color=color)
        med  = Side(style='medium', color="4472C4")
        return Border(left=thin, right=thin, top=thin, bottom=thin)

    # ── 행1: 대제목 ────────────────────────────────────────────────
    total_cols = 2 + last_day
    ws.merge_cells(start_row=1, start_column=1,
                   end_row=1,   end_column=total_cols)
    title_cell = ws.cell(1, 1,
        value=f"{'[' + department_filter + '] ' if department_filter else ''}"
              f"{year}년 {month}월 출근 현황")
    title_cell.font      = Font(bold=True, color=C_TITLE_FG, size=14,
                                name="Malgun Gothic")
    title_cell.fill      = fill(C_TITLE_BG)
    title_cell.alignment = center()
    ws.row_dimensions[1].height = 32

    # ── 행2: 날짜 헤더 ─────────────────────────────────────────────
    ws.cell(2, 1, "성  명").font      = font(True, C_TITLE_FG, 10)
    ws.cell(2, 1).fill                = fill(C_SUBHDR_BG)
    ws.cell(2, 1).alignment           = center()
    ws.cell(2, 1).border              = border("4472C4", "medium")

    ws.cell(2, 2, "부서 / 팀").font   = font(True, C_TITLE_FG, 10)
    ws.cell(2, 2).fill                = fill(C_SUBHDR_BG)
    ws.cell(2, 2).alignment           = center()
    ws.cell(2, 2).border              = border("4472C4", "medium")

    for day in range(1, last_day + 1):
        d   = datetime(year, month, day)
        wd  = d.weekday()               # 0=월 … 6=일
        col = day + 2
        wday_str = ['월','화','수','목','금','토','일'][wd]
        c = ws.cell(2, col, f"{day}\n({wday_str})")
        c.alignment = center(wrap=True)
        c.border    = border()
        c.font      = font(True, size=9)
        if wd == 5:                     # 토
            c.fill = fill(C_SAT_BG)
            c.font = font(True, "2E75B6", 9)
        elif wd == 6:                   # 일
            c.fill = fill(C_SUN_BG)
            c.font = font(True, "C00000", 9)
        else:
            c.fill = fill(C_WEEK_BG)
    ws.row_dimensions[2].height = 30

    # ── 열 너비 설정 ───────────────────────────────────────────────
    ws.column_dimensions['A'].width = 12   # 성명
    ws.column_dimensions['B'].width = 16   # 부서
    for day in range(1, last_day + 1):
        ws.column_dimensions[get_column_letter(day + 2)].width = 9.5

    # ── 데이터 행 ──────────────────────────────────────────────────
    prev_dept = None
    data_row  = 3

    for idx, emp in enumerate(employees):
        dept = emp.department or '미지정'
        wd   = data_row

        # 부서가 바뀌면 그룹 구분행 삽입
        if dept != prev_dept:
            if prev_dept is not None:
                ws.row_dimensions[wd].height = 6
                for c in range(1, total_cols + 1):
                    ws.cell(wd, c).fill = fill("DAEEF3")
                data_row += 1
                wd = data_row
            prev_dept = dept

        row_bg = C_ODD_BG if idx % 2 == 0 else C_EVEN_BG

        # 성명
        nc = ws.cell(wd, 1, emp.name)
        nc.font      = font(True, size=10)
        nc.alignment = center()
        nc.fill      = fill(row_bg)
        nc.border    = border()

        # 부서
        dc = ws.cell(wd, 2, dept)
        dc.font      = font(size=9, color="404040")
        dc.alignment = center()
        dc.fill      = fill(row_bg)
        dc.border    = border()

        # 날짜별 출근기록
        for day in range(1, last_day + 1):
            col = day + 2
            d   = datetime(year, month, day)
            wd2 = d.weekday()
            rec = record_map.get(emp.id, {}).get(day)

            cell_val  = ''
            cell_fill = row_bg
            cell_font = font(size=9)
            cell_bold = False

            if wd2 == 5:   cell_fill = C_SAT_BG
            elif wd2 == 6: cell_fill = C_SUN_BG

            if rec:
                rt = rec.record_type or 'normal'
                if rt == 'annual_leave':
                    cell_val  = '연 차'
                    cell_fill = C_LEAVE_BG
                    cell_bold = True
                elif rt == 'half_leave':
                    cell_val  = '반 차'
                    cell_fill = C_LEAVE_BG
                elif rt == 'substitute_holiday':
                    cell_val  = '대체휴무'
                    cell_fill = "E2EFDA"
                elif rt == 'business_trip':
                    cell_val  = f"출장\n{rec.note}" if rec.note else '출 장'
                    cell_fill = C_TRIP_BG
                elif rec.check_in_time:
                    try:
                        ci = rec.check_in_time
                        hh = ci.hour if hasattr(ci,'hour') else int(str(ci)[:2])
                        mm = ci.minute if hasattr(ci,'minute') else int(str(ci)[3:5])
                        cell_val = f"{hh:02d}:{mm:02d}"
                        # 지각 체크 (09:30 초과)
                        if (hh, mm) > (9, 30):
                            cell_fill = C_LATE_BG
                            cell_bold = True
                        else:
                            cell_fill = row_bg
                    except Exception:
                        cell_val = str(rec.check_in_time)[:5]
            elif wd2 < 5:
                cell_val = ''   # 평일 미출근은 빈칸

            c = ws.cell(wd, col, cell_val)
            c.font      = Font(bold=cell_bold, color=C_TIME_FG if cell_val and ':' in cell_val else "000000",
                               size=9, name="Malgun Gothic")
            c.fill      = fill(cell_fill)
            c.alignment = center(wrap=True)
            c.border    = border()

        ws.row_dimensions[wd].height = 18
        data_row += 1

    # ── 마지막 구분선 ──────────────────────────────────────────────
    for c in range(1, total_cols + 1):
        cell = ws.cell(data_row, c)
        cell.border = Border(
            top=Side(style='medium', color="4472C4")
        )

    # ── 창 고정 (성명+부서, 날짜행 고정) ──────────────────────────
    ws.freeze_panes = ws.cell(3, 3)

    # ── 인쇄 설정 ─────────────────────────────────────────────────
    from openpyxl.worksheet.page import PageMargins
    ws.page_setup.orientation = ws.ORIENTATION_LANDSCAPE
    ws.page_setup.fitToPage   = True
    ws.page_setup.fitToWidth  = 1
    ws.page_setup.fitToHeight = 0
    ws.page_margins           = PageMargins(left=0.5, right=0.5,
                                            top=0.75, bottom=0.75)
    ws.print_title_rows = '1:2'   # 인쇄 시 1~2행 반복

    # ── 파일 출력 ─────────────────────────────────────────────────
    output = io.BytesIO()
    wb.save(output)
    output.seek(0)

    filename = (f"출근기록_{year}.{month:02d}"
                f"{'_' + department_filter if department_filter else ''}.xlsx")
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
    """SenseLink relay /attendance 에서 출근 데이터 수집
    relay 필드: user_name, sign_time_str, type("1"=직원), device_direction("0"=입장)
    로직: type="1" + 하루 최초 입장 시각 = 출근시각
    """
    data  = request.json or {}
    year  = data.get('year',  datetime.now().year)
    month = data.get('month', datetime.now().month)

    date_prefix = f"{year:04d}-{month:02d}-"
    _, last_d   = calendar.monthrange(year, month)
    HEADERS = {'ngrok-skip-browser-warning': 'true', 'User-Agent': 'AMS/1.0'}

    all_recs, errors = [], []
    page, size = 1, 100
    MAX_PAGES  = 200

    while page <= MAX_PAGES:
        try:
            resp = _req.get(
                f"{SENSELINK_RELAY_URL}/attendance",
                params={'page': page, 'size': size,
                        'year': year, 'month': month,
                        'start': f"{year:04d}-{month:02d}-01",
                        'end':   f"{year:04d}-{month:02d}-{last_d:02d}"},
                headers=HEADERS, timeout=30
            )
            if resp.status_code != 200:
                errors.append(f"relay HTTP {resp.status_code}")
                break
            body     = resp.json()
            data_obj = body.get('data', {})
            recs     = data_obj.get('list', [])
            total    = data_obj.get('total', 0)
            if not recs:
                break

            for rec in recs:
                st = rec.get('sign_time_str', '')
                if st.startswith(date_prefix):
                    all_recs.append(rec)

            oldest = min((r.get('sign_time_str','') for r in recs), default='')
            if oldest and oldest < f"{year:04d}-{month:02d}-01":
                break
            if page * size >= total:
                break
            page += 1
        except Exception as e:
            errors.append(str(e)); break

    # 하루 최초 입장(type=1) 선택
    best = {}
    for rec in all_recs:
        uname = (rec.get('user_name') or '').strip()
        stime = rec.get('sign_time_str', '')
        if not uname or not stime or str(rec.get('type','')) != '1':
            continue
        dkey = stime[:10]
        key  = (uname, dkey)
        direction = str(rec.get('device_direction','0'))
        cur = best.get(key)
        if cur is None:
            best[key] = rec
        else:
            cur_dir = str(cur.get('device_direction','0'))
            if direction == '0' and cur_dir != '0':
                best[key] = rec
            elif direction == cur_dir and stime < cur.get('sign_time_str',''):
                best[key] = rec

    synced = 0
    for (uname, dkey), rec in best.items():
        try:
            emp = Employee.query.filter_by(name=uname, is_active=True).first()
            if not emp:
                continue
            work_date = datetime.strptime(dkey, '%Y-%m-%d').date()
            stime     = rec.get('sign_time_str','')
            ci_time   = None
            if len(stime) >= 19:
                ci_time = datetime.strptime(stime[:19], '%Y-%m-%d %H:%M:%S').time()
            existing = AttendanceRecord.query.filter_by(
                employee_id=emp.id, date=work_date).first()
            if existing:
                if ci_time: existing.check_in_time = ci_time
                existing.data_source = 'senselink'
            else:
                db.session.add(AttendanceRecord(
                    employee_id=emp.id, date=work_date,
                    check_in_time=ci_time, record_type='normal',
                    data_source='senselink'))
            synced += 1
        except Exception:
            pass
    db.session.commit()

    return jsonify({
        'code': 200, 'message': f'{synced}건 동기화 완료',
        'synced': synced, 'fetched': len(all_recs),
        'errors': errors[:5], 'relay_url': SENSELINK_RELAY_URL
    })

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
