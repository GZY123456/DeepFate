import base64
import hashlib
import hmac
import json
import os
import random
import ssl
import time
from datetime import datetime
from time import mktime
from urllib.parse import urlencode, urlparse
from wsgiref.handlers import format_date_time
from flask import Flask, Response, jsonify, request, stream_with_context
import websocket
import psycopg2
import psycopg2.extras
from dotenv import load_dotenv

BASE_DIR = os.path.dirname(__file__)
load_dotenv(os.path.join(BASE_DIR, ".env"))

SPARK_SYSTEM_PROMPT1 = '''
你是一个精通八字，紫微斗数，奇门遁甲等命理知识的玄学大师，我是一个命理师，帮我为客户看一下她的八字/紫微斗数。输出一份家庭、事业、姻缘、财富、长相、健康等的全面报告。八字：xx xx xx xx，性别、出生地，起运时间，当前大运
说出用户的性格特点，长相特点，并输出几件用户在以往人生中发生的关键事件作为命盘验证。
然后有以下问题：
1.该用户的用神是什么？忌神是什么？具体体现在什么方面，有没有好的建议？
2.是否成格？具体格局是什么？
3.排大运，哪步大运是好运，找准备什么？哪步大运较差，要注意什么？
还有一些问题：
1.用户命盘里最突出的才智或天赋特征是什么？
2.如果每个人来到世界上都有使命，那么用户的使命是什么？
3.最幸运的地方体现在哪？最遗憾的地方体现在哪？
4.事业上适合在公司干（大平台，小公司还是事业编），独立做事或者创业？有没有适合的领域或副业？
5.命盘中有什么用户尚未意识但应该引起注意的问题？
6.描述下正缘伴侣的长相。
'''

SPARK_SYSTEM_PROMPT = '''
你是一个精通八字，紫微斗数，奇门遁甲等命理知识的玄学大师，我是一个命理师，帮我为客户看一下她的八字并回复用户的问题。八字：xx xx xx xx，性别、出生地，起运时间，当前大运。
现在是{time}
'''

SPARK_TITLE_PROMPT = "请基于用户的第一条消息生成一个不超过12个字的聊天标题，直接输出标题文本，不要加引号。"

APP_ID = os.getenv("SPARK_APP_ID", "")
API_KEY = os.getenv("SPARK_API_KEY", "")
API_SECRET = os.getenv("SPARK_API_SECRET", "")
SPARK_URL = os.getenv("SPARK_URL", "wss://spark-api.xf-yun.com/v1/x1")
SPARK_DOMAIN = os.getenv("SPARK_DOMAIN", "spark-x")
SPARK_SYSTEM_PROMPT = os.getenv("SPARK_SYSTEM_PROMPT", SPARK_SYSTEM_PROMPT)
SPARK_DEBUG_RESPONSE = os.getenv("SPARK_DEBUG_RESPONSE", "0") == "1"


app = Flask(__name__)
LOCATION_FILE = os.path.join(BASE_DIR, "locations.json")
PROFILE_FILE = os.path.join(BASE_DIR, "profiles.json")

DB_CONFIG = {
    "host": os.getenv("POSTGRES_HOST", "localhost"),
    "port": int(os.getenv("POSTGRES_PORT", "5432")),
    "dbname": os.getenv("POSTGRES_DB", "deepfate"),
    "user": os.getenv("POSTGRES_USER", "postgres"),
    "password": os.getenv("POSTGRES_PASSWORD", "your_password_here"),
}

# OSS config (reserved for future cloud avatar uploads)
OSS_CONFIG = {
    "endpoint": os.getenv("OSS_ENDPOINT", ""),
    "bucket": os.getenv("OSS_BUCKET", ""),
    "access_key_id": os.getenv("OSS_ACCESS_KEY_ID", ""),
    "access_key_secret": os.getenv("OSS_ACCESS_KEY_SECRET", ""),
    "base_url": os.getenv("OSS_BASE_URL", ""),
}


def get_db_conn():
    return psycopg2.connect(**DB_CONFIG)


