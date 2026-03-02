import hashlib, time, requests, logging
from flask import Flask, request, Response, jsonify
import urllib3
urllib3.disable_warnings()

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger(__name__)

app = Flask(__name__)
SENSELINK = "http://192.168.250.183"
APP_KEY   = "c6324cfa50169e85"
SECRET    = "e30af86f8f4e75d128ba4288597dea3c"

DB_CONFIG = {
    "host": "192.168.250.183", "port": 3306,
    "user": "senselink", "password": "senselink_2018_local",
    "database": "bi_slink_base", "charset": "utf8mb4"
}

def get_db():
    import pymysql
    return pymysql.connect(**DB_CONFIG, connect_timeout=5)

def rows_to_list(cur):
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, [str(v) if v is not None else "" for v in row]))
            for row in cur.fetchall()]

@app.route("/attendance")
def attendance():
    try:
        page  = int(request.args.get("page", 1))
        size  = int(request.args.get("size", 100))
        dept  = request.args.get("dept", "")

        # AMS(start/end) 또는 직접호출(dateTimeFrom/dateTimeTo) 파라미터 모두 지원
        date_from_raw = (request.args.get("dateTimeFrom")
                         or request.args.get("start", ""))
        date_to_raw   = (request.args.get("dateTimeTo")
                         or request.args.get("end", ""))

        # start/end 가 YYYY-MM-DD 형식이면 시간 붙이기
        if date_from_raw and len(date_from_raw) == 10:
            date_from = date_from_raw + " 00:00:00"
        elif date_from_raw:
            date_from = date_from_raw
        else:
            date_from = "2026-01-01 00:00:00"

        if date_to_raw and len(date_to_raw) == 10:
            date_to = date_to_raw + " 23:59:59"
        elif date_to_raw:
            date_to = date_to_raw
        else:
            date_to = "2026-12-31 23:59:59"

        offset = (page - 1) * size

        conn = get_db()
        cur  = conn.cursor()

        dept_filter = "AND r.group_name = %s" if dept else ""
        params_count = [date_from, date_to]
        params_data  = [date_from, date_to]
        if dept:
            params_count.append(dept)
            params_data.append(dept)

        cur.execute(
            f"SELECT COUNT(*) FROM t_record r "
            f"WHERE r.sign_time_str >= %s AND r.sign_time_str <= %s {dept_filter}",
            params_count
        )
        total = cur.fetchone()[0]

        params_data += [size, offset]
        cur.execute(
            f"""SELECT r.id, r.user_name, r.group_name,
                       r.sign_time_str, r.device_name, r.location,
                       r.in_time, r.device_direction, r.type,
                       r.body_temperature, r.verify_score, r.job_number
                FROM t_record r
                WHERE r.sign_time_str >= %s AND r.sign_time_str <= %s {dept_filter}
                ORDER BY r.sign_time_str ASC
                LIMIT %s OFFSET %s""",
            params_data
        )
        rows = rows_to_list(cur)
        conn.close()

        log.info(f"[attendance] {date_from}~{date_to} dept={dept or ALL} total={total} page={page}")
        return jsonify({
            "code": 200, "message": "success",
            "data": {"total": total, "page": page, "size": size, "list": rows}
        })
    except Exception as e:
        log.error(f"[attendance] error: {e}")
        return jsonify({"code": 500, "error": str(e)})

@app.route("/attendance/summary")
def attendance_summary():
    try:
        date_from = request.args.get("dateTimeFrom", "2026-01-01 00:00:00")
        date_to   = request.args.get("dateTimeTo",   "2026-12-31 23:59:59")
        conn = get_db()
        cur  = conn.cursor()
        cur.execute(
            """SELECT group_name,
                      COUNT(*) AS total_records,
                      COUNT(DISTINCT user_name) AS unique_users,
                      SUM(CASE WHEN in_time=1 THEN 1 ELSE 0 END) AS checkin_count,
                      SUM(CASE WHEN in_time=0 THEN 1 ELSE 0 END) AS checkout_count
               FROM t_record
               WHERE sign_time_str >= %s AND sign_time_str <= %s
               GROUP BY group_name
               ORDER BY total_records DESC""",
            (date_from, date_to)
        )
        rows = rows_to_list(cur)
        conn.close()
        return jsonify({"code": 200, "data": rows})
    except Exception as e:
        return jsonify({"code": 500, "error": str(e)})

@app.route("/departments")
def departments():
    try:
        conn = get_db()
        cur  = conn.cursor()
        cur.execute(
            """SELECT group_name, COUNT(DISTINCT user_name) AS user_count
               FROM t_record WHERE group_name != ""
               GROUP BY group_name ORDER BY group_name"""
        )
        rows = rows_to_list(cur)
        conn.close()
        return jsonify({"code": 200, "data": rows})
    except Exception as e:
        return jsonify({"code": 500, "error": str(e)})

@app.route("/users")
def users():
    try:
        conn = get_db()
        cur  = conn.cursor()
        cur.execute(
            """SELECT u.id, u.name, u.job_number,
                      d.name AS dept_name, u.phone, u.status
               FROM t_user u
               LEFT JOIN t_department d ON u.department_id = d.id
               ORDER BY d.name, u.name"""
        )
        rows = rows_to_list(cur)
        conn.close()
        return jsonify({"code": 200, "total": len(rows), "list": rows})
    except Exception as e:
        return jsonify({"code": 500, "error": str(e)})

@app.route("/health")
def health():
    try:
        conn = get_db()
        cur  = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM t_record")
        total = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM t_record WHERE sign_time_str >= \"2026-03-01\"")
        mar = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM t_record WHERE sign_time_str >= \"2026-02-01\" AND sign_time_str < \"2026-03-01\"")
        feb = cur.fetchone()[0]
        conn.close()
        return jsonify({"relay": "ok", "db": "connected",
                        "total_records": total, "mar_2026": mar, "feb_2026": feb})
    except Exception as e:
        return jsonify({"relay": "ok", "db": "error", "error": str(e)})

if __name__ == "__main__":
    print("=" * 55)
    print("  SenseLink 중계 서버 v8 - 포트 8765")
    print("  MySQL 직접 연동 (start/end + dateTimeFrom/To 지원)")
    print("  /health              : 연결 상태")
    print("  /attendance          : 근태 데이터 조회")
    print("  /attendance/summary  : 부서별 요약")
    print("  /departments         : 부서 목록")
    print("  /users               : 사용자 목록")
    print("=" * 55)
    app.run(host="0.0.0.0", port=8765, debug=False)

