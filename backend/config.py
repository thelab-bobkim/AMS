import os
from dotenv import load_dotenv

load_dotenv()

class Config:
    # Flask
    SECRET_KEY = os.getenv('FLASK_SECRET_KEY', 'dev-secret-key-change-in-production')
    
    # Database
    SQLALCHEMY_DATABASE_URI = os.getenv('DATABASE_URL', 'sqlite:///attendance.db')
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    
    # 다우오피스 API - OAuth2 Client Credentials 방식
    DAUOFFICE_CLIENT_ID = os.getenv('DAUOFFICE_CLIENT_ID', '')
    DAUOFFICE_CLIENT_SECRET = os.getenv('DAUOFFICE_CLIENT_SECRET', '')
    DAUOFFICE_API_URL = os.getenv('DAUOFFICE_API_URL', 'https://api.daouoffice.com')
    
    # 하위 호환: 기존 DAUOFFICE_API_KEY → CLIENT_ID로 폴백
    @classmethod
    def get_client_id(cls):
        return cls.DAUOFFICE_CLIENT_ID or os.getenv('DAUOFFICE_API_KEY', '')
    
    @classmethod
    def get_client_secret(cls):
        return cls.DAUOFFICE_CLIENT_SECRET or os.getenv('DAUOFFICE_API_KEY', '')
    
    # 근태 데이터 소스
    DATA_SOURCE_DAUOFFICE = 'dauoffice'
    DATA_SOURCE_MANUAL = 'manual'