def init_db():
    with get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute('CREATE EXTENSION IF NOT EXISTS "pgcrypto";')
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                    phone text UNIQUE NOT NULL,
                    nickname text NOT NULL,
                    password_hash text NOT NULL,
                    created_at timestamptz DEFAULT now(),
                    updated_at timestamptz DEFAULT now()
                );
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS sms_codes (
                    id bigserial PRIMARY KEY,
                    phone text NOT NULL,
                    code text NOT NULL,
                    expires_at timestamptz NOT NULL,
                    created_at timestamptz DEFAULT now()
                );
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS profiles (
                    id uuid PRIMARY KEY,
                    user_id uuid REFERENCES users(id) ON DELETE CASCADE,
                    name text NOT NULL,
                    gender text,
                    location text,
                    solar text,
                    lunar text,
                    true_solar text,
                    created_at timestamptz DEFAULT now(),
                    updated_at timestamptz DEFAULT now()
                );
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS draws (
                    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                    profile_id uuid NOT NULL,
                    draw_date date NOT NULL,
                    card_name text NOT NULL,
                    keywords jsonb NOT NULL,
                    interpretation text NOT NULL,
                    advice text NOT NULL,
                    created_at timestamptz DEFAULT now(),
                    UNIQUE (profile_id, draw_date)
                );
                """
            )


def _hash_password(password, salt=None):
    salt = salt or os.urandom(8).hex()
    digest = hashlib.sha256((salt + password).encode("utf-8")).hexdigest()
    return f"{salt}${digest}"


def _verify_password(password, stored):
    if "$" not in stored:
        return False
    salt, _ = stored.split("$", 1)
    return _hash_password(password, salt) == stored


init_db()

def create_signed_url():
    if not APP_ID or not API_KEY or not API_SECRET:
        return None

    parsed = urlparse(SPARK_URL)
    host = parsed.netloc
    path = parsed.path

    now = datetime.now()
    date = format_date_time(mktime(now.timetuple()))

    signature_origin = f"host: {host}\n"
    signature_origin += f"date: {date}\n"
    signature_origin += f"GET {path} HTTP/1.1"

    signature_sha = hmac.new(
        API_SECRET.encode("utf-8"),
        signature_origin.encode("utf-8"),
        digestmod=hashlib.sha256,
    ).digest()

    signature_sha_base64 = base64.b64encode(signature_sha).decode("utf-8")

    authorization_origin = (
        f'api_key="{API_KEY}", algorithm="hmac-sha256", '
        f'headers="host date request-line", signature="{signature_sha_base64}"'
    )
    authorization = base64.b64encode(authorization_origin.encode("utf-8")).decode("utf-8")

    query = urlencode(
        {
            "authorization": authorization,
            "date": date,
            "host": host,
        }
    )
    return f"{SPARK_URL}?{query}"


@app.get("/spark/handshake")
def handshake():
    ws_url = create_signed_url()
    if not ws_url:
        return jsonify({"error": "missing credentials"}), 500
    return jsonify({"app_id": APP_ID, "ws_url": ws_url})


@app.get("/locations")
def locations():
    try:
        with open(LOCATION_FILE, "r", encoding="utf-8") as file:
            return Response(file.read(), mimetype="application/json")
    except FileNotFoundError:
        return jsonify({"error": "locations data not found"}), 404


def build_spark_payload(messages):
    return {
        "header": {
            "uid": "user_id",
            "app_id": APP_ID,
        },
        "parameter": {
            "chat": {
                "domain": SPARK_DOMAIN,
                "max_tokens": 4096,
                "presence_penalty": 1,
                "temperature": 0.5,
                "frequency_penalty": 0.02,
                "top_k": 5,
                "tools": [
                    {
                        "type": "web_search",
                        "web_search": {
                            "enable": True,
                            "search_mode": "normal",
                        },
                    }
                ],
            }
        },
        "payload": {"message": {"text": messages}},
    }


def build_profile_prompt(profile):
    if not isinstance(profile, dict):
        return ""
    name = profile.get("name", "")
    gender = profile.get("gender", "")
    location = profile.get("location", "")
    solar = profile.get("solar", "")
    lunar = profile.get("lunar", "")
    true_solar = profile.get("trueSolar", "")
    if not any([name, gender, location, solar, lunar, true_solar]):
        return ""
    return (
        "用户档案信息（结构化）：\n"
        f"- 姓名：{name}\n"
        f"- 性别：{gender}\n"
        f"- 出生地：{location}\n"
        f"- 出生时间（阳历）：{solar}\n"
        f"- 出生时间（阴历）：{lunar}\n"
        f"- 真太阳时：{true_solar}\n"
        "请在后续分析中结合以上信息。"
    )


def build_draw_prompt(profile, now_str):
    profile_prompt = build_profile_prompt(profile)
    return (
        "你是一个玄学抽卡占卜师。请根据用户档案与当前时间生成今日的一事一测抽卡结果。\n"
        f"当前时间：{now_str}\n"
        "输出必须是严格 JSON，格式如下：\n"
        '{\"cardName\":\"...\",\"keywords\":[\"...\",\"...\"],\"interpretation\":\"...\",\"advice\":\"...\"}\n'
        "要求：\n"
        "- keywords 3-5 个短语\n"
        "- interpretation 80-140 字\n"
        "- advice 60-120 字\n"
        "- 不要输出任何额外文字、不要换行代码块\n"
        "\n"
        f"{profile_prompt}"
    ).strip()


def parse_draw_response(text):
    if not text:
        return None
    raw = text.strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass
    # Fallback: extract first JSON object
    start = raw.find("{")
    end = raw.rfind("}")
    if start >= 0 and end > start:
        snippet = raw[start:end + 1]
        try:
            return json.loads(snippet)
        except json.JSONDecodeError:
            return None
    return None


def fetch_draw(profile_id, draw_date):
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT card_name, keywords, interpretation, advice
                FROM draws
                WHERE profile_id = %s AND draw_date = %s
                """,
                (str(profile_id), draw_date),
            )
            row = cur.fetchone()
    if not row:
        return None
    return {
        "date": str(draw_date),
        "cardName": row.get("card_name", ""),
        "keywords": row.get("keywords") or [],
        "interpretation": row.get("interpretation", ""),
        "advice": row.get("advice", ""),
    }


