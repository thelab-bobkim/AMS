from flask_sqlalchemy import SQLAlchemy
from datetime import datetime

db = SQLAlchemy()

class Employee(db.Model):
    """직원 정보"""
    __tablename__ = 'employees'
    
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(50), nullable=False)  # 성명
    department = db.Column(db.String(100))  # 부서/팀
    
    # 데이터 소스 구분
    data_source = db.Column(db.String(20), default='manual')  # 'dauoffice' or 'manual'
    dauoffice_user_id = db.Column(db.String(100), unique=True, nullable=True)  # 다우오피스 사용자 ID
    
    is_active = db.Column(db.Boolean, default=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # 관계
    attendance_records = db.relationship('AttendanceRecord', backref='employee', lazy=True, cascade='all, delete-orphan')
    
    def to_dict(self):
        return {
            'id': self.id,
            'name': self.name,
            'department': self.department,
            'data_source': self.data_source,
            'dauoffice_user_id': self.dauoffice_user_id,
            'is_active': self.is_active
        }


class AttendanceRecord(db.Model):
    """출근 기록"""
    __tablename__ = 'attendance_records'
    
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.Integer, db.ForeignKey('employees.id'), nullable=False)
    
    date = db.Column(db.Date, nullable=False)  # 날짜
    check_in_time = db.Column(db.Time, nullable=True)  # 출근 시간
    
    # 특수 기록
    record_type = db.Column(db.String(20), default='normal')  # 'normal', 'annual_leave', 'half_leave', 'business_trip', 'substitute_holiday'
    note = db.Column(db.String(500))  # 메모 (예: "출장-셀락바이오")
    
    # 데이터 소스
    data_source = db.Column(db.String(20), default='manual')  # 'dauoffice' or 'manual'
    
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # 중복 방지: 한 직원의 같은 날짜에 하나의 레코드만
    __table_args__ = (db.UniqueConstraint('employee_id', 'date', name='_employee_date_uc'),)
    
    def to_dict(self):
        return {
            'id': self.id,
            'employee_id': self.employee_id,
            'employee_name': self.employee.name,
            'date': self.date.isoformat(),
            'check_in_time': self.check_in_time.strftime('%H:%M:%S') if self.check_in_time else None,
            'record_type': self.record_type,
            'note': self.note,
            'data_source': self.data_source
        }


class DauofficeToken(db.Model):
    """다우오피스 Access Token 관리"""
    __tablename__ = 'dauoffice_tokens'
    
    id = db.Column(db.Integer, primary_key=True)
    access_token = db.Column(db.String(500), nullable=False)
    expires_at = db.Column(db.DateTime, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    def is_valid(self):
        return datetime.utcnow() < self.expires_at
