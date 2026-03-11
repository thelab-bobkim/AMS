from flask_sqlalchemy import SQLAlchemy
from datetime import datetime

db = SQLAlchemy()

class Employee(db.Model):
    __tablename__ = 'employees'
    id               = db.Column(db.Integer, primary_key=True)
    name             = db.Column(db.String(50), nullable=False)
    department       = db.Column(db.String(100))
    data_source      = db.Column(db.String(20), default='manual')
    dauoffice_user_id= db.Column(db.String(100), unique=True, nullable=True)
    is_active        = db.Column(db.Boolean, default=True)
    created_at       = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at       = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    attendance_records = db.relationship('AttendanceRecord', backref='employee', lazy=True, cascade='all, delete-orphan')

    def to_dict(self):
        return {
            'id': self.id, 'name': self.name, 'department': self.department,
            'data_source': self.data_source, 'dauoffice_user_id': self.dauoffice_user_id,
            'is_active': self.is_active
        }

class AttendanceRecord(db.Model):
    __tablename__ = 'attendance_records'
    id           = db.Column(db.Integer, primary_key=True)
    employee_id  = db.Column(db.Integer, db.ForeignKey('employees.id'), nullable=False)
    date         = db.Column(db.Date, nullable=False)
    check_in_time= db.Column(db.Time, nullable=True)
    record_type  = db.Column(db.String(20), default='normal')
    note         = db.Column(db.String(500))
    data_source  = db.Column(db.String(20), default='manual')
    created_at   = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at   = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    __table_args__ = (db.UniqueConstraint('employee_id', 'date', name='_employee_date_uc'),)

    def to_dict(self):
        return {
            'id': self.id, 'employee_id': self.employee_id,
            'employee_name': self.employee.name,
            'date': self.date.isoformat(),
            'check_in_time': self.check_in_time.strftime('%H:%M:%S') if self.check_in_time else None,
            'record_type': self.record_type, 'note': self.note, 'data_source': self.data_source
        }

class DauofficeToken(db.Model):
    __tablename__ = 'dauoffice_tokens'
    id           = db.Column(db.Integer, primary_key=True)
    access_token = db.Column(db.String(500), nullable=False)
    expires_at   = db.Column(db.DateTime, nullable=False)
    created_at   = db.Column(db.DateTime, default=datetime.utcnow)
    def is_valid(self): return datetime.utcnow() < self.expires_at