def fetch_profile(profile_id):
    if not profile_id:
        return {}
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, name, gender, location, solar, lunar, true_solar
                FROM profiles
                WHERE id = %s
                """,
                (str(profile_id),),
            )
            row = cur.fetchone()
            if not row:
                return {}
            return {
                "id": str(row["id"]),
                "name": row.get("name", ""),
                "gender": row.get("gender", ""),
                "location": row.get("location", ""),
                "solar": row.get("solar", ""),
                "lunar": row.get("lunar", ""),
                "trueSolar": row.get("true_solar", ""),
            }


def build_chat_messages(messages, profile):
    raw_messages = list(messages) if isinstance(messages, list) else []
    def is_error_message(item):
        if item.get("role") != "assistant":
            return False
        content = (item.get("content") or "").strip()
        return content.startswith("请求失败：")

    chat_messages = [
        m for m in raw_messages
        if m.get("role") != "system" and not is_error_message(m)
    ]
    while chat_messages and chat_messages[0].get("role") != "user":
        chat_messages.pop(0)
    # Collapse consecutive duplicate user messages to save tokens.
    compacted = []
    for message in chat_messages:
        if compacted and message.get("role") == "user" and compacted[-1].get("role") == "user":
            if (message.get("content") or "").strip() == (compacted[-1].get("content") or "").strip():
                compacted[-1] = message
                continue
        compacted.append(message)
    chat_messages = compacted
    profile_prompt = build_profile_prompt(profile)
    system_parts = []
    now_str = time.strftime("%Y-%m-%d %H:%M:%S")
    if SPARK_SYSTEM_PROMPT.strip():
        system_parts.append(SPARK_SYSTEM_PROMPT.format(time=now_str).strip())
    if profile_prompt:
        system_parts.append(profile_prompt.strip())
    if system_parts:
        system_message = {"role": "system", "content": "\n\n".join(system_parts)}
        return [system_message] + chat_messages
    return chat_messages


@app.post("/profiles")
def upsert_profile():
    payload = request.get_json(silent=True) or {}
    profile_id = str(payload.get("id", "")).strip()
    if not profile_id:
        return jsonify({"error": "id required"}), 400
    user_id = payload.get("userId")
    if not user_id:
        return jsonify({"error": "userId required"}), 400
    with get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO profiles (id, user_id, name, gender, location, solar, lunar, true_solar)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (id) DO UPDATE SET
                    user_id = EXCLUDED.user_id,
                    name = EXCLUDED.name,
                    gender = EXCLUDED.gender,
                    location = EXCLUDED.location,
                    solar = EXCLUDED.solar,
                    lunar = EXCLUDED.lunar,
                    true_solar = EXCLUDED.true_solar,
                    updated_at = now()
                """,
                (
                    profile_id,
                    user_id,
                    payload.get("name", ""),
                    payload.get("gender", ""),
                    payload.get("location", ""),
                    payload.get("solar", ""),
                    payload.get("lunar", ""),
                    payload.get("trueSolar", ""),
                ),
            )
    print(f"[profiles] upsert id={profile_id}")
    return jsonify({"ok": True})


@app.get("/profiles")
def list_profiles():
    user_id = request.args.get("user_id") or request.args.get("userId")
    if not user_id:
        return jsonify({"error": "user_id required"}), 400
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, name, gender, location, solar, lunar, true_solar, created_at
                FROM profiles
                WHERE user_id = %s
                ORDER BY created_at DESC
                """,
                (user_id,),
            )
            rows = cur.fetchall()
    payload = [
        {
            "id": str(row["id"]),
            "name": row.get("name", ""),
            "gender": row.get("gender", ""),
            "location": row.get("location", ""),
            "solar": row.get("solar", ""),
            "lunar": row.get("lunar", ""),
            "trueSolar": row.get("true_solar", ""),
        }
        for row in rows
    ]
    return jsonify(payload)


@app.get("/profiles/<profile_id>")
def get_profile(profile_id):
    profile = fetch_profile(profile_id)
    if not profile:
        return jsonify({"error": "not found"}), 404
    return jsonify(profile)


@app.delete("/profiles/<profile_id>")
def delete_profile(profile_id):
    user_id = request.args.get("user_id") or request.args.get("userId")
    if not user_id:
        return jsonify({"error": "user_id required"}), 400
    with get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "DELETE FROM profiles WHERE id = %s AND user_id = %s",
                (profile_id, user_id),
            )
    return jsonify({"ok": True})


@app.get("/draws/today")
def get_today_draw():
    profile_id = request.args.get("profile_id") or request.args.get("profileId")
    if not profile_id:
        return jsonify({"error": "profile_id required"}), 400
    today = datetime.now().date()
    existing = fetch_draw(profile_id, today)
    if not existing:
        return jsonify({"error": "not found"}), 404
    return jsonify(existing)


@app.post("/draws/daily")
def create_today_draw():
    payload = request.get_json(silent=True) or {}
    profile_id = payload.get("profileId") or payload.get("profile_id")
    if not profile_id:
        return jsonify({"error": "profileId required"}), 400
    today = datetime.now().date()
    existing = fetch_draw(profile_id, today)
    if existing:
        return jsonify(existing)

    profile = fetch_profile(profile_id) if profile_id else {}
    now_str = time.strftime("%Y-%m-%d %H:%M:%S")
    prompt = build_draw_prompt(profile, now_str)
    messages = [
        {"role": "system", "content": prompt},
        {"role": "user", "content": "开始抽卡。"},
    ]
    try:
        raw = spark_chat(messages)
        parsed = parse_draw_response(raw)
        if not isinstance(parsed, dict):
            return jsonify({"error": "invalid draw response"}), 500
        card_name = (parsed.get("cardName") or "").strip()
        keywords = parsed.get("keywords") or []
        interpretation = (parsed.get("interpretation") or "").strip()
        advice = (parsed.get("advice") or "").strip()
        if not card_name or not interpretation or not advice:
            return jsonify({"error": "draw response missing fields"}), 500
        if not isinstance(keywords, list):
            keywords = [str(keywords)]
        with get_db_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO draws (profile_id, draw_date, card_name, keywords, interpretation, advice)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    ON CONFLICT (profile_id, draw_date) DO NOTHING
                    """,
                    (
                        str(profile_id),
                        today,
                        card_name,
                        psycopg2.extras.Json(keywords),
                        interpretation,
                        advice,
                    ),
                )
        result = {
            "date": str(today),
            "cardName": card_name,
            "keywords": keywords,
            "interpretation": interpretation,
            "advice": advice,
        }
        return jsonify(result)
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": str(exc)}), 500


