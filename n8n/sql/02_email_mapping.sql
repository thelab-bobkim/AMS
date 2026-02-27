-- 담당자 이메일 매핑 업데이트 SQL
-- 용도: contracts 테이블의 NULL sales_rep_email 값을 실제 이메일로 채움
UPDATE contracts SET sales_rep_email = 'ghkim1@dsti.co.kr' WHERE sales_rep_name = '김규헌' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'ytkim@dsti.co.kr' WHERE sales_rep_name = '김용태' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'karisma5882@naver.com' WHERE sales_rep_name = '김윤식' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'jckim@dsti.co.kr' WHERE sales_rep_name = '김재천' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'jskim@dsti.co.kr' WHERE sales_rep_name = '김준서' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'hjyoo@dsti.co.kr' WHERE sales_rep_name = '김형태' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'hushms@dsti.co.kr' WHERE sales_rep_name = '박민식' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'smpark@dsti.co.kr' WHERE sales_rep_name = '박상민' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'hj.lee@dsti.co.kr' WHERE sales_rep_name = '박용석' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'pjj@dsti.co.kr' WHERE sales_rep_name = '박정재' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'hypark@dsti.co.kr' WHERE sales_rep_name = '박희열' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'jws@dsti.co.kr' WHERE sales_rep_name = '손지원' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'palseokoh@dsti.co.kr' WHERE sales_rep_name = '오팔석' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'ywyoun@dsti.co.kr' WHERE sales_rep_name = '윤윤원' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'yklee@dsti.co.kr' WHERE sales_rep_name = '이용건' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'cklee@dsti.co.kr' WHERE sales_rep_name = '이종갑' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'gdlim@dsti.co.kr' WHERE sales_rep_name = '임규동' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'gblim@dsti.co.kr' WHERE sales_rep_name = '임규빈' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'jmlim@dsti.co.kr' WHERE sales_rep_name = '임종만' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'chjang@dsti.co.kr' WHERE sales_rep_name = '장창훈' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'swjeong@dsti.co.kr' WHERE sales_rep_name = '정석우' AND (sales_rep_email IS NULL OR sales_rep_email = '');
UPDATE contracts SET sales_rep_email = 'jmchoi@dsti.co.kr' WHERE sales_rep_name = '최종민' AND (sales_rep_email IS NULL OR sales_rep_email = '');

-- 검증
SELECT sales_rep_name, sales_rep_email, COUNT(*) 
FROM contracts 
GROUP BY sales_rep_name, sales_rep_email 
ORDER BY sales_rep_name;
