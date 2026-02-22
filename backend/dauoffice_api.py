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
        """Access Token 발급/조회"""
        # DB에서 유효한 토큰 확인
        token_record = DauofficeToken.query.order_by(DauofficeToken.created_at.desc()).first()
        
        if token_record and token_record.is_valid():
            self.access_token = token_record.access_token
            return self.access_token
        
        # 새로운 토큰 발급
        try:
            # 인증키 발급 API 호출 (문서 기반)
            # 실제 API 엔드포인트는 다우오피스 문서 확인 필요
            url = f"{self.api_url}/api/v1/auth/token"
            
            payload = {
                "api_key": self.api_key,
                "server_ip": self.server_ip
            }
            
            headers = {
                "Content-Type": "application/json"
            }
            
            # SSL 검증 비활성화 (개발 환경용, 프로덕션에서는 제거)
            response = requests.post(url, json=payload, headers=headers, verify=False, timeout=10)
            
            if response.status_code == 200:
                data = response.json()
                self.access_token = data.get('access_token')
                expires_in = data.get('expires_in', 3600)  # 기본 1시간
                
                # DB에 저장
                token_record = DauofficeToken(
                    access_token=self.access_token,
                    expires_at=datetime.utcnow() + timedelta(seconds=expires_in)
                )
                db.session.add(token_record)
                db.session.commit()
                
                return self.access_token
            else:
                raise Exception(f"토큰 발급 실패: {response.status_code} - {response.text}")
        
        except Exception as e:
            print(f"Access Token 발급 오류: {str(e)}")
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
    
    def get_attendance_records(self, start_date, end_date):
        """근태 정보 조회
        
        Args:
            start_date: 시작일 (YYYY-MM-DD)
            end_date: 종료일 (YYYY-MM-DD)
        
        Returns:
            list: 근태 기록 리스트
        """
        # 다우오피스 근태정보 조회 API
        # 실제 엔드포인트는 문서 확인 필요
        endpoint = "/api/v1/attendance/records"
        
        data = {
            "start_date": start_date,
            "end_date": end_date
        }
        
        response = self._make_request("POST", endpoint, data)
        
        if response and response.status_code == 200:
            return response.json().get('records', [])
        else:
            print(f"근태 정보 조회 실패: {response.status_code if response else 'No response'}")
            return []
    
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
        endpoint = "/api/v1/organization/employees"
        
        response = self._make_request("POST", endpoint)
        
        if response and response.status_code == 200:
            return response.json().get('employees', [])
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
            # 다우오피스 사용자 ID로 기존 직원 찾기
            dauoffice_user_id = emp_data.get('user_id')
            employee = Employee.query.filter_by(dauoffice_user_id=dauoffice_user_id).first()
            
            if not employee:
                # 새 직원 추가
                employee = Employee(
                    name=emp_data.get('name'),
                    department=emp_data.get('department'),
                    data_source='dauoffice',
                    dauoffice_user_id=dauoffice_user_id
                )
                db.session.add(employee)
                synced_count += 1
            else:
                # 기존 직원 정보 업데이트
                employee.name = emp_data.get('name')
                employee.department = emp_data.get('department')
                synced_count += 1
        
        db.session.commit()
        return synced_count