def build_chart_text(solar_year, solar_month, solar_day, solar_hour, solar_minute, longitude, gender=""):
    """使用 lunar_python 生成八字排盘文本。真太阳时：按经度修正时辰。"""
    try:
        from lunar_python import Solar, Lunar
    except ImportError:
        return "服务端未安装 lunar_python，无法排盘。请联系管理员。"
    try:
        # 阳历日期时间（公历）
        solar = Solar.fromYmdHms(solar_year, solar_month, solar_day, solar_hour, solar_minute or 0, 0)
        # 真太阳时：经度每差 1 度约 4 分钟，东经 120 为基准
        offset_minutes = int(round((float(longitude) - 120.0) * 4.0))
        from datetime import timedelta
        from datetime import datetime as dt
        d = dt(solar_year, solar_month, solar_day, solar_hour, solar_minute or 0, 0)
        d = d + timedelta(minutes=offset_minutes)
        solar = Solar.fromYmdHms(d.year, d.month, d.day, d.hour, d.minute, 0)
        lunar = solar.getLunar()
        # 八字：年柱、月柱、日柱、时柱
        ygz = lunar.getYearInGanZhi()
        mgz = lunar.getMonthInGanZhi()
        dgz = lunar.getDayInGanZhi()
        hgz = lunar.getTimeInGanZhi()
        lines = [
            "【八字排盘】",
            f"公历：{solar_year}年{solar_month}月{solar_day}日 {solar_hour}时{solar_minute or 0}分",
            f"真太阳时（经度{longitude}°）：{d.year}年{d.month}月{d.day}日 {d.hour}时{d.minute}分",
            f"农历：{lunar.toString()}",
            "",
            "四柱：",
            f"  年柱：{ygz}",
            f"  月柱：{mgz}",
            f"  日柱：{dgz}",
            f"  时柱：{hgz}",
            "",
        ]
        try:
            if hasattr(lunar, "getYearShengXiao"):
                lines.append(f"生肖：{lunar.getYearShengXiao()}")
        except Exception:
            pass
        try:
            if hasattr(lunar, "getDayNaYin"):
                lines.append(f"日柱纳音：{lunar.getDayNaYin()}")
        except Exception:
            pass
        if gender:
            lines.append(f"性别：{gender}")
        return "\n".join(lines)
    except Exception as e:
        return f"排盘计算异常：{str(e)}"


def _split_gan_zhi(gz):
    """干支字符串拆为 (天干, 地支)，如 '辛巳' -> ('辛','巳')"""
    if not gz or len(gz) < 2:
        return "", ""
    return gz[0], gz[1]


# 天干 -> 五行（用于藏干显示 丙·火）
_GAN_WU_XING = {
    "甲": "木", "乙": "木", "丙": "火", "丁": "火", "戊": "土", "己": "土",
    "庚": "金", "辛": "金", "壬": "水", "癸": "水",
}


def _zang_gan_list(hide_gan_list):
    """藏干列表转为 ['丙·火','庚·金'] 格式"""
    if not hide_gan_list:
        return []
    return [f"{g}·{_GAN_WU_XING.get(g, '')}" for g in hide_gan_list if g]


