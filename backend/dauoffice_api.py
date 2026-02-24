import requests
from datetime import datetime, timedelta
from models import db, DauofficeToken

class DauofficeAPIClient:
    """다우오피스 OpenAPI 클라이언트"""
    
    def __init__(self, api_key, api_url, server_ip):
        self.api_key = api_key
        self.api_url = api_url
        self.server_ip = server_ip
        self.access_token = None
    
    def get_access_token(self):
        """Access Token 발급/조회
        다우오피스 API Key를 Bearer Token으로 사용
        """
        # 다우오피스는 API Key를 직접 Bearer Token으로 사용
        # DB 토큰 검증 로직은 향후 토큰 갱신 API가 제공될 경우 활용
        if self.api_key:
            self.access_token = self.api_key
            return self.access_token
        
        print("API Key가 설정되지 않았습니다.")
        return None
    
    def _make_request(self, method, endpoint, data=None):
        """공통 API 요청 메서드"""
        if not self.access_token:
            self.get_access_token()
        
        url = f"{self.api_url}{endpoint}"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.access_token}"
        }
        
        try:
            if method == "GET":
                response = requests.get(url, headers=headers, verify=False, timeout=10)
            elif method == "POST":
                response = requests.post(url, json=data, headers=headers, verify=False, timeout=10)
            
            return response
        except Exception as e:
            print(f"API 요청 오류: {str(e)}")
            return None
    
    def get_attendance_records(self, start_date, end_date, page=0, page_size=50):
        """근태 정보 조회
        
        Args:
            start_date: 시작일 (YYYY-MM-DD)
            end_date: 종료일 (YYYY-MM-DD)
            page: 페이지 번호 (기본값: 0)
            page_size: 페이지 크기 (기본값: 50)
        
        Returns:
            dict: 근태 기록 딕셔너리 (totalCount, elements 포함)
        """
        # 다우오피스 근태 이력 조회 API v2
        endpoint = f"/public/api/attnd-v2/attnd?startDate={start_date}&endDate={end_date}&page={page}&pageSize={page_size}"
        
        response = self._make_request("GET", endpoint)
        
        if response and response.status_code == 200:
            data = response.json()
            if data.get('code') == '200':
                return data.get('data', {})
            else:
                print(f"근태 정보 조회 실패: {data.get('message')}")
                return {'totalCount': 0, 'elements': []}
        else:
            print(f"근태 정보 조회 실패: {response.status_code if response else 'No response'}")
            return {'totalCount': 0, 'elements': []}
    
    def register_attendance_record(self, user_id, date, check_in_time, record_type='normal', note=''):
        """근태 기록 등록 (수동 입력 시 다우오피스에도 등록)
        
        Args:
            user_id: 다우오피스 사용자 ID
            date: 날짜 (YYYY-MM-DD)
            check_in_time: 출근 시간 (HH:MM:SS)
            record_type: 기록 타입
            note: 메모
        
        Returns:
            bool: 성공 여부
        """
        endpoint = "/api/v1/attendance/register"
        
        data = {
            "user_id": user_id,
            "date": date,
            "check_in_time": check_in_time,
            "record_type": record_type,
            "note": note
        }
        
        response = self._make_request("POST", endpoint, data)
        
        if response and response.status_code == 200:
            return True
        else:
            print(f"근태 기록 등록 실패: {response.status_code if response else 'No response'}")
            return False
    
    def get_organization_info(self):
        """조직 정보 조회 (직원 목록)
        
        Returns:
            list: 직원 정보 리스트
        """
        # 다우오피스 조직도 사용자 목록 조회 API v3
        endpoint = "/public/api/attnd-v3/organization-chart/user/list"
        
        response = self._make_request("GET", endpoint)
        
        if response and response.status_code == 200:
            data = response.json()
            if data.get('code') == '200':
                return data.get('data', [])
            else:
                print(f"조직 정보 조회 실패: {data.get('message')}")
                return []
        else:
            print(f"조직 정보 조회 실패: {response.status_code if response else 'No response'}")
            return []
    
    def sync_employees_from_dauoffice(self):
        """다우오피스에서 직원 정보 동기화
        
        Returns:
            int: 동기화된 직원 수
        """
        from models import Employee
        
        employees = self.get_organization_info()
        synced_count = 0
        
        for emp_data in employees:
            # 다우오피스 로그인 ID로 기존 직원 찾기
            login_id = emp_data.get('loginId')
            if not login_id:
                continue
            
            employee = Employee.query.filter_by(dauoffice_user_id=login_id).first()
            
            # 부서 정보 추출 (userGroups에서 첫 번째 그룹의 이름)
            user_groups = emp_data.get('userGroups', [])
            department = user_groups[0].get('name') if user_groups else '미지정'
            
            if not employee:
                # 새 직원 추가
                employee = Employee(
                    name=emp_data.get('name'),
                    department=department,
                    data_source='dauoffice',
                    dauoffice_user_id=login_id
                )
                db.session.add(employee)
                synced_count += 1
            else:
                # 기존 직원 정보 업데이트
                employee.name = emp_data.get('name')
                employee.department = department
                employee.is_active = (emp_data.get('status') == 'ONLINE')
                synced_count += 1
        
        db.session.commit()
        return synced_count
    
    def sync_attendance_from_dauoffice(self, year, month):
        """다우오피스에서 근태 기록 동기화
        
        Args:
            year: 년도
            month: 월
        
        Returns:
            int: 동기화된 기록 수
        """
        from models import Employee, AttendanceRecord
        from calendar import monthrange
        
        # 해당 월의 시작일과 종료일 계산
        _, last_day = monthrange(year, month)
        start_date = f"{year:04d}-{month:02d}-01"
        end_date = f"{year:04d}-{month:02d}-{last_day:02d}"
        
        synced_count = 0
        page = 0
        page_size = 50
        
        while True:
            # 근태 데이터 가져오기 (페이지네이션)
            result = self.get_attendance_records(start_date, end_date, page, page_size)
            elements = result.get('elements', [])
            
            if not elements:
                break
            
            for att_data in elements:
                # 로그인 ID로 직원 찾기
                login_id = att_data.get('loginId')
                employee = Employee.query.filter_by(dauoffice_user_id=login_id).first()
                
                if not employee:
                    # 직원이 DB에 없으면 건너뛴기
                    continue
                
                # 출근 날짜
                accrual_date = att_data.get('accrualDate')
                if not accrual_date:
                    continue
                
                # 기존 기록 확인
                existing_record = AttendanceRecord.query.filter_by(
                    employee_id=employee.id,
                    date=datetime.strptime(accrual_date, '%Y-%m-%d').date()
                ).first()
                
                # 출근 시간 파싱
                start_work_time = att_data.get('startWorkTime')
                check_in_time = None
                if start_work_time:
                    try:
                        check_in_time = datetime.strptime(start_work_time, '%H:%M:%S').time()
                    except:
                        pass
                
                # 기록 타입 결정 (normal, leave 등)
                record_type = 'normal'
                # 다우오피스 API에서 휴가/연차 정보를 제공하는 경우 여기서 판단
                # 현재는 기본값으로 normal 설정
                
                if not existing_record:
                    # 새 기록 추가
                    new_record = AttendanceRecord(
                        employee_id=employee.id,
                        date=datetime.strptime(accrual_date, '%Y-%m-%d').date(),
                        check_in_time=check_in_time,
                        record_type=record_type,
                        data_source='dauoffice'
                    )
                    db.session.add(new_record)
                    synced_count += 1
                else:
                    # 기존 기록 업데이트 (수동 입력된 기록이 아니면)
                    if existing_record.data_source == 'dauoffice':
                        existing_record.check_in_time = check_in_time
                        existing_record.record_type = record_type
                        synced_count += 1
            
            # 다음 페이지
            page += 1
            total_pages = result.get('totalPages', 1)
            if page >= total_pages:
                break
        
        db.session.commit()
        return synced_count
