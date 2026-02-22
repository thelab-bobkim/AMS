import os
from dotenv import load_dotenv

load_dotenv()

class Config:
    # Flask
    SECRET_KEY = os.getenv('FLASK_SECRET_KEY', 'dev-secret-key-change-in-production')
    
    # Database
    SQLALCHEMY_DATABASE_URI = os.getenv('DATABASE_URL', 'sqlite:///attendance.db')
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    
    # 다우오피스 API
    DAUOFFICE_API_KEY = os.getenv('DAUOFFICE_API_KEY', '')
    DAUOFFICE_API_URL = os.getenv('DAUOFFICE_API_URL', 'https://35.216.3.121')
    DAUOFFICE_SERVER_IP = os.getenv('DAUOFFICE_SERVER_IP', '35.216.3.121')
    
    # 근태 데이터 소스
    DATA_SOURCE_DAUOFFICE = 'dauoffice'
    DATA_SOURCE_MANUAL = 'manual'