def build_chart_json(solar_year, solar_month, solar_day, solar_hour, solar_minute, longitude, gender=""):
    """返回结构化排盘 JSON，供前端表格展示。使用 lunar_python 的 Lunar + EightChar 填满纳音、旬空、十神、藏干、地势、节气、神煞等。"""
    try:
        from lunar_python import Solar, Lunar
    except ImportError:
        return None
    try:
        from datetime import timedelta
        from datetime import datetime as dt
        offset_minutes = int(round((float(longitude) - 120.0) * 4.0))
        d = dt(solar_year, solar_month, solar_day, solar_hour, solar_minute or 0, 0)
        d = d + timedelta(minutes=offset_minutes)
        solar = Solar.fromYmdHms(d.year, d.month, d.day, d.hour, d.minute, 0)
        lunar = solar.getLunar()
        ec = lunar.getEightChar()

        ygz = lunar.getYearInGanZhi()
        mgz = lunar.getMonthInGanZhi()
        dgz = lunar.getDayInGanZhi()
        hgz = lunar.getTimeInGanZhi()
        yg, yz = _split_gan_zhi(ygz)
        mg, mz = _split_gan_zhi(mgz)
        dg, dz = _split_gan_zhi(dgz)
        hg, hz = _split_gan_zhi(hgz)

        true_solar_label = f"{d.year}年{d.month:02d}月{d.day:02d}日 {d.hour:02d}:{d.minute:02d}"
        solar_label = f"{solar_year}年{solar_month}月{solar_day}日 {solar_hour}时{solar_minute or 0}分"
        lunar_label = lunar.toString() if hasattr(lunar, "toString") else ""

        # 纳音（年/月/日/时）
        year_na_yin = (lunar.getYearNaYin() or "").strip()
        month_na_yin = (lunar.getMonthNaYin() or "").strip()
        day_na_yin = (lunar.getDayNaYin() or "").strip()
        hour_na_yin = (lunar.getTimeNaYin() or "").strip()

        # 旬空（空亡）
        year_kong = (lunar.getYearXunKong() or "").strip()
        month_kong = (lunar.getMonthXunKong() or "").strip()
        day_kong = (lunar.getDayXunKong() or "").strip()
        hour_kong = (lunar.getTimeXunKong() or "").strip()

        # 十神干（干神）
        shi_shen_gan = lunar.getBaZiShiShenGan() if hasattr(lunar, "getBaZiShiShenGan") else []
        if not isinstance(shi_shen_gan, list):
            shi_shen_gan = []
        gan_shen_list = [str(x).strip() for x in shi_shen_gan[:4]]
        while len(gan_shen_list) < 4:
            gan_shen_list.append("")

        # 十神支（支神）
        def _ss_zhi(fn):
            try:
                val = fn()
                return [str(x) for x in val] if isinstance(val, list) else []
            except Exception:
                return []

        year_shi_shen = _ss_zhi(lunar.getBaZiShiShenYearZhi) if hasattr(lunar, "getBaZiShiShenYearZhi") else []
        month_shi_shen = _ss_zhi(lunar.getBaZiShiShenMonthZhi) if hasattr(lunar, "getBaZiShiShenMonthZhi") else []
        day_shi_shen = _ss_zhi(lunar.getBaZiShiShenDayZhi) if hasattr(lunar, "getBaZiShiShenDayZhi") else []
        hour_shi_shen = _ss_zhi(lunar.getBaZiShiShenTimeZhi) if hasattr(lunar, "getBaZiShiShenTimeZhi") else []

        # 藏干（EightChar）
        def _hide_gan(fn):
            try:
                val = fn()
                return list(val) if val else []
            except Exception:
                return []

        year_zang = _zang_gan_list(_hide_gan(ec.getYearHideGan))
        month_zang = _zang_gan_list(_hide_gan(ec.getMonthHideGan))
        day_zang = _zang_gan_list(_hide_gan(ec.getDayHideGan))
        hour_zang = _zang_gan_list(_hide_gan(ec.getTimeHideGan))

        # 地势
        def _str(fn, default=""):
            try:
                v = fn()
                return str(v).strip() if v is not None else default
            except Exception:
                return default

        year_di_shi = _str(ec.getYearDiShi)
        month_di_shi = _str(ec.getMonthDiShi)
        day_di_shi = _str(ec.getDayDiShi)
        hour_di_shi = _str(ec.getTimeDiShi)

        # 自坐：此处用该柱地势（十二长生）作为自坐
        year_zi_zuo = year_di_shi
        month_zi_zuo = month_di_shi
        day_zi_zuo = day_di_shi
        hour_zi_zuo = hour_di_shi

        # 神煞：日柱用当日吉神+凶煞，年/月/时柱库无直接接口暂空
        day_ji_shen = _ss_zhi(lunar.getDayJiShen) if hasattr(lunar, "getDayJiShen") else []
        day_xiong_sha = _ss_zhi(lunar.getDayXiongSha) if hasattr(lunar, "getDayXiongSha") else []
        day_shen_sha = list(day_ji_shen) + list(day_xiong_sha)

        # 出生节气
        solar_term_label = None
        try:
            prev_jie = lunar.getPrevJie()
            if prev_jie is not None and hasattr(prev_jie, "getName"):
                jie_name = prev_jie.getName()
                jie_solar = getattr(prev_jie, "getSolar", lambda: None)()
                if jie_solar and jie_name:
                    jie_ymd = f"{jie_solar.getYear()}.{jie_solar.getMonth():02d}.{jie_solar.getDay():02d}"
                    try:
                        from datetime import date
                        jie_date = date(jie_solar.getYear(), jie_solar.getMonth(), jie_solar.getDay())
                        birth_date = date(d.year, d.month, d.day)
                        days_after = (birth_date - jie_date).days
                        solar_term_label = f"出生于{jie_name} ({jie_ymd}) 后{days_after}天"
                    except Exception:
                        solar_term_label = f"出生于{jie_name} ({jie_ymd}) 后"
        except Exception:
            pass

        def pillar(gan, zhi, na_yin, kong_wang, zang_gan, shi_shen, di_shi, zi_zuo, shen_sha, gan_shen):
            return {
                "gan": gan,
                "zhi": zhi,
                "zangGan": zang_gan,
                "shiShen": shi_shen,
                "naYin": na_yin,
                "kongWang": kong_wang,
                "diShi": di_shi,
                "ziZuo": zi_zuo,
                "shenSha": shen_sha,
                "ganShen": gan_shen,
            }

        def _format_item(x):
            try:
                if hasattr(x, "getGanZhi"):
                    return str(x.getGanZhi())
                if hasattr(x, "getName"):
                    return str(x.getName())
                if hasattr(x, "getYear"):
                    year = x.getYear()
                    if hasattr(x, "getGanZhi"):
                        return f"{year} {x.getGanZhi()}"
                    return str(year)
            except Exception:
                return str(x)
            return str(x)

        def _safe_list(fn):
            try:
                val = fn()
                if not val:
                    return None
                return [_format_item(x) for x in val]
            except Exception:
                return None

        def _safe_da_yun():
            try:
                yun = lunar.getYun() if hasattr(lunar, "getYun") else None
                if yun is None:
                    return None
                if hasattr(yun, "getDaYun"):
                    return [_format_item(x) for x in yun.getDaYun()]
                return None
            except Exception:
                return None

        # 胎元/命宫/身宫/大运/流年（来自 EightChar）
        tai_yuan = ec.getTaiYuan() if hasattr(ec, "getTaiYuan") else None
        ming_gong = ec.getMingGong() if hasattr(ec, "getMingGong") else None
        shen_gong = ec.getShenGong() if hasattr(ec, "getShenGong") else None

        gender_flag = 1 if str(gender).strip() == "男" else 0
        da_yun_list = None
        liu_nian_list = None
        try:
            if hasattr(ec, "getYun"):
                yun = ec.getYun(gender_flag, 1)
                if hasattr(yun, "getDaYun"):
                    da_yun = yun.getDaYun(10)
                    out = []
                    for item in da_yun:
                        start_year = getattr(item, "getStartYear", lambda: None)()
                        end_year = getattr(item, "getEndYear", lambda: None)()
                        start_age = getattr(item, "getStartAge", lambda: None)()
                        end_age = getattr(item, "getEndAge", lambda: None)()
                        gan_zhi = getattr(item, "getGanZhi", lambda: "")() or ""
                        core = f"{start_year}-{end_year}({start_age}-{end_age}岁)"
                        label = f"{core} {gan_zhi}".strip()
                        out.append(label)
                    da_yun_list = out

                    # 流年：取当前年份所在的大运，并从当前年起取 10 个
                    try:
                        from datetime import datetime as _dt
                        current_year = _dt.now().year
                        target = None
                        for item in da_yun:
                            s = getattr(item, "getStartYear", lambda: None)()
                            e = getattr(item, "getEndYear", lambda: None)()
                            if s is not None and e is not None and s <= current_year <= e:
                                target = item
                                break
                        if target and hasattr(target, "getLiuNian"):
                            ln = target.getLiuNian()
                            formatted = []
                            for x in ln:
                                y = getattr(x, "getYear", lambda: None)()
                                gz = getattr(x, "getGanZhi", lambda: "")() or ""
                                if y is None:
                                    continue
                                if y < current_year:
                                    continue
                                formatted.append(f"{y} {gz}".strip())
                            liu_nian_list = formatted[:10] if formatted else None
                    except Exception:
                        liu_nian_list = None
        except Exception:
            da_yun_list = None
            liu_nian_list = None

        return {
            "solarLabel": solar_label,
            "trueSolarLabel": true_solar_label,
            "lunarLabel": lunar_label,
            "solarTermLabel": solar_term_label,
            "yearPillar": pillar(yg, yz, year_na_yin, year_kong, year_zang, year_shi_shen, year_di_shi, year_zi_zuo, [], gan_shen_list[0]),
            "monthPillar": pillar(mg, mz, month_na_yin, month_kong, month_zang, month_shi_shen, month_di_shi, month_zi_zuo, [], gan_shen_list[1]),
            "dayPillar": pillar(dg, dz, day_na_yin, day_kong, day_zang, day_shi_shen, day_di_shi, day_zi_zuo, day_shen_sha, gan_shen_list[2]),
            "hourPillar": pillar(hg, hz, hour_na_yin, hour_kong, hour_zang, hour_shi_shen, hour_di_shi, hour_zi_zuo, [], gan_shen_list[3]),
            "ganRelationText": None,
            "gender": gender or None,
            "taiYuan": tai_yuan,
            "mingGong": ming_gong,
            "shenGong": shen_gong,
            "daYun": da_yun_list,
            "liuNian": liu_nian_list,
        }
    except Exception:
        return None


