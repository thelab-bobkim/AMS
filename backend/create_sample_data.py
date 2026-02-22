"""샘플 데이터 생성 스크립트"""
import sys
sys.path.append('/home/user/attendance-system/backend')

from app import app, db
from models import Employee, AttendanceRecord
from datetime import datetime, timedelta
import random

with app.app_context():
    # 데이터베이스 초기화
    db.drop_all()
    db.create_all()
    
    print("데이터베이스 초기화 완료")
    
    # 샘플 직원 데이터 (기존 엑셀 파일 참고)
    sample_employees = [
        {"name": "임규동", "department": "Cohesity사업부", "data_source": "dauoffice", "dauoffice_user_id": "emp001"},
        {"name": "정석우", "department": "CA사업본부", "data_source": "dauoffice", "dauoffice_user_id": "emp002"},
        {"name": "박희열", "department": "CA사업본부", "data_source": "dauoffice", "dauoffice_user_id": "emp003"},
        {"name": "김준서", "department": "CA사업본부", "data_source": "manual"},
        {"name": "최종민", "department": "Actera사업부", "data_source": "manual"},
        {"name": "김재천", "department": "CA사업본부", "data_source": "dauoffice", "dauoffice_user_id": "emp006"},
        {"name": "신원식", "department": "백업팀", "data_source": "manual"},
        {"name": "박상민", "department": "CA사업본부", "data_source": "dauoffice", "dauoffice_user_id": "emp008"},
    ]
    
    # 직원 추가
    employees = []
    for emp_data in sample_employees:
        emp = Employee(**emp_data)
        db.session.add(emp)
        employees.append(emp)
    
    db.session.commit()
    print(f"{len(employees)}명의 직원 추가 완료")
    
    # 2026년 1월 샘플 출근 기록 생성
    year = 2026
    month = 1
    
    # 시간 샘플
    sample_times = [
        "07:50:14", "08:00:23", "08:30:45", "09:00:12", "09:15:33",
        "09:30:21", "10:00:45", "10:15:22", "11:00:13"
    ]
    
    record_types = ["normal", "annual_leave", "business_trip"]
    
    attendance_count = 0
    
    for emp in employees:
        # 각 직원에 대해 1월 평일 데이터 생성 (약 15-20일)
        for day in range(1, 32):
            date_obj = datetime(year, month, day).date()
            weekday = date_obj.weekday()
            
            # 주말은 스킵
            if weekday >= 5:
                continue
            
            # 70% 확률로 데이터 생성 (일부는 비움)
            if random.random() > 0.7:
                continue
            
            # 랜덤으로 기록 유형 선택
            record_type = random.choice(record_types) if random.random() > 0.8 else "normal"
            
            check_in_time = None
            note = ""
            
            if record_type == "normal":
                time_str = random.choice(sample_times)
                check_in_time = datetime.strptime(time_str, "%H:%M:%S").time()
            elif record_type == "business_trip":
                note = "출장-고객사"
            
            record = AttendanceRecord(
                employee_id=emp.id,
                date=date_obj,
                check_in_time=check_in_time,
                record_type=record_type,
                note=note,
                data_source=emp.data_source
            )
            
            db.session.add(record)
            attendance_count += 1
    
    db.session.commit()
    print(f"{attendance_count}개의 출근 기록 생성 완료")
    print("\n샘플 데이터 생성 완료!")
    print(f"- 직원 수: {len(employees)}명")
    print(f"- 출근 기록: {attendance_count}개")
    print(f"- 기간: {year}년 {month}월")