@app.post("/chart")
def chart():
    """根据公历出生时间与经度生成八字排盘。body: year, month, day, hour, minute, longitude, gender(可选)。返回 content(全文) 与 bazi(结构化，可选)。"""
    payload = request.get_json(silent=True) or {}
    year = payload.get("year")
    month = payload.get("month")
    day = payload.get("day")
    hour = payload.get("hour")
    minute = payload.get("minute", 0)
    longitude = payload.get("longitude", 120.0)
    gender = payload.get("gender", "")
    if year is None or month is None or day is None or hour is None:
        return jsonify({"error": "year, month, day, hour required"}), 400
    try:
        year, month, day = int(year), int(month), int(day)
        hour = int(hour)
        minute = int(minute) if minute is not None else 0
        longitude = float(longitude)
    except (TypeError, ValueError):
        return jsonify({"error": "invalid number"}), 400
    text = build_chart_text(year, month, day, hour, minute, longitude, gender)
    out = {"content": text}
    bazi = build_chart_json(year, month, day, hour, minute, longitude, gender)
    if bazi is not None:
        out["bazi"] = bazi
    return jsonify(out)


@app.post("/auth/sms/send")
def send_sms_code():
    payload = request.get_json(silent=True) or {}
    phone = (payload.get("phone") or "").strip()
    if not phone:
        return jsonify({"error": "phone required"}), 400
    code = f"{random.randint(0, 999999):06d}"
    expires_in = 300
    with get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO sms_codes (phone, code, expires_at)
                VALUES (%s, %s, now() + interval '5 minutes')
                """,
                (phone, code),
            )
    debug_code = code if os.getenv("SMS_DEBUG", "1") == "1" else None
    return jsonify({"ok": True, "expires_in": expires_in, "code": debug_code})


@app.post("/auth/sms/verify")
def verify_sms_code():
    payload = request.get_json(silent=True) or {}
    phone = (payload.get("phone") or "").strip()
    code = (payload.get("code") or "").strip()
    if not phone or not code:
        return jsonify({"error": "phone and code required"}), 400
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id FROM sms_codes
                WHERE phone = %s AND code = %s AND expires_at > now()
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (phone, code),
            )
            sms = cur.fetchone()
            if not sms:
                return jsonify({"error": "invalid code"}), 400
            cur.execute(
                """
                SELECT id, phone, nickname
                FROM users
                WHERE phone = %s
                """,
                (phone,),
            )
            user = cur.fetchone()
    if user:
        return jsonify({"ok": True, "user_exists": True, "user": {
            "id": str(user["id"]),
            "phone": user["phone"],
            "nickname": user["nickname"],
        }})
    return jsonify({"ok": True, "user_exists": False})


@app.post("/auth/login")
def login_with_password():
    payload = request.get_json(silent=True) or {}
    phone = (payload.get("phone") or "").strip()
    password = (payload.get("password") or "").strip()
    if not phone or not password:
        return jsonify({"error": "phone and password required"}), 400
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, phone, nickname, password_hash
                FROM users
                WHERE phone = %s
                """,
                (phone,),
            )
            user = cur.fetchone()
    if not user:
        return jsonify({"error": "user not found"}), 404
    if not _verify_password(password, user["password_hash"]):
        return jsonify({"error": "invalid password"}), 400
    return jsonify({"ok": True, "user": {
        "id": str(user["id"]),
        "phone": user["phone"],
        "nickname": user["nickname"],
    }})


@app.post("/auth/register")
def register_account():
    payload = request.get_json(silent=True) or {}
    phone = (payload.get("phone") or "").strip()
    nickname = (payload.get("nickname") or "").strip()
    password = (payload.get("password") or "").strip()
    if not phone or not nickname or not password:
        return jsonify({"error": "phone, nickname, password required"}), 400
    if len(password) < 6:
        return jsonify({"error": "password too short"}), 400
    password_hash = _hash_password(password)
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT id FROM users WHERE phone = %s", (phone,))
            existing = cur.fetchone()
            if existing:
                return jsonify({"error": "user already exists"}), 400
            cur.execute(
                """
                INSERT INTO users (phone, nickname, password_hash)
                VALUES (%s, %s, %s)
                RETURNING id, phone, nickname
                """,
                (phone, nickname, password_hash),
            )
            user = cur.fetchone()
    return jsonify({"ok": True, "user": {
        "id": str(user["id"]),
        "phone": user["phone"],
        "nickname": user["nickname"],
    }})


@app.post("/auth/password/reset")
def reset_password():
    payload = request.get_json(silent=True) or {}
    phone = (payload.get("phone") or "").strip()
    code = (payload.get("code") or "").strip()
    password = (payload.get("password") or "").strip()
    if not phone or not code or not password:
        return jsonify({"error": "phone, code, password required"}), 400
    if len(password) < 6:
        return jsonify({"error": "password too short"}), 400

    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id FROM sms_codes
                WHERE phone = %s AND code = %s AND expires_at > now()
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (phone, code),
            )
            sms = cur.fetchone()
            if not sms:
                return jsonify({"error": "invalid code"}), 400
            cur.execute(
                "SELECT id FROM users WHERE phone = %s",
                (phone,),
            )
            user = cur.fetchone()
            if not user:
                return jsonify({"error": "user not found"}), 404
            password_hash = _hash_password(password)
            cur.execute(
                """
                UPDATE users
                SET password_hash = %s, updated_at = now()
                WHERE phone = %s
                """,
                (password_hash, phone),
            )
    return jsonify({"ok": True})


def spark_chat(messages):
    ws_url = create_signed_url()
    if not ws_url:
        return "服务端未配置 Spark 凭证，请联系管理员。"

    payload = build_spark_payload(messages)
    ws = websocket.create_connection(ws_url, sslopt={"cert_reqs": ssl.CERT_NONE})
    try:
        ws.send(json.dumps(payload))
        response_text = ""
        while True:
            raw = ws.recv()
            if SPARK_DEBUG_RESPONSE:
                print("[spark_raw]", raw)
            data = json.loads(raw)
            header = data.get("header", {})
            if header.get("code", 0) != 0:
                raise RuntimeError(header.get("message", "spark error"))

            choices = data.get("payload", {}).get("choices", {})
            status = choices.get("status", 0)
            text_items = choices.get("text", [])
            if text_items:
                content = text_items[0].get("content", "")
                if content:
                    response_text += content

            if status == 2:
                break
        return response_text
    finally:
        ws.close()


def spark_title(text):
    prompt_messages = [
        {"role": "system", "content": SPARK_TITLE_PROMPT},
        {"role": "user", "content": text},
    ]
    title = spark_chat(prompt_messages)
    if "未配置 Spark 凭证" in title:
        return "新建聊天"
    return title.strip().strip("“”\"")


def spark_chat_stream(messages):
    ws_url = create_signed_url()
    if not ws_url:
        yield "服务端未配置 Spark 凭证，请联系管理员。"
        return

    payload = build_spark_payload(messages)
    ws = websocket.create_connection(ws_url, sslopt={"cert_reqs": ssl.CERT_NONE})
    try:
        ws.send(json.dumps(payload))
        while True:
            raw = ws.recv()
            if SPARK_DEBUG_RESPONSE:
                print("[spark_raw]", raw)
            data = json.loads(raw)
            header = data.get("header", {})
            if header.get("code", 0) != 0:
                raise RuntimeError(header.get("message", "spark error"))

            choices = data.get("payload", {}).get("choices", {})
            status = choices.get("status", 0)
            text_items = choices.get("text", [])
            if text_items:
                content = text_items[0].get("content", "")
                if content:
                    yield content

            if status == 2:
                break
    finally:
        ws.close()


@app.post("/spark/chat")
def chat():
    payload = request.get_json(silent=True) or {}
    messages = payload.get("messages", [])
    profile_id = payload.get("profileId")
    if not isinstance(messages, list) or not messages:
        return jsonify({"error": "messages required"}), 400
    try:
        profile = fetch_profile(profile_id) if profile_id else {}
        chat_messages = build_chat_messages(messages, profile)
        print(f"[chat] profileId={profile_id} profile_found={bool(profile)}")
        print(chat_messages)
        answer = spark_chat(chat_messages)
        return jsonify({"content": answer})
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": str(exc)}), 500


@app.post("/spark/chat/stream")
def chat_stream():
    payload = request.get_json(silent=True) or {}
    messages = payload.get("messages", [])
    profile_id = payload.get("profileId")
    if not isinstance(messages, list) or not messages:
        return jsonify({"error": "messages required"}), 400

    def generate():
        try:
            profile = fetch_profile(profile_id) if profile_id else {}
            chat_messages = build_chat_messages(messages, profile)
            print(f"[chat_stream] profileId={profile_id} profile_found={bool(profile)}")
            print(chat_messages)
            for chunk in spark_chat_stream(chat_messages):
                safe = chunk.replace("\r", "").replace("\n", "\\n")
                yield f"data: {safe}\n\n"
            yield "event: done\ndata: [DONE]\n\n"
        except Exception as exc:  # noqa: BLE001
            safe = str(exc).replace("\r", "").replace("\n", "\\n")
            yield f"event: error\ndata: {safe}\n\n"

    headers = {
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
    }
    return Response(stream_with_context(generate()), mimetype="text/event-stream", headers=headers)


@app.post("/spark/title")
def chat_title():
    payload = request.get_json(silent=True) or {}
    text = (payload.get("text") or "").strip()
    if not text:
        return jsonify({"error": "text required"}), 400
    try:
        title = spark_title(text)
        return jsonify({"title": title})
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": str(exc)}), 500


if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=8000, debug=False)
