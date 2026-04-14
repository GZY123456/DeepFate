import base64
import io
import hashlib
import hmac
import json
import math
import os
import random
import socket
import ssl
import statistics
import threading
import time
import uuid
from datetime import datetime, timezone
from time import mktime
from urllib.parse import urlencode, urlparse
from urllib.parse import quote
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo
from wsgiref.handlers import format_date_time
from flask import Flask, Response, jsonify, request, send_from_directory, stream_with_context
import websocket
import psycopg2
import psycopg2.extras
from dotenv import load_dotenv
from PIL import Image, ImageFilter, ImageStat

try:
    import mediapipe as mp
except Exception:  # noqa: BLE001
    mp = None

try:
    from palm_segmentation import palm_line_segmenter
except Exception as exc:  # noqa: BLE001
    palm_line_segmenter = None
    PALM_SEGMENTATION_IMPORT_ERROR = str(exc)
else:
    PALM_SEGMENTATION_IMPORT_ERROR = None

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

TIANSHI_SYSTEM_PROMPTS = {
    "sexy": """
你是 DeepFate 的「性感大师姐」。
你的表达风格：成熟、冷静、洞察力强，语气带一点锋芒和戏剧张力，但不能低俗、不能冒犯。
你的任务：结合用户问题、上下文和命理信息，给出清晰、可执行的建议。

输出要求：
1) 先给一句结论（吉/平/谨慎或趋势判断）。
2) 再给三段：原因判断、风险提示、行动建议。
3) 建议必须具体可执行，尽量给时间窗或优先级。
4) 回答简洁，默认 180-320 字；用户要求详细再展开。
5) 不编造用户未提供的事实；不确定时明确说明“基于当前信息推断”。

安全边界：
- 不提供医疗诊断、法律定论、投资保本承诺。
- 不鼓励极端行为、违法行为或人身伤害。
- 涉及高风险事项时，建议咨询专业人士。

现在时间：{time}
""".strip(),
    "soft": """
你是 DeepFate 的「软萌小师妹」。
你的表达风格：温柔、共情、耐心，像贴心陪伴者；语气亲和但不幼稚。
你的任务：结合用户问题、上下文和命理信息，给出安抚情绪且可执行的建议。

输出要求：
1) 先给一句温和结论（吉/平/谨慎或趋势判断）。
2) 再给三段：现状理解、关键提醒、下一步建议。
3) 建议要落地，优先给今天/本周可做的动作。
4) 回答简洁，默认 180-320 字；用户要求详细再展开。
5) 不编造用户未提供的事实；不确定时明确说明“基于当前信息推断”。

安全边界：
- 不提供医疗诊断、法律定论、投资保本承诺。
- 不鼓励极端行为、违法行为或人身伤害。
- 涉及高风险事项时，建议咨询专业人士。

现在时间：{time}
""".strip(),
}

SPARK_TITLE_PROMPT = "请基于用户的第一条消息生成一个不超过12个字的聊天标题，直接输出标题文本，不要加引号。"

APP_ID = os.getenv("SPARK_APP_ID", "")
API_KEY = os.getenv("SPARK_API_KEY", "")
API_SECRET = os.getenv("SPARK_API_SECRET", "")
SPARK_URL = os.getenv("SPARK_URL", "wss://spark-api.xf-yun.com/v1/x1")
SPARK_DOMAIN = os.getenv("SPARK_DOMAIN", "spark-x")
SPARK_SYSTEM_PROMPT = os.getenv("SPARK_SYSTEM_PROMPT", SPARK_SYSTEM_PROMPT)
SPARK_DEBUG_RESPONSE = os.getenv("SPARK_DEBUG_RESPONSE", "0") == "1"
AMAP_API_KEY = os.getenv("AMAP_API_KEY", "dcac0625f0725b9683338027fe890aa4")
AMAP_SECURITY_KEY = os.getenv("AMAP_SECURITY_KEY", "")
AMAP_PLACE_TEXT_URL = "https://restapi.amap.com/v5/place/text"
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"


app = Flask(__name__)
LOCATION_FILE = os.path.join(BASE_DIR, "locations.json")
PROFILE_FILE = os.path.join(BASE_DIR, "profiles.json")
UPLOAD_ROOT = os.path.join(BASE_DIR, "uploads")
PALMISTRY_UPLOAD_DIR = os.path.join(UPLOAD_ROOT, "palmistry")
os.makedirs(PALMISTRY_UPLOAD_DIR, exist_ok=True)

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
            cur.execute("ALTER TABLE profiles ADD COLUMN IF NOT EXISTS location_province text;")
            cur.execute("ALTER TABLE profiles ADD COLUMN IF NOT EXISTS location_city text;")
            cur.execute("ALTER TABLE profiles ADD COLUMN IF NOT EXISTS location_district text;")
            cur.execute("ALTER TABLE profiles ADD COLUMN IF NOT EXISTS location_detail text;")
            cur.execute("ALTER TABLE profiles ADD COLUMN IF NOT EXISTS latitude double precision;")
            cur.execute("ALTER TABLE profiles ADD COLUMN IF NOT EXISTS longitude double precision;")
            cur.execute("ALTER TABLE profiles ADD COLUMN IF NOT EXISTS timezone_id text;")
            cur.execute("ALTER TABLE profiles ADD COLUMN IF NOT EXISTS utc_offset_minutes integer;")
            cur.execute("ALTER TABLE profiles ADD COLUMN IF NOT EXISTS place_source text;")
            cur.execute("ALTER TABLE profiles ADD COLUMN IF NOT EXISTS location_adcode text;")
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
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS one_thing_divinations (
                    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                    profile_id uuid NOT NULL,
                    divination_date date NOT NULL,
                    question text NOT NULL,
                    started_at timestamptz NOT NULL,
                    ganzhi_year text NOT NULL,
                    ganzhi_month text NOT NULL,
                    ganzhi_day text NOT NULL,
                    ganzhi_hour text NOT NULL,
                    lunar_label text NOT NULL,
                    tosses jsonb NOT NULL,
                    lines jsonb NOT NULL,
                    primary_hexagram jsonb NOT NULL,
                    changed_hexagram jsonb NOT NULL,
                    moving_lines jsonb NOT NULL,
                    conclusion text NOT NULL,
                    summary text NOT NULL,
                    five_elements text NOT NULL,
                    advice text NOT NULL,
                    six_relatives jsonb NOT NULL,
                    created_at timestamptz DEFAULT now(),
                    UNIQUE (profile_id, divination_date)
                );
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS palm_readings (
                    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                    profile_id uuid NOT NULL,
                    hand_side text NOT NULL,
                    taken_at timestamptz NOT NULL,
                    original_image_path text NOT NULL,
                    thumbnail_path text NOT NULL,
                    structured jsonb NOT NULL,
                    overall text NOT NULL,
                    summary text NOT NULL,
                    life_line text NOT NULL,
                    head_line text NOT NULL,
                    heart_line text NOT NULL,
                    career text NOT NULL,
                    wealth text NOT NULL,
                    love text NOT NULL,
                    health text NOT NULL,
                    advice text NOT NULL,
                    source_pipeline text NOT NULL DEFAULT 'fallback',
                    created_at timestamptz DEFAULT now()
                );
                """
            )
            cur.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_palm_readings_profile_taken_at
                ON palm_readings (profile_id, taken_at DESC);
                """
            )
            cur.execute("ALTER TABLE palm_readings ADD COLUMN IF NOT EXISTS report_status text NOT NULL DEFAULT 'ready';")
            cur.execute("ALTER TABLE palm_readings ADD COLUMN IF NOT EXISTS report_error text;")
            cur.execute("ALTER TABLE palm_readings ADD COLUMN IF NOT EXISTS report_requested_at timestamptz;")
            cur.execute("ALTER TABLE palm_readings ADD COLUMN IF NOT EXISTS report_generated_at timestamptz;")
            cur.execute("UPDATE palm_readings SET report_status = 'ready' WHERE report_status IS NULL OR report_status = '';")
            cur.execute(
                """
                ALTER TABLE one_thing_divinations
                DROP CONSTRAINT IF EXISTS one_thing_divinations_profile_id_divination_date_key;
                """
            )
            cur.execute(
                """
                CREATE INDEX IF NOT EXISTS idx_one_thing_profile_started_at
                ON one_thing_divinations (profile_id, started_at DESC);
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


@app.get("/health")
def health():
    """健康检查：返回 200 表示服务在运行。"""
    return jsonify({"status": "ok"})


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


def _clean_text(value):
    if value is None:
        return ""
    return str(value).strip()


def _safe_float(value):
    try:
        if value in (None, ""):
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def resolve_timezone_id(province="", city="", district="", full_text=""):
    text = f"{_clean_text(province)}{_clean_text(city)}{_clean_text(district)}{_clean_text(full_text)}"
    if "香港" in text:
        return "Asia/Hong_Kong"
    if "澳门" in text:
        return "Asia/Macau"
    if "台湾" in text or "台北" in text or "高雄" in text:
        return "Asia/Taipei"
    return "Asia/Shanghai"


def compute_utc_offset_minutes(timezone_id, solar_text=None):
    tz = _clean_text(timezone_id)
    if not tz:
        return None
    try:
        if solar_text:
            dt = datetime.strptime(str(solar_text), "%Y-%m-%d %H:%M")
        else:
            dt = datetime.now()
        aware = dt.replace(tzinfo=ZoneInfo(tz))
        offset = aware.utcoffset()
        if offset is None:
            return None
        return int(offset.total_seconds() // 60)
    except Exception:
        return None


def build_location_text(province="", city="", district="", detail=""):
    parts = [_clean_text(province), _clean_text(city), _clean_text(district)]
    compact = "".join([part for part in parts if part])
    extra = _clean_text(detail)
    if compact and extra:
        return f"{compact} {extra}"
    return compact or extra


def amap_search_places(keyword, city="", limit=20):
    if not AMAP_API_KEY:
        raise RuntimeError("AMAP_API_KEY 未配置")
    q = _clean_text(keyword)
    if not q:
        return []
    page_size = max(1, min(int(limit), 20))
    params = {
        "key": AMAP_API_KEY,
        "keywords": q,
        "region": "全国",
        "city": _clean_text(city),
        "city_limit": "false",
        "show_fields": "business",
        "page_size": page_size,
        "page_num": 1,
    }
    payload = call_amap_place_api(params)
    if payload.get("status") != "1":
        raise RuntimeError(payload.get("info", "高德地点检索失败"))
    items = []
    for poi in payload.get("pois") or []:
        location = _clean_text(poi.get("location"))
        if "," not in location:
            continue
        lng_str, lat_str = location.split(",", 1)
        longitude = _safe_float(lng_str)
        latitude = _safe_float(lat_str)
        if longitude is None or latitude is None:
            continue
        province = _clean_text(poi.get("pname"))
        city_name = poi.get("cityname")
        if isinstance(city_name, list):
            city_name = city_name[0] if city_name else ""
        city_name = _clean_text(city_name)
        district = _clean_text(poi.get("adname"))
        detail = _clean_text(poi.get("address"))
        poi_name = _clean_text(poi.get("name"))
        full_address = build_location_text(province, city_name, district, detail) or poi_name
        timezone_id = resolve_timezone_id(province, city_name, district, full_address)
        items.append(
            {
                "name": poi_name,
                "province": province,
                "city": city_name,
                "district": district,
                "detailAddress": detail,
                "fullAddress": full_address,
                "longitude": longitude,
                "latitude": latitude,
                "adcode": _clean_text(poi.get("adcode")),
                "timezoneId": timezone_id,
                "utcOffsetMinutes": compute_utc_offset_minutes(timezone_id),
                "source": "amap",
            }
        )
    return items


def call_amap_place_api(params):
    # 高德 Web 服务可配置“数字签名校验”，开启后必须带 sig。
    # 同时做兜底：签名失败时再尝试无 sig，兼容未开启校验的 key。
    variants = [True, False] if AMAP_SECURITY_KEY else [False]
    last_payload = None
    for use_sig in variants:
        query_params = dict(params)
        if use_sig:
            query_params["sig"] = build_amap_sig(query_params)
        query = urlencode(query_params, quote_via=quote)
        url = f"{AMAP_PLACE_TEXT_URL}?{query}"
        with urlopen(url, timeout=8) as resp:
            raw = resp.read().decode("utf-8")
        payload = json.loads(raw)
        last_payload = payload
        if payload.get("status") == "1":
            return payload
    return last_payload or {}


def build_amap_sig(params):
    pairs = []
    for key in sorted(params.keys()):
        value = params.get(key)
        if value in (None, ""):
            continue
        pairs.append(f"{key}={value}")
    raw = "&".join(pairs) + AMAP_SECURITY_KEY
    return hashlib.md5(raw.encode("utf-8")).hexdigest()


def nominatim_search_places(keyword, limit=20):
    q = _clean_text(keyword)
    if not q:
        return []
    params = {
        "q": q,
        "format": "jsonv2",
        "addressdetails": 1,
        "limit": max(1, min(int(limit), 20)),
    }
    req = Request(
        f"{NOMINATIM_URL}?{urlencode(params, quote_via=quote)}",
        headers={"User-Agent": "DeepFate/1.0"},
    )
    with urlopen(req, timeout=8) as resp:
        raw = resp.read().decode("utf-8")
    payload = json.loads(raw)
    items = []
    for entry in payload if isinstance(payload, list) else []:
        longitude = _safe_float(entry.get("lon"))
        latitude = _safe_float(entry.get("lat"))
        if longitude is None or latitude is None:
            continue
        address = entry.get("address") or {}
        province = _clean_text(address.get("state") or address.get("province"))
        city = _clean_text(address.get("city") or address.get("town") or address.get("county"))
        district = _clean_text(address.get("county") or address.get("suburb"))
        detail = _clean_text(address.get("road"))
        full_address = _clean_text(entry.get("display_name"))
        timezone_id = resolve_timezone_id(province, city, district, full_address)
        items.append(
            {
                "name": _clean_text(address.get("city_district") or address.get("suburb") or city),
                "province": province,
                "city": city,
                "district": district,
                "detailAddress": detail,
                "fullAddress": full_address,
                "longitude": longitude,
                "latitude": latitude,
                "adcode": "",
                "timezoneId": timezone_id,
                "utcOffsetMinutes": compute_utc_offset_minutes(timezone_id),
                "source": "nominatim",
            }
        )
    return items


def search_places(keyword, city="", limit=20):
    try:
        items = amap_search_places(keyword, city=city, limit=limit)
        if items:
            return items
    except Exception as exc:
        print(f"[geo] amap search failed: {exc}")
    try:
        return nominatim_search_places(keyword, limit=limit)
    except Exception as exc:
        print(f"[geo] fallback search failed: {exc}")
        return []


def enrich_location_payload(payload):
    province = _clean_text(payload.get("locationProvince"))
    city = _clean_text(payload.get("locationCity"))
    district = _clean_text(payload.get("locationDistrict"))
    detail = _clean_text(payload.get("locationDetail"))
    longitude = _safe_float(payload.get("longitude"))
    latitude = _safe_float(payload.get("latitude"))
    timezone_id = _clean_text(payload.get("timezoneId"))
    utc_offset = payload.get("utcOffsetMinutes")
    if utc_offset in ("", None):
        utc_offset = None
    else:
        try:
            utc_offset = int(utc_offset)
        except (TypeError, ValueError):
            utc_offset = None
    source = _clean_text(payload.get("placeSource")) or "manual"
    adcode = _clean_text(payload.get("locationAdcode"))
    location_text = _clean_text(payload.get("location"))
    solar_text = _clean_text(payload.get("solar"))

    if (not province or longitude is None or latitude is None) and location_text:
        candidates = search_places(location_text, limit=1)
        if candidates:
            first = candidates[0]
            province = province or _clean_text(first.get("province"))
            city = city or _clean_text(first.get("city"))
            district = district or _clean_text(first.get("district"))
            detail = detail or _clean_text(first.get("detailAddress"))
            longitude = longitude if longitude is not None else _safe_float(first.get("longitude"))
            latitude = latitude if latitude is not None else _safe_float(first.get("latitude"))
            timezone_id = timezone_id or _clean_text(first.get("timezoneId"))
            adcode = adcode or _clean_text(first.get("adcode"))
            source = _clean_text(first.get("source")) or source

    if not location_text:
        location_text = build_location_text(province, city, district, detail)

    if not timezone_id:
        timezone_id = resolve_timezone_id(province, city, district, location_text)
    if utc_offset is None:
        utc_offset = compute_utc_offset_minutes(timezone_id, solar_text)

    return {
        "location": location_text,
        "location_province": province,
        "location_city": city,
        "location_district": district,
        "location_detail": detail,
        "longitude": longitude,
        "latitude": latitude,
        "timezone_id": timezone_id,
        "utc_offset_minutes": utc_offset,
        "place_source": source,
        "location_adcode": adcode,
    }


def backfill_profile_locations():
    if not AMAP_API_KEY:
        print("[profiles] skip location backfill: AMAP_API_KEY missing")
        return
    try:
        with get_db_conn() as conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute(
                    """
                    SELECT id, location, solar, location_province, location_city, location_district,
                           location_detail, latitude, longitude, timezone_id, utc_offset_minutes,
                           place_source, location_adcode
                    FROM profiles
                    WHERE (location_province IS NULL OR location_province = '')
                       OR latitude IS NULL
                       OR longitude IS NULL
                       OR timezone_id IS NULL
                    ORDER BY created_at DESC
                    LIMIT 200
                    """
                )
                rows = cur.fetchall()
                updated = 0
                for row in rows:
                    enriched = enrich_location_payload(
                        {
                            "location": row.get("location", ""),
                            "solar": row.get("solar", ""),
                            "locationProvince": row.get("location_province", ""),
                            "locationCity": row.get("location_city", ""),
                            "locationDistrict": row.get("location_district", ""),
                            "locationDetail": row.get("location_detail", ""),
                            "latitude": row.get("latitude"),
                            "longitude": row.get("longitude"),
                            "timezoneId": row.get("timezone_id", ""),
                            "utcOffsetMinutes": row.get("utc_offset_minutes"),
                            "placeSource": row.get("place_source", ""),
                            "locationAdcode": row.get("location_adcode", ""),
                        }
                    )
                    if not enriched.get("location") and enriched.get("longitude") is None:
                        continue
                    cur.execute(
                        """
                        UPDATE profiles
                        SET location = COALESCE(NULLIF(location, ''), %s),
                            location_province = COALESCE(NULLIF(location_province, ''), %s),
                            location_city = COALESCE(NULLIF(location_city, ''), %s),
                            location_district = COALESCE(NULLIF(location_district, ''), %s),
                            location_detail = COALESCE(NULLIF(location_detail, ''), %s),
                            latitude = COALESCE(latitude, %s),
                            longitude = COALESCE(longitude, %s),
                            timezone_id = COALESCE(NULLIF(timezone_id, ''), %s),
                            utc_offset_minutes = COALESCE(utc_offset_minutes, %s),
                            place_source = COALESCE(NULLIF(place_source, ''), %s),
                            location_adcode = COALESCE(NULLIF(location_adcode, ''), %s),
                            updated_at = now()
                        WHERE id = %s
                        """,
                        (
                            enriched["location"],
                            enriched["location_province"],
                            enriched["location_city"],
                            enriched["location_district"],
                            enriched["location_detail"],
                            enriched["latitude"],
                            enriched["longitude"],
                            enriched["timezone_id"],
                            enriched["utc_offset_minutes"],
                            enriched["place_source"],
                            enriched["location_adcode"],
                            str(row["id"]),
                        ),
                    )
                    updated += 1
        print(f"[profiles] location backfill finished, updated={updated}")
    except Exception as exc:
        print(f"[profiles] location backfill failed: {exc}")


@app.get("/geo/search")
def geo_search():
    keyword = request.args.get("q") or request.args.get("keyword") or ""
    city = request.args.get("city", "")
    try:
        limit = int(request.args.get("limit", "20"))
    except ValueError:
        limit = 20
    limit = max(1, min(limit, 20))
    keyword = _clean_text(keyword)
    if not keyword:
        return jsonify({"error": "q required"}), 400
    items = search_places(keyword, city=city, limit=limit)
    if items:
        return jsonify({"items": items})
    return jsonify({"items": [], "error": "no location results"}), 200


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
    location_detail = profile.get("locationDetail", "")
    solar = profile.get("solar", "")
    lunar = profile.get("lunar", "")
    true_solar = profile.get("trueSolar", "")
    longitude = profile.get("longitude", "")
    latitude = profile.get("latitude", "")
    if not any([name, gender, location, location_detail, solar, lunar, true_solar]):
        return ""
    location_line = location
    if location_detail and location_detail not in location:
        location_line = f"{location} {location_detail}".strip()
    return (
        "用户档案信息（结构化）：\n"
        f"- 姓名：{name}\n"
        f"- 性别：{gender}\n"
        f"- 出生地：{location_line}\n"
        f"- 坐标：经度{longitude}，纬度{latitude}\n"
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


_TRIGRAM_BY_BITS = {
    "111": {"name": "乾", "element": "金"},
    "110": {"name": "兑", "element": "金"},
    "101": {"name": "离", "element": "火"},
    "100": {"name": "震", "element": "木"},
    "011": {"name": "巽", "element": "木"},
    "010": {"name": "坎", "element": "水"},
    "001": {"name": "艮", "element": "土"},
    "000": {"name": "坤", "element": "土"},
}

_HEXAGRAM_BY_TRIGRAM = {
    ("乾", "乾"): (1, "乾为天"),
    ("坤", "坤"): (2, "坤为地"),
    ("坎", "震"): (3, "水雷屯"),
    ("艮", "坎"): (4, "山水蒙"),
    ("坎", "乾"): (5, "水天需"),
    ("乾", "坎"): (6, "天水讼"),
    ("坤", "坎"): (7, "地水师"),
    ("坎", "坤"): (8, "水地比"),
    ("巽", "乾"): (9, "风天小畜"),
    ("乾", "兑"): (10, "天泽履"),
    ("坤", "乾"): (11, "地天泰"),
    ("乾", "坤"): (12, "天地否"),
    ("乾", "离"): (13, "天火同人"),
    ("离", "乾"): (14, "火天大有"),
    ("坤", "艮"): (15, "地山谦"),
    ("震", "坤"): (16, "雷地豫"),
    ("兑", "震"): (17, "泽雷随"),
    ("艮", "巽"): (18, "山风蛊"),
    ("坤", "兑"): (19, "地泽临"),
    ("巽", "坤"): (20, "风地观"),
    ("离", "震"): (21, "火雷噬嗑"),
    ("艮", "离"): (22, "山火贲"),
    ("艮", "坤"): (23, "山地剥"),
    ("坤", "震"): (24, "地雷复"),
    ("乾", "震"): (25, "天雷无妄"),
    ("艮", "乾"): (26, "山天大畜"),
    ("艮", "震"): (27, "山雷颐"),
    ("兑", "巽"): (28, "泽风大过"),
    ("坎", "坎"): (29, "坎为水"),
    ("离", "离"): (30, "离为火"),
    ("兑", "艮"): (31, "泽山咸"),
    ("震", "巽"): (32, "雷风恒"),
    ("乾", "艮"): (33, "天山遁"),
    ("震", "乾"): (34, "雷天大壮"),
    ("离", "坤"): (35, "火地晋"),
    ("坤", "离"): (36, "地火明夷"),
    ("巽", "离"): (37, "风火家人"),
    ("离", "兑"): (38, "火泽睽"),
    ("坎", "艮"): (39, "水山蹇"),
    ("震", "坎"): (40, "雷水解"),
    ("艮", "兑"): (41, "山泽损"),
    ("巽", "震"): (42, "风雷益"),
    ("兑", "乾"): (43, "泽天夬"),
    ("乾", "巽"): (44, "天风姤"),
    ("兑", "坤"): (45, "泽地萃"),
    ("坤", "巽"): (46, "地风升"),
    ("兑", "坎"): (47, "泽水困"),
    ("坎", "巽"): (48, "水风井"),
    ("兑", "离"): (49, "泽火革"),
    ("离", "巽"): (50, "火风鼎"),
    ("震", "震"): (51, "震为雷"),
    ("艮", "艮"): (52, "艮为山"),
    ("巽", "艮"): (53, "风山渐"),
    ("震", "兑"): (54, "雷泽归妹"),
    ("震", "离"): (55, "雷火丰"),
    ("离", "艮"): (56, "火山旅"),
    ("巽", "巽"): (57, "巽为风"),
    ("兑", "兑"): (58, "兑为泽"),
    ("巽", "坎"): (59, "风水涣"),
    ("坎", "兑"): (60, "水泽节"),
    ("巽", "兑"): (61, "风泽中孚"),
    ("震", "艮"): (62, "雷山小过"),
    ("坎", "离"): (63, "水火既济"),
    ("离", "坎"): (64, "火水未济"),
}

_ELEMENT_GENERATES = {"木": "火", "火": "土", "土": "金", "金": "水", "水": "木"}
_ELEMENT_CONTROLS = {"木": "土", "土": "水", "水": "火", "火": "金", "金": "木"}
_VALID_SIX_RELATIVE_ROLES = {"兄弟", "父母", "子孙", "妻财", "官鬼"}


def _parse_iso_datetime(raw_value):
    raw = _clean_text(raw_value)
    if not raw:
        return datetime.now(timezone.utc)
    try:
        if raw.endswith("Z"):
            raw = raw[:-1] + "+00:00"
        parsed = datetime.fromisoformat(raw)
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=timezone.utc)
        return parsed
    except Exception:
        return datetime.now(timezone.utc)


def _normalize_coin_face(value):
    text = _clean_text(value).lower()
    if text in {"正", "阳", "heads", "head", "h", "1", "true"}:
        return "正"
    if text in {"反", "阴", "tails", "tail", "t", "0", "false"}:
        return "反"
    return "正" if random.random() >= 0.5 else "反"


def _normalize_tosses(raw_tosses):
    if not isinstance(raw_tosses, list):
        return None
    out = []
    for item in raw_tosses:
        if isinstance(item, dict):
            coins = item.get("coins")
        else:
            coins = item
        if not isinstance(coins, list) or len(coins) != 3:
            return None
        out.append([_normalize_coin_face(face) for face in coins])
    if len(out) != 6:
        return None
    return out


def _coins_to_line(coins, line_no):
    front_count = sum(1 for coin in coins if coin == "正")
    back_count = 3 - front_count
    # 官方常见口径：正(字面)=2，反(背面)=3
    total = front_count * 2 + back_count * 3
    line_type_map = {6: "老阴", 7: "少阳", 8: "少阴", 9: "老阳"}
    line_type = line_type_map.get(total, "少阴")
    is_yang = total in (7, 9)
    is_moving = total in (6, 9)
    changed_is_yang = (not is_yang) if is_moving else is_yang
    return {
        "line": int(line_no),  # 1=初爻（最下），6=上爻（最上）
        "coins": list(coins),
        "sum": int(total),
        "type": line_type,
        "isYang": bool(is_yang),
        "isMoving": bool(is_moving),
        "changedIsYang": bool(changed_is_yang),
    }


def _line_symbol(is_yang):
    return "────────" if is_yang else "────  ────"


def _bits_to_trigram(bits):
    key = "".join("1" if b else "0" for b in bits)
    return _TRIGRAM_BY_BITS.get(key, {"name": "坤", "element": "土"})


def _build_hexagram(lines_yang):
    lower = _bits_to_trigram(lines_yang[:3])
    upper = _bits_to_trigram(lines_yang[3:6])
    number, name = _HEXAGRAM_BY_TRIGRAM.get((upper["name"], lower["name"]), (0, f"{upper['name']}{lower['name']}"))
    top_down_bits = list(reversed(lines_yang))
    return {
        "number": number,
        "name": name,
        "upperTrigram": upper["name"],
        "upperElement": upper["element"],
        "lowerTrigram": lower["name"],
        "lowerElement": lower["element"],
        "linePattern": ["阳" if bit else "阴" for bit in top_down_bits],
        "lineSymbols": [_line_symbol(bit) for bit in top_down_bits],
    }


def _six_relative_role(day_element, line_element):
    if not day_element or not line_element:
        return "兄弟"
    if day_element == line_element:
        return "兄弟"
    if _ELEMENT_GENERATES.get(line_element) == day_element:
        return "父母"
    if _ELEMENT_GENERATES.get(day_element) == line_element:
        return "子孙"
    if _ELEMENT_CONTROLS.get(day_element) == line_element:
        return "妻财"
    if _ELEMENT_CONTROLS.get(line_element) == day_element:
        return "官鬼"
    return "兄弟"


def _build_six_relatives(lines, day_gan, primary_hexagram):
    day_element = _GAN_WU_XING.get(day_gan, "")
    upper_element = primary_hexagram.get("upperElement", "")
    lower_element = primary_hexagram.get("lowerElement", "")
    result = []
    for line in lines:
        line_no = int(line.get("line", 0))
        line_element = lower_element if line_no <= 3 else upper_element
        role = _six_relative_role(day_element, line_element)
        result.append(
            {
                "line": line_no,
                "role": role,
                "element": line_element,
                "yinYang": "阳" if line.get("isYang") else "阴",
                "moving": bool(line.get("isMoving")),
                "note": "",
            }
        )
    result.sort(key=lambda item: item["line"], reverse=True)
    return result


def _merge_six_relatives(base_items, llm_items):
    if not isinstance(base_items, list):
        return []
    if not isinstance(llm_items, list):
        return base_items

    llm_map = {}
    for item in llm_items:
        if not isinstance(item, dict):
            continue
        line_no = item.get("line")
        try:
            line_no = int(line_no)
        except (TypeError, ValueError):
            continue
        llm_map[line_no] = item

    merged = []
    for base in base_items:
        line_no = int(base.get("line", 0))
        llm = llm_map.get(line_no, {})
        role = _clean_text(llm.get("role"))
        note = _clean_text(llm.get("note"))
        updated = dict(base)
        if role in _VALID_SIX_RELATIVE_ROLES:
            updated["role"] = role
        if note:
            updated["note"] = note
        merged.append(updated)
    return merged


def build_liuyao_prompt(question, gan_zhi, primary_hexagram, changed_hexagram, lines, six_relatives):
    line_text = []
    for line in sorted(lines, key=lambda item: item["line"], reverse=True):
        marker = "动" if line.get("isMoving") else "静"
        line_text.append(
            f"- 第{line['line']}爻：{line['type']}（{''.join(line['coins'])}，和值{line['sum']}，{marker}）"
        )

    relative_text = []
    for item in six_relatives:
        relative_text.append(
            f"- 第{item['line']}爻：{item['role']}（五行{item['element']}，{item['yinYang']}爻）"
        )

    return (
        "你是资深六爻占断师。请依据下列已确定的排卦信息，给出结构化解读。\n"
        "仅输出严格 JSON，不要输出任何解释文字、不要 markdown。\n"
        "JSON 格式：\n"
        "{\"conclusion\":\"吉|平|凶\",\"summary\":\"...\",\"fiveElements\":\"...\",\"advice\":\"...\","
        "\"sixRelatives\":[{\"line\":6,\"role\":\"父母|兄弟|子孙|妻财|官鬼\",\"note\":\"...\"}]}\n"
        "要求：\n"
        "- summary 40~90 字，先给结论导向。\n"
        "- fiveElements 120~220 字，围绕旺衰、生克、动爻影响。\n"
        "- advice 80~160 字，给可执行建议。\n"
        "- sixRelatives 必须 6 条，line 用 6 到 1。\n"
        "- 保持语言专业但简洁。\n\n"
        f"用户问题：{question}\n"
        f"起卦干支：年{gan_zhi['year']} 月{gan_zhi['month']} 日{gan_zhi['day']} 时{gan_zhi['hour']}\n"
        f"农历：{gan_zhi['lunarLabel']}\n"
        f"本卦：{primary_hexagram['name']}（{primary_hexagram['upperTrigram']}上{primary_hexagram['lowerTrigram']}下）\n"
        f"变卦：{changed_hexagram['name']}（{changed_hexagram['upperTrigram']}上{changed_hexagram['lowerTrigram']}下）\n"
        "六爻结果（上爻到初爻）：\n"
        + "\n".join(line_text)
        + "\n六亲基础排布（上爻到初爻）：\n"
        + "\n".join(relative_text)
    )


def parse_liuyao_response(text):
    if not text:
        return None
    raw = text.strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass
    start = raw.find("{")
    end = raw.rfind("}")
    if start >= 0 and end > start:
        snippet = raw[start:end + 1]
        try:
            return json.loads(snippet)
        except json.JSONDecodeError:
            return None
    return None


def _default_liuyao_analysis(question, primary_hexagram, changed_hexagram, moving_lines):
    moving_count = len(moving_lines)
    if moving_count <= 1:
        conclusion = "平"
    elif moving_count <= 3:
        conclusion = "吉"
    else:
        conclusion = "凶"
    summary = (
        f"此卦显示为{conclusion}势，"
        f"本卦{primary_hexagram['name']}转{changed_hexagram['name']}，"
        "宜顺势而行，避免急进。"
    )
    five_elements = (
        "起卦以当下干支为时空气机，动爻代表事件中的变化节点。"
        "本卦看现状根基，变卦看后续趋势；动爻越多，外部扰动越大。"
        "建议先稳住核心资源，再根据变化节奏逐步推进。"
    )
    advice = (
        "先确定一个可执行的小目标并在三日内落地。"
        "若中途出现反复，以既定节奏为主，不轻易改方向。"
        "涉及合作与承诺时，先书面确认关键条件。"
    )
    return {
        "conclusion": conclusion,
        "summary": summary,
        "fiveElements": five_elements,
        "advice": advice,
        "sixRelatives": [],
    }


def _to_started_at_text(started_at, timezone_id):
    if started_at is None:
        return ""
    try:
        zone = ZoneInfo(timezone_id or "Asia/Shanghai")
    except Exception:
        zone = ZoneInfo("Asia/Shanghai")
    try:
        local_dt = started_at.astimezone(zone)
    except Exception:
        local_dt = started_at
    return local_dt.strftime("%Y-%m-%d %H:%M")


def _to_one_thing_payload(row, timezone_id):
    if not row:
        return None
    started_at = row.get("started_at")
    started_at_text = _to_started_at_text(started_at, timezone_id)
    started_at_iso = started_at.isoformat() if started_at else ""
    return {
        "id": str(row.get("id", "")),
        "date": str(row.get("divination_date", "")),
        "question": row.get("question", ""),
        "startedAt": started_at_text,
        "startedAtISO": started_at_iso,
        "ganZhi": {
            "year": row.get("ganzhi_year", ""),
            "month": row.get("ganzhi_month", ""),
            "day": row.get("ganzhi_day", ""),
            "hour": row.get("ganzhi_hour", ""),
            "lunarLabel": row.get("lunar_label", ""),
        },
        "tosses": row.get("tosses") or [],
        "lines": row.get("lines") or [],
        "hexagram": {
            "primary": row.get("primary_hexagram") or {},
            "changed": row.get("changed_hexagram") or {},
            "movingLines": row.get("moving_lines") or [],
        },
        "analysis": {
            "conclusion": row.get("conclusion", ""),
            "summary": row.get("summary", ""),
            "fiveElements": row.get("five_elements", ""),
            "advice": row.get("advice", ""),
            "sixRelatives": row.get("six_relatives") or [],
        },
    }


def fetch_one_thing_divination_by_date(profile_id, divination_date, timezone_id="Asia/Shanghai"):
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, divination_date, question, started_at,
                       ganzhi_year, ganzhi_month, ganzhi_day, ganzhi_hour, lunar_label,
                       tosses, lines, primary_hexagram, changed_hexagram, moving_lines,
                       conclusion, summary, five_elements, advice, six_relatives
                FROM one_thing_divinations
                WHERE profile_id = %s AND divination_date = %s
                ORDER BY started_at DESC, created_at DESC
                LIMIT 1
                """,
                (str(profile_id), divination_date),
            )
            row = cur.fetchone()
    return _to_one_thing_payload(row, timezone_id)


def fetch_one_thing_divination_latest(profile_id, timezone_id="Asia/Shanghai"):
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, divination_date, question, started_at,
                       ganzhi_year, ganzhi_month, ganzhi_day, ganzhi_hour, lunar_label,
                       tosses, lines, primary_hexagram, changed_hexagram, moving_lines,
                       conclusion, summary, five_elements, advice, six_relatives
                FROM one_thing_divinations
                WHERE profile_id = %s
                ORDER BY started_at DESC, created_at DESC
                LIMIT 1
                """,
                (str(profile_id),),
            )
            row = cur.fetchone()
    return _to_one_thing_payload(row, timezone_id)


def fetch_one_thing_divination_by_id(profile_id, row_id, timezone_id="Asia/Shanghai"):
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, divination_date, question, started_at,
                       ganzhi_year, ganzhi_month, ganzhi_day, ganzhi_hour, lunar_label,
                       tosses, lines, primary_hexagram, changed_hexagram, moving_lines,
                       conclusion, summary, five_elements, advice, six_relatives
                FROM one_thing_divinations
                WHERE profile_id = %s AND id = %s
                LIMIT 1
                """,
                (str(profile_id), str(row_id)),
            )
            row = cur.fetchone()
    return _to_one_thing_payload(row, timezone_id)


def delete_one_thing_divination(profile_id, row_id):
    with get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                DELETE FROM one_thing_divinations
                WHERE profile_id = %s AND id = %s
                """,
                (str(profile_id), str(row_id)),
            )
            return cur.rowcount > 0


def list_one_thing_history(profile_id, timezone_id="Asia/Shanghai", limit=30):
    n = max(1, min(int(limit), 100))
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, divination_date, question, started_at,
                       conclusion, primary_hexagram, changed_hexagram
                FROM one_thing_divinations
                WHERE profile_id = %s
                ORDER BY started_at DESC, created_at DESC
                LIMIT %s
                """,
                (str(profile_id), n),
            )
            rows = cur.fetchall()
    result = []
    for row in rows:
        primary_hex = row.get("primary_hexagram") or {}
        changed_hex = row.get("changed_hexagram") or {}
        result.append(
            {
                "id": str(row.get("id", "")),
                "date": str(row.get("divination_date", "")),
                "startedAt": _to_started_at_text(row.get("started_at"), timezone_id),
                "question": row.get("question", ""),
                "conclusion": row.get("conclusion", ""),
                "primaryName": primary_hex.get("name", ""),
                "changedName": changed_hex.get("name", ""),
            }
        )
    return result


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


def _decode_base64_image(raw_value):
    text = _clean_text(raw_value)
    if not text:
        return None
    if text.startswith("data:") and "," in text:
        text = text.split(",", 1)[1]
    try:
        return base64.b64decode(text)
    except Exception:
        return None


def _save_palmistry_images(image_bytes):
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    reading_id = str(uuid.uuid4())
    original_name = f"{reading_id}.jpg"
    thumb_name = f"{reading_id}_thumb.jpg"
    image.save(os.path.join(PALMISTRY_UPLOAD_DIR, original_name), format="JPEG", quality=90, optimize=True)
    thumb = image.copy()
    thumb.thumbnail((720, 720))
    thumb.save(os.path.join(PALMISTRY_UPLOAD_DIR, thumb_name), format="JPEG", quality=80, optimize=True)
    return reading_id, original_name, thumb_name, image


def _distance(a, b):
    if not a or not b:
        return 0.0
    return math.sqrt((a["x"] - b["x"]) ** 2 + (a["y"] - b["y"]) ** 2)


def _classify_band(value, low_cut, high_cut, low_label, mid_label, high_label):
    if value < low_cut:
        return low_label
    if value > high_cut:
        return high_label
    return mid_label


def _extract_landmark_point(landmarks, key):
    item = landmarks.get(key)
    if not isinstance(item, dict):
        return None
    try:
        return {
            "x": float(item.get("x")),
            "y": float(item.get("y")),
            "confidence": float(item.get("confidence", 0)),
        }
    except Exception:
        return None


def _extract_palmistry_from_landmarks(landmarks):
    if not isinstance(landmarks, dict) or not landmarks:
        return None

    wrist = _extract_landmark_point(landmarks, "VNHLKWrist")
    index_mcp = _extract_landmark_point(landmarks, "VNHLKIndexMCP")
    middle_mcp = _extract_landmark_point(landmarks, "VNHLKMiddleMCP")
    ring_mcp = _extract_landmark_point(landmarks, "VNHLKRingMCP")
    little_mcp = _extract_landmark_point(landmarks, "VNHLKLittleMCP")
    thumb_tip = _extract_landmark_point(landmarks, "VNHLKThumbTip")
    index_tip = _extract_landmark_point(landmarks, "VNHLKIndexTip")
    middle_tip = _extract_landmark_point(landmarks, "VNHLKMiddleTip")
    ring_tip = _extract_landmark_point(landmarks, "VNHLKRingTip")
    little_tip = _extract_landmark_point(landmarks, "VNHLKLittleTip")

    required = [wrist, index_mcp, middle_mcp, ring_mcp, little_mcp, thumb_tip, index_tip, middle_tip, ring_tip, little_tip]
    if any(point is None for point in required):
        return None

    palm_width = max(_distance(index_mcp, little_mcp), 0.001)
    palm_height = max(_distance(wrist, middle_mcp), 0.001)
    aspect_ratio = palm_height / palm_width
    tip_xs = [index_tip["x"], middle_tip["x"], ring_tip["x"], little_tip["x"]]
    finger_spread_ratio = max(0.0, max(tip_xs) - min(tip_xs)) / palm_width
    thumb_open_ratio = abs(thumb_tip["x"] - index_mcp["x"]) / palm_width
    finger_lengths = [
        _distance(index_tip, index_mcp) / palm_height,
        _distance(middle_tip, middle_mcp) / palm_height,
        _distance(ring_tip, ring_mcp) / palm_height,
        _distance(little_tip, little_mcp) / palm_height,
    ]
    mean_finger_length = statistics.mean(finger_lengths)
    clarity_seed = statistics.mean(point["confidence"] for point in required)

    palm_shape = _classify_band(aspect_ratio, 0.92, 1.15, "方掌偏稳", "掌型均衡", "长掌偏柔")
    finger_spread = _classify_band(finger_spread_ratio, 1.25, 1.75, "指缝收束", "舒展适中", "手指舒展")
    line_clarity = _classify_band(clarity_seed, 0.45, 0.72, "掌纹偏淡", "掌纹中等清晰", "掌纹清晰")
    life_line = "弧度开阔、起点稳定" if thumb_open_ratio > 0.68 else "弧度偏紧、守成倾向较强"
    head_line = "理性规划感较强" if mean_finger_length > 0.98 else "更偏感受驱动与现场反应"
    heart_line = "表达直接，情感推进较快" if finger_spread_ratio > 1.65 else "情感表达克制，重安全感"
    career_line = "节奏感明显，适合循序积累" if aspect_ratio >= 1.0 else "更适合稳定框架内深耕"

    notes = []
    if thumb_open_ratio > 0.82:
        notes.append("拇指张开角度较大，主观能动性偏强。")
    if finger_spread_ratio < 1.3:
        notes.append("指间距离偏收，近期更重控制风险。")
    if mean_finger_length > 1.05:
        notes.append("指节相对修长，思考与观察先于行动。")

    return {
        "source": "landmarks",
        "palmShape": palm_shape,
        "fingerSpread": finger_spread,
        "lineClarity": line_clarity,
        "qualitySummary": "已检测到完整掌型骨架，可进入结构化解读。",
        "lifeLine": life_line,
        "headLine": head_line,
        "heartLine": heart_line,
        "careerLine": career_line,
        "notes": notes,
        "metrics": {
            "aspectRatio": round(aspect_ratio, 3),
            "fingerSpreadRatio": round(finger_spread_ratio, 3),
            "thumbOpenRatio": round(thumb_open_ratio, 3),
            "meanFingerLength": round(mean_finger_length, 3),
        },
    }


def _extract_palmistry_from_image(image):
    gray = image.convert("L")
    stat = ImageStat.Stat(gray)
    brightness = stat.mean[0] if stat.mean else 0
    contrast = stat.stddev[0] if stat.stddev else 0
    edge_stat = ImageStat.Stat(gray.filter(ImageFilter.FIND_EDGES))
    edge_strength = edge_stat.mean[0] if edge_stat.mean else 0
    width, height = image.size
    aspect_ratio = height / max(width, 1)

    return {
        "source": "image_heuristic",
        "palmShape": _classify_band(aspect_ratio, 1.05, 1.35, "掌型偏宽", "掌型均衡", "掌型偏长"),
        "fingerSpread": _classify_band(edge_strength, 9, 20, "手指收束", "舒展适中", "舒展明显"),
        "lineClarity": _classify_band(contrast + edge_strength * 0.3, 26, 42, "掌纹偏淡", "掌纹中等清晰", "掌纹清晰"),
        "qualitySummary": f"亮度约 {brightness:.0f}、对比度约 {contrast:.0f}，图像质量可用于基础解析。",
        "lifeLine": "画面可见生命线区域，但当前仅做基础趋势判断。",
        "headLine": "智慧线细节有限，建议以后续问答补充判断。",
        "heartLine": "感情线区域可见度中等，情绪表达倾向需结合提问理解。",
        "careerLine": "事业线先按整体掌型和掌面清晰度做保守判断。",
        "notes": ["当前结构化结果以图像清晰度与掌型比例为基础。"],
        "metrics": {
            "brightness": round(brightness, 2),
            "contrast": round(contrast, 2),
            "edgeStrength": round(edge_strength, 2),
            "aspectRatio": round(aspect_ratio, 3),
        },
    }


def _extract_palmistry_with_mediapipe(image):
    if mp is None:
        return None
    try:
        hands = mp.solutions.hands.Hands(static_image_mode=True, max_num_hands=1, min_detection_confidence=0.5)
        result = hands.process(image.convert("RGB"))
        hands.close()
        if not result.multi_hand_landmarks:
            return None
        structured = _extract_palmistry_from_image(image)
        if structured:
            structured["source"] = "mediapipe+image_heuristic"
            structured["notes"].append("已尝试通过 MediaPipe 骨架补强检测结果。")
        return structured
    except Exception:
        return None


def _compose_palmistry_structure(image, landmarks):
    structured = _extract_palmistry_with_mediapipe(image)
    if structured:
        return structured, "mediapipe"
    structured = _extract_palmistry_from_landmarks(landmarks or {})
    if structured:
        return structured, "landmarks"
    return _extract_palmistry_from_image(image), "image_heuristic"


def _clamp01(value):
    return max(0.0, min(float(value), 1.0))


def _landmark_image_point(landmarks, key, width, height):
    point = _extract_landmark_point(landmarks, key)
    if not point:
        return None
    return (
        _clamp01(point["x"]) * width,
        _clamp01(1 - point["y"]) * height,
    )


def _bezier_point(p0, p1, p2, p3, t):
    inv = 1 - t
    x = inv ** 3 * p0[0] + 3 * inv * inv * t * p1[0] + 3 * inv * t * t * p2[0] + t ** 3 * p3[0]
    y = inv ** 3 * p0[1] + 3 * inv * inv * t * p1[1] + 3 * inv * t * t * p2[1] + t ** 3 * p3[1]
    return (x, y)


def _sample_darkest_near(gray, x, y, radius=14):
    width, height = gray.size
    px = gray.load()
    best = (x, y)
    best_score = -10**9
    min_x = max(0, int(x - radius))
    max_x = min(width - 1, int(x + radius))
    min_y = max(0, int(y - radius))
    max_y = min(height - 1, int(y + radius))
    for iy in range(min_y, max_y + 1):
        for ix in range(min_x, max_x + 1):
            darkness = 255 - px[ix, iy]
            distance_penalty = ((ix - x) ** 2 + (iy - y) ** 2) ** 0.5 * 1.8
            score = darkness - distance_penalty
            if score > best_score:
                best_score = score
                best = (ix, iy)
    return best


def _smooth_points(points, width, height):
    if len(points) <= 2:
        return points
    smoothed = []
    for index in range(len(points)):
        left = max(0, index - 1)
        right = min(len(points), index + 2)
        window = points[left:right]
        x = sum(p[0] for p in window) / len(window)
        y = sum(p[1] for p in window) / len(window)
        smoothed.append((_clamp01(x / width), _clamp01(y / height)))
    return smoothed


def _trace_curve(gray, anchors, samples=24, radius=14):
    width, height = gray.size
    points = []
    for idx in range(samples):
        t = idx / max(samples - 1, 1)
        expected = _bezier_point(anchors[0], anchors[1], anchors[2], anchors[3], t)
        sampled = _sample_darkest_near(gray, expected[0], expected[1], radius=radius)
        points.append(sampled)
    return _smooth_points(points, width, height)


def _trace_curve_or_fallback(gray, anchors, width, height, samples=24, radius=8, max_offset_ratio=0.045):
    traced = _trace_curve(gray, anchors, samples=samples, radius=radius)
    expected = _fallback_curve(anchors, width, height, samples=samples)
    if len(traced) != len(expected):
        return expected
    max_offset = min(width, height) * max_offset_ratio
    total = 0.0
    for traced_point, expected_point in zip(traced, expected):
        dx = traced_point[0] * width - expected_point[0] * width
        dy = traced_point[1] * height - expected_point[1] * height
        total += (dx * dx + dy * dy) ** 0.5
    avg_offset = total / max(len(traced), 1)
    return traced if avg_offset <= max_offset else expected


def _fallback_curve(anchors, width, height, samples=24):
    points = []
    for idx in range(samples):
        t = idx / max(samples - 1, 1)
        x, y = _bezier_point(anchors[0], anchors[1], anchors[2], anchors[3], t)
        points.append((_clamp01(x / width), _clamp01(y / height)))
    return points


def _default_line_overlays(width, height):
    return [
        {
            "key": "heart_line",
            "title": "爱情线",
            "colorHex": "FF7A95",
            "confidence": 0.42,
            "points": _fallback_curve(
                [
                    (0.18 * width, 0.32 * height),
                    (0.36 * width, 0.25 * height),
                    (0.62 * width, 0.23 * height),
                    (0.84 * width, 0.30 * height),
                ],
                width,
                height,
            ),
        },
        {
            "key": "head_line",
            "title": "智慧线",
            "colorHex": "7B8CFF",
            "confidence": 0.4,
            "points": _fallback_curve(
                [
                    (0.32 * width, 0.40 * height),
                    (0.44 * width, 0.46 * height),
                    (0.62 * width, 0.50 * height),
                    (0.80 * width, 0.54 * height),
                ],
                width,
                height,
            ),
        },
        {
            "key": "career_line",
            "title": "事业线",
            "colorHex": "F6C453",
            "confidence": 0.36,
            "points": _fallback_curve(
                [
                    (0.50 * width, 0.82 * height),
                    (0.52 * width, 0.66 * height),
                    (0.53 * width, 0.50 * height),
                    (0.56 * width, 0.34 * height),
                ],
                width,
                height,
            ),
        },
        {
            "key": "life_line",
            "title": "生命线",
            "colorHex": "53D3A6",
            "confidence": 0.4,
            "points": _fallback_curve(
                [
                    (0.36 * width, 0.28 * height),
                    (0.16 * width, 0.36 * height),
                    (0.14 * width, 0.66 * height),
                    (0.34 * width, 0.87 * height),
                ],
                width,
                height,
            ),
        },
    ]


def _build_geometric_palm_line_overlays(image, landmarks, hand_side):
    width, height = image.size
    wrist = _landmark_image_point(landmarks, "VNHLKWrist", width, height)
    index_mcp = _landmark_image_point(landmarks, "VNHLKIndexMCP", width, height)
    middle_mcp = _landmark_image_point(landmarks, "VNHLKMiddleMCP", width, height)
    ring_mcp = _landmark_image_point(landmarks, "VNHLKRingMCP", width, height)
    little_mcp = _landmark_image_point(landmarks, "VNHLKLittleMCP", width, height)
    index_pip = _landmark_image_point(landmarks, "VNHLKIndexPIP", width, height)
    middle_pip = _landmark_image_point(landmarks, "VNHLKMiddlePIP", width, height)
    ring_pip = _landmark_image_point(landmarks, "VNHLKRingPIP", width, height)
    little_pip = _landmark_image_point(landmarks, "VNHLKLittlePIP", width, height)
    thumb_cmc = _landmark_image_point(landmarks, "VNHLKThumbCMC", width, height)
    thumb_mp = _landmark_image_point(landmarks, "VNHLKThumbMP", width, height)
    if not all([wrist, index_mcp, middle_mcp, ring_mcp, little_mcp, index_pip, middle_pip, ring_pip, little_pip, thumb_cmc, thumb_mp]):
        return _default_line_overlays(width, height)

    palm_width = max(abs(little_mcp[0] - index_mcp[0]), width * 0.12)
    palm_height = max(abs(wrist[1] - middle_mcp[1]), height * 0.18)
    center_x = (index_mcp[0] + middle_mcp[0] + ring_mcp[0] + little_mcp[0]) / 4
    thumb_on_left = thumb_cmc[0] < center_x

    outer_mcp = little_mcp if thumb_on_left else index_mcp
    inner_mcp = index_mcp if thumb_on_left else little_mcp
    outer_pip = little_pip if thumb_on_left else index_pip
    inner_pip = index_pip if thumb_on_left else little_pip
    life_dir = -1 if thumb_on_left else 1

    heart_anchors = [
        (outer_pip[0] + palm_width * (0.06 if thumb_on_left else -0.06), outer_mcp[1] + palm_height * 0.02),
        (ring_pip[0], ring_mcp[1] + palm_height * 0.06),
        (middle_pip[0], middle_mcp[1] + palm_height * 0.06),
        (inner_pip[0] + palm_width * (-0.02 if thumb_on_left else 0.02), inner_mcp[1] + palm_height * 0.02),
    ]
    head_anchors = [
        (inner_mcp[0] + palm_width * 0.04 * life_dir, inner_mcp[1] + palm_height * 0.12),
        (middle_mcp[0] + palm_width * 0.05 * life_dir, middle_mcp[1] + palm_height * 0.18),
        (ring_mcp[0] + palm_width * 0.02 * life_dir, ring_mcp[1] + palm_height * 0.24),
        (outer_mcp[0] + palm_width * 0.04 * (1 if thumb_on_left else -1), outer_mcp[1] + palm_height * 0.26),
    ]
    career_anchors = [
        (center_x - palm_width * 0.01, wrist[1] - palm_height * 0.05),
        (center_x - palm_width * 0.02, wrist[1] - palm_height * 0.26),
        (center_x + palm_width * 0.00, middle_mcp[1] + palm_height * 0.26),
        (center_x + palm_width * 0.01, middle_mcp[1] + palm_height * 0.02),
    ]
    life_anchors = [
        (inner_mcp[0] + palm_width * 0.02 * life_dir, inner_mcp[1] + palm_height * 0.04),
        (thumb_cmc[0] + palm_width * 0.16 * life_dir, thumb_cmc[1] + palm_height * 0.10),
        (thumb_mp[0] + palm_width * 0.18 * life_dir, wrist[1] - palm_height * 0.16),
        (center_x + palm_width * 0.24 * life_dir, wrist[1] - palm_height * 0.04),
    ]

    return [
        {
            "key": "heart_line",
            "title": "爱情线",
            "colorHex": "FF7A95",
            "confidence": 0.78,
            "points": _fallback_curve(heart_anchors, width, height, samples=22),
        },
        {
            "key": "head_line",
            "title": "智慧线",
            "colorHex": "7B8CFF",
            "confidence": 0.78,
            "points": _fallback_curve(head_anchors, width, height, samples=22),
        },
        {
            "key": "career_line",
            "title": "事业线",
            "colorHex": "F6C453",
            "confidence": 0.72,
            "points": _fallback_curve(career_anchors, width, height, samples=20),
        },
        {
            "key": "life_line",
            "title": "生命线",
            "colorHex": "53D3A6",
            "confidence": 0.82,
            "points": _fallback_curve(life_anchors, width, height, samples=24),
        },
    ]


def _build_palm_line_overlays(image, landmarks, hand_side):
    if palm_line_segmenter is not None:
        try:
            model_overlays = palm_line_segmenter.build_overlays(image, landmarks)
            if _has_valid_palm_line_overlays(model_overlays):
                return model_overlays
        except Exception as exc:  # noqa: BLE001
            print(f"[palmistry_model_segment_error] {exc}")
    elif PALM_SEGMENTATION_IMPORT_ERROR:
        print(f"[palmistry_model_segment_unavailable] {PALM_SEGMENTATION_IMPORT_ERROR}")
    return _build_geometric_palm_line_overlays(image, landmarks, hand_side)


def _has_valid_palm_line_overlays(overlays):
    if not isinstance(overlays, list) or len(overlays) < 4:
        return False
    for line in overlays:
        if not isinstance(line, dict):
            return False
        points = line.get("points") or []
        confidence = _safe_float(line.get("confidence")) or 0
        if len(points) < 8 or confidence < 0.6:
            return False
    return True


def _build_palmistry_summary_tags(hand_side, structured, analysis):
    tags = [
        f"{hand_side}主看",
        structured.get("palmShape", ""),
        structured.get("lineClarity", ""),
        analysis.get("overall", ""),
    ]
    if structured.get("fingerSpread"):
        tags.append(structured.get("fingerSpread", ""))
    output = []
    for tag in tags:
        text = _clean_text(tag)
        if text and text not in output:
            output.append(text)
    return output[:5]


def build_palmistry_prompt(profile, hand_side, structured):
    profile_lines = []
    if profile:
        profile_lines.extend([
            f"- 姓名：{profile.get('name', '')}",
            f"- 性别：{profile.get('gender', '')}",
            f"- 出生地：{profile.get('location', '')}",
            f"- 阳历出生：{profile.get('solar', '')}",
            f"- 阴历出生：{profile.get('lunar', '')}",
            f"- 真太阳时：{profile.get('trueSolar', '')}",
        ])
    metrics = structured.get("metrics") or {}
    metrics_text = "、".join(f"{key}={value}" for key, value in metrics.items())
    return (
        "你是资深手相师。请根据结构化掌纹观察结果输出严格 JSON，不要 markdown，不要解释。"
        "格式："
        "{\"overall\":\"...\",\"summary\":\"...\",\"lifeLine\":\"...\",\"headLine\":\"...\",\"heartLine\":\"...\","
        "\"career\":\"...\",\"wealth\":\"...\",\"love\":\"...\",\"health\":\"...\",\"advice\":\"...\",\"summaryTags\":[\"标签1\",\"标签2\"]}"
        "要求：summary 60~110 字，其余每项 50~120 字，语言自然，不要绝对化，不要做医疗诊断。"
        "summaryTags 输出 3~5 个简短标签。"
        f"识别手别：{hand_side}。"
        f"结构化观察：掌型={structured.get('palmShape', '')}；舒展度={structured.get('fingerSpread', '')}；"
        f"掌纹清晰度={structured.get('lineClarity', '')}；质量备注={structured.get('qualitySummary', '')}；"
        f"生命线观察={structured.get('lifeLine', '')}；智慧线观察={structured.get('headLine', '')}；"
        f"感情线观察={structured.get('heartLine', '')}；事业线观察={structured.get('careerLine', '')}；"
        f"补充={';'.join(structured.get('notes') or [])}；指标={metrics_text}。"
        + (" 用户档案：" + " ".join(profile_lines) if profile_lines else "")
    )


def parse_palmistry_response(text):
    if not text:
        return None
    raw = text.strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass
    start = raw.find("{")
    end = raw.rfind("}")
    if start >= 0 and end > start:
        try:
            return json.loads(raw[start:end + 1])
        except json.JSONDecodeError:
            return None
    return None


def _default_palmistry_analysis(hand_side, structured):
    summary = (
        f"这次读取的是{hand_side}，整体呈现“{structured.get('palmShape', '掌型均衡')}、"
        f"{structured.get('fingerSpread', '舒展适中')}、{structured.get('lineClarity', '掌纹中等清晰')}”的组合。"
        "当前更适合稳住节奏、先做确认再推进，属于可进但不宜躁进的手相走势。"
    )
    return {
        "overall": "稳中可进",
        "summary": summary,
        "lifeLine": "生命线观感偏稳，近期核心状态重在恢复节律与体能储备，适合把作息与消耗控制住。",
        "headLine": "智慧线倾向理性规划，但容易在细节上反复权衡，关键决策宜限定时间窗口，不要拖太久。",
        "heartLine": "感情线反馈更强调安全感与边界感，关系推进宜先看对方是否持续稳定回应。",
        "career": "事业上适合先稳岗位、稳资源，再谈扩张。近期更适合做整理、补漏、复盘型工作。",
        "wealth": "财运表现偏稳健，适合守住现金流和预算纪律，不宜因为情绪起伏做冲动消费或冒进投入。",
        "love": "情感议题上宜慢热观察，先看行动一致性，不宜只凭一时的热度判断长期走向。",
        "health": "这里只能给生活层面的提醒：近期更需要关注睡眠、肩颈与手部疲劳，不替代医疗建议。",
        "advice": "未来一周优先做一件能落地的小事：确认一个计划、完成一次沟通或收拢一项资源。先让局面变清楚，再决定下一步。",
        "summaryTags": [],
    }


def _pending_palmistry_analysis():
    return {
        "overall": "掌纹分割已完成",
        "summary": "您的专属天师正在思考中，完整报告生成后可在当前页展开查看。",
        "lifeLine": "",
        "headLine": "",
        "heartLine": "",
        "career": "",
        "wealth": "",
        "love": "",
        "health": "",
        "advice": "",
        "summaryTags": [],
    }


def _build_palmistry_file_url(filename):
    if not filename:
        return None
    return f"{request.host_url.rstrip('/')}/uploads/palmistry/{quote(filename)}"


def _serialize_palmistry_payload(row):
    if not row:
        return None
    taken_at = row.get("taken_at")
    report_status = _clean_text(row.get("report_status")) or "ready"
    structured = row.get("structured") or {}
    raw_overlays = structured.get("overlays") or []
    overlays = []
    for line in raw_overlays:
        points = []
        for point in line.get("points") or []:
            if isinstance(point, dict):
                x = point.get("x")
                y = point.get("y")
            elif isinstance(point, (list, tuple)) and len(point) >= 2:
                x, y = point[0], point[1]
            else:
                continue
            try:
                points.append({"x": float(x), "y": float(y)})
            except Exception:
                continue
        overlays.append(
            {
                "key": line.get("key", ""),
                "title": line.get("title", ""),
                "colorHex": line.get("colorHex", ""),
                "confidence": float(line.get("confidence", 0.0) or 0.0),
                "points": points,
            }
        )
    analysis = None
    if report_status == "ready":
        analysis = {
            "overall": row.get("overall", ""),
            "summary": row.get("summary", ""),
            "lifeLine": row.get("life_line", ""),
            "headLine": row.get("head_line", ""),
            "heartLine": row.get("heart_line", ""),
            "career": row.get("career", ""),
            "wealth": row.get("wealth", ""),
            "love": row.get("love", ""),
            "health": row.get("health", ""),
            "advice": row.get("advice", ""),
            "summaryTags": structured.get("summaryTags") or [],
            "structured": structured,
        }
    return {
        "id": str(row.get("id", "")),
        "profileId": str(row.get("profile_id", "")),
        "handSide": row.get("hand_side", "right"),
        "takenAt": _to_started_at_text(taken_at, "Asia/Shanghai"),
        "takenAtISO": taken_at.isoformat() if taken_at else "",
        "originalImageURL": _build_palmistry_file_url(row.get("original_image_path", "")),
        "thumbnailURL": _build_palmistry_file_url(row.get("thumbnail_path", "")),
        "overlays": overlays,
        "reportStatus": report_status,
        "reportError": row.get("report_error"),
        "analysis": analysis,
    }


def fetch_palmistry_reading(profile_id, reading_id):
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT *
                FROM palm_readings
                WHERE profile_id = %s AND id = %s
                LIMIT 1
                """,
                (str(profile_id), str(reading_id)),
            )
            row = cur.fetchone()
    return _serialize_palmistry_payload(row)


def list_palmistry_history(profile_id, limit=30):
    n = max(1, min(int(limit), 100))
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, profile_id, hand_side, taken_at, thumbnail_path, summary, overall, report_status
                FROM palm_readings
                WHERE profile_id = %s
                ORDER BY taken_at DESC, created_at DESC
                LIMIT %s
                """,
                (str(profile_id), n),
            )
            rows = cur.fetchall()
    payload = []
    for row in rows:
        taken_at = row.get("taken_at")
        payload.append(
            {
                "id": str(row.get("id", "")),
                "profileId": str(row.get("profile_id", "")),
                "handSide": row.get("hand_side", "right"),
                "takenAt": _to_started_at_text(taken_at, "Asia/Shanghai"),
                "takenAtISO": taken_at.isoformat() if taken_at else "",
                "thumbnailURL": _build_palmistry_file_url(row.get("thumbnail_path", "")),
                "reportStatus": _clean_text(row.get("report_status")) or "ready",
                "summary": row.get("summary", ""),
                "overall": row.get("overall", ""),
            }
        )
    return payload


def fetch_profile(profile_id):
    if not profile_id:
        return {}
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT id, name, gender, location, solar, lunar, true_solar,
                       location_province, location_city, location_district, location_detail,
                       latitude, longitude, timezone_id, utc_offset_minutes, place_source, location_adcode
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
                "locationProvince": row.get("location_province", ""),
                "locationCity": row.get("location_city", ""),
                "locationDistrict": row.get("location_district", ""),
                "locationDetail": row.get("location_detail", ""),
                "latitude": row.get("latitude"),
                "longitude": row.get("longitude"),
                "timezoneId": row.get("timezone_id", ""),
                "utcOffsetMinutes": row.get("utc_offset_minutes"),
                "placeSource": row.get("place_source", ""),
                "locationAdcode": row.get("location_adcode", ""),
            }


def _fetch_palmistry_row(profile_id, reading_id):
    with get_db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT *
                FROM palm_readings
                WHERE profile_id = %s AND id = %s
                LIMIT 1
                """,
                (str(profile_id), str(reading_id)),
            )
            return cur.fetchone()


def _generate_palmistry_report_for_reading(profile_id, reading_id):
    row = _fetch_palmistry_row(profile_id, reading_id)
    if not row:
        return
    structured = row.get("structured") or {}
    hand_side = "左手" if row.get("hand_side") == "left" else "右手"
    profile = fetch_profile(profile_id)
    analysis = _default_palmistry_analysis(hand_side, structured)
    try:
        prompt = build_palmistry_prompt(profile, hand_side, structured)
        raw = spark_chat(
            [{"role": "system", "content": prompt}, {"role": "user", "content": "开始解读这次手相。"}],
            recv_timeout=4,
            max_duration=8,
        )
        parsed = parse_palmistry_response(raw)
        if isinstance(parsed, dict):
            for key in ["overall", "summary", "lifeLine", "headLine", "heartLine", "career", "wealth", "love", "health", "advice"]:
                if _clean_text(parsed.get(key)):
                    analysis[key] = _clean_text(parsed.get(key))
            if isinstance(parsed.get("summaryTags"), list):
                analysis["summaryTags"] = [_clean_text(item) for item in parsed.get("summaryTags") if _clean_text(item)]
    except Exception as exc:
        print(f"[palmistry_fallback] {exc}")

    analysis["summaryTags"] = analysis.get("summaryTags") or _build_palmistry_summary_tags(hand_side, structured, analysis)
    structured["summaryTags"] = analysis["summaryTags"]

    with get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE palm_readings
                SET structured = %s,
                    overall = %s,
                    summary = %s,
                    life_line = %s,
                    head_line = %s,
                    heart_line = %s,
                    career = %s,
                    wealth = %s,
                    love = %s,
                    health = %s,
                    advice = %s,
                    report_status = 'ready',
                    report_error = NULL,
                    report_generated_at = now()
                WHERE profile_id = %s AND id = %s
                """,
                (
                    psycopg2.extras.Json(structured),
                    analysis["overall"],
                    analysis["summary"],
                    analysis["lifeLine"],
                    analysis["headLine"],
                    analysis["heartLine"],
                    analysis["career"],
                    analysis["wealth"],
                    analysis["love"],
                    analysis["health"],
                    analysis["advice"],
                    str(profile_id),
                    str(reading_id),
                ),
            )


def _queue_palmistry_report(profile_id, reading_id):
    def runner():
        try:
            _generate_palmistry_report_for_reading(profile_id, reading_id)
            print(f"[palmistry] report ready reading={reading_id}")
        except Exception as exc:
            print(f"[palmistry_report_error] {exc}")
            with get_db_conn() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        UPDATE palm_readings
                        SET report_status = 'failed',
                            report_error = %s
                        WHERE profile_id = %s AND id = %s
                        """,
                        (str(exc), str(profile_id), str(reading_id)),
                    )

    threading.Thread(target=runner, daemon=True).start()


def resolve_tianshi_prompt(tianshi_id, now_str):
    tianshi_key = str(tianshi_id or "").strip().lower()
    prompt_template = TIANSHI_SYSTEM_PROMPTS.get(tianshi_key)
    if prompt_template:
        return prompt_template.format(time=now_str).strip()
    if SPARK_SYSTEM_PROMPT.strip():
        return SPARK_SYSTEM_PROMPT.format(time=now_str).strip()
    return ""


def build_chat_messages(messages, profile, tianshi_id=None):
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
    role_prompt = resolve_tianshi_prompt(tianshi_id, now_str)
    if role_prompt:
        system_parts.append(role_prompt)
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
    enriched_location = enrich_location_payload(payload)
    with get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO profiles (
                    id, user_id, name, gender, location, solar, lunar, true_solar,
                    location_province, location_city, location_district, location_detail,
                    latitude, longitude, timezone_id, utc_offset_minutes, place_source, location_adcode
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (id) DO UPDATE SET
                    user_id = EXCLUDED.user_id,
                    name = EXCLUDED.name,
                    gender = EXCLUDED.gender,
                    location = EXCLUDED.location,
                    solar = EXCLUDED.solar,
                    lunar = EXCLUDED.lunar,
                    true_solar = EXCLUDED.true_solar,
                    location_province = EXCLUDED.location_province,
                    location_city = EXCLUDED.location_city,
                    location_district = EXCLUDED.location_district,
                    location_detail = EXCLUDED.location_detail,
                    latitude = EXCLUDED.latitude,
                    longitude = EXCLUDED.longitude,
                    timezone_id = EXCLUDED.timezone_id,
                    utc_offset_minutes = EXCLUDED.utc_offset_minutes,
                    place_source = EXCLUDED.place_source,
                    location_adcode = EXCLUDED.location_adcode,
                    updated_at = now()
                """,
                (
                    profile_id,
                    user_id,
                    payload.get("name", ""),
                    payload.get("gender", ""),
                    enriched_location.get("location", ""),
                    payload.get("solar", ""),
                    payload.get("lunar", ""),
                    payload.get("trueSolar", ""),
                    enriched_location.get("location_province", ""),
                    enriched_location.get("location_city", ""),
                    enriched_location.get("location_district", ""),
                    enriched_location.get("location_detail", ""),
                    enriched_location.get("latitude"),
                    enriched_location.get("longitude"),
                    enriched_location.get("timezone_id", ""),
                    enriched_location.get("utc_offset_minutes"),
                    enriched_location.get("place_source", ""),
                    enriched_location.get("location_adcode", ""),
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
                SELECT id, name, gender, location, solar, lunar, true_solar, created_at,
                       location_province, location_city, location_district, location_detail,
                       latitude, longitude, timezone_id, utc_offset_minutes, place_source, location_adcode
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
            "locationProvince": row.get("location_province", ""),
            "locationCity": row.get("location_city", ""),
            "locationDistrict": row.get("location_district", ""),
            "locationDetail": row.get("location_detail", ""),
            "latitude": row.get("latitude"),
            "longitude": row.get("longitude"),
            "timezoneId": row.get("timezone_id", ""),
            "utcOffsetMinutes": row.get("utc_offset_minutes"),
            "placeSource": row.get("place_source", ""),
            "locationAdcode": row.get("location_adcode", ""),
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


@app.get("/uploads/palmistry/<path:filename>")
def serve_palmistry_upload(filename):
    return send_from_directory(PALMISTRY_UPLOAD_DIR, filename)


@app.post("/palmistry/segment")
def segment_palmistry():
    payload = request.get_json(silent=True) or {}
    profile_id = payload.get("profileId") or payload.get("profile_id")
    if not profile_id:
        return jsonify({"error": "profileId required"}), 400

    image_bytes = _decode_base64_image(payload.get("imageBase64") or payload.get("image_base64"))
    if not image_bytes:
        return jsonify({"error": "imageBase64 required"}), 400

    hand_side_raw = _clean_text(payload.get("handSide") or payload.get("hand_side")).lower()
    hand_side = "left" if hand_side_raw == "left" else "right"
    captured_at = _parse_iso_datetime(payload.get("capturedAt") or payload.get("captured_at"))
    landmarks = payload.get("landmarks") if isinstance(payload.get("landmarks"), dict) else {}
    profile = fetch_profile(profile_id)

    try:
        print(f"[palmistry] segment start profile={profile_id} hand={hand_side}")
        reading_id, original_name, thumb_name, image = _save_palmistry_images(image_bytes)
        structured, pipeline = _compose_palmistry_structure(image, landmarks)
        overlays = _build_palm_line_overlays(image, landmarks, "左手" if hand_side == "left" else "右手")
        if not _has_valid_palm_line_overlays(overlays):
            return jsonify({"error": "未能稳定识别四条主线，请重新拍照"}), 422
        analysis = _pending_palmistry_analysis()
        structured["overlays"] = overlays
        structured["summaryTags"] = []

        with get_db_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO palm_readings (
                        id, profile_id, hand_side, taken_at, original_image_path, thumbnail_path,
                        structured, overall, summary, life_line, head_line, heart_line,
                        career, wealth, love, health, advice, source_pipeline,
                        report_status, report_error
                    )
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        reading_id,
                        str(profile_id),
                        hand_side,
                        captured_at,
                        original_name,
                        thumb_name,
                        psycopg2.extras.Json(structured),
                        analysis["overall"],
                        analysis["summary"],
                        analysis["lifeLine"],
                        analysis["headLine"],
                        analysis["heartLine"],
                        analysis["career"],
                        analysis["wealth"],
                        analysis["love"],
                        analysis["health"],
                        analysis["advice"],
                        pipeline + "+segment",
                        "pending",
                        None,
                    ),
                )
        stored = fetch_palmistry_reading(profile_id, reading_id)
        if not stored:
            return jsonify({"error": "failed to persist palm segment"}), 500
        print(f"[palmistry] segment success reading={reading_id} pipeline={pipeline}")
        return jsonify(stored)
    except Exception as exc:  # noqa: BLE001
        print(f"[palmistry_segment_error] {exc}")
        return jsonify({"error": str(exc)}), 500


@app.post("/palmistry/report")
def start_palmistry_report():
    payload = request.get_json(silent=True) or {}
    profile_id = payload.get("profileId") or payload.get("profile_id")
    reading_id = payload.get("readingId") or payload.get("reading_id")
    if not profile_id or not reading_id:
        return jsonify({"error": "profileId and readingId required"}), 400
    row = _fetch_palmistry_row(profile_id, reading_id)
    if not row:
        return jsonify({"error": "not found"}), 404
    report_status = _clean_text(row.get("report_status")) or "pending"
    if report_status == "ready":
        return jsonify({"ok": True, "status": "ready"})
    with get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE palm_readings
                SET report_status = 'pending',
                    report_error = NULL,
                    report_requested_at = now()
                WHERE profile_id = %s AND id = %s
                """,
                (str(profile_id), str(reading_id)),
            )
    _queue_palmistry_report(profile_id, reading_id)
    return jsonify({"ok": True, "status": "pending"})


@app.get("/palmistry/<reading_id>/report-status")
def palmistry_report_status(reading_id):
    profile_id = request.args.get("profile_id") or request.args.get("profileId")
    if not profile_id:
        return jsonify({"error": "profile_id required"}), 400
    row = _fetch_palmistry_row(profile_id, reading_id)
    if not row:
        return jsonify({"error": "not found"}), 404
    payload = _serialize_palmistry_payload(row)
    return jsonify(
        {
            "readingId": str(reading_id),
            "reportStatus": payload.get("reportStatus", "pending"),
            "reportError": payload.get("reportError"),
            "result": payload,
        }
    )


@app.get("/palmistry/history")
def palmistry_history():
    profile_id = request.args.get("profile_id") or request.args.get("profileId")
    if not profile_id:
        return jsonify({"error": "profile_id required"}), 400
    limit = request.args.get("limit", 30)
    try:
        payload = list_palmistry_history(profile_id, limit=limit)
        return jsonify(payload)
    except Exception as exc:  # noqa: BLE001
        return jsonify({"error": str(exc)}), 500


@app.get("/palmistry/<reading_id>")
def palmistry_detail(reading_id):
    profile_id = request.args.get("profile_id") or request.args.get("profileId")
    if not profile_id:
        return jsonify({"error": "profile_id required"}), 400
    payload = fetch_palmistry_reading(profile_id, reading_id)
    if not payload:
        return jsonify({"error": "not found"}), 404
    return jsonify(payload)


def _resolve_profile_zone(profile):
    timezone_id = _clean_text((profile or {}).get("timezoneId")) or "Asia/Shanghai"
    try:
        return ZoneInfo(timezone_id)
    except Exception:
        return ZoneInfo("Asia/Shanghai")


def _resolve_profile_today(profile):
    zone = _resolve_profile_zone(profile)
    return datetime.now(zone).date()


@app.get("/one-thing/today")
def get_today_one_thing():
    profile_id = request.args.get("profile_id") or request.args.get("profileId")
    if not profile_id:
        return jsonify({"error": "profile_id required"}), 400
    profile = fetch_profile(profile_id)
    if not profile:
        return jsonify({"error": "profile not found"}), 404
    today = _resolve_profile_today(profile)
    existing = fetch_one_thing_divination_by_date(profile_id, today, profile.get("timezoneId", "Asia/Shanghai"))
    if not existing:
        return jsonify({"error": "not found"}), 404
    return jsonify(existing)


@app.get("/one-thing/latest")
def get_latest_one_thing():
    profile_id = request.args.get("profile_id") or request.args.get("profileId")
    if not profile_id:
        return jsonify({"error": "profile_id required"}), 400
    profile = fetch_profile(profile_id)
    if not profile:
        return jsonify({"error": "profile not found"}), 404
    latest = fetch_one_thing_divination_latest(profile_id, profile.get("timezoneId", "Asia/Shanghai"))
    if not latest:
        return jsonify({"error": "not found"}), 404
    return jsonify(latest)


@app.get("/one-thing/history")
def get_one_thing_history():
    profile_id = request.args.get("profile_id") or request.args.get("profileId")
    if not profile_id:
        return jsonify({"error": "profile_id required"}), 400
    profile = fetch_profile(profile_id)
    if not profile:
        return jsonify({"error": "profile not found"}), 404
    limit = request.args.get("limit", 30)
    try:
        limit = int(limit)
    except (TypeError, ValueError):
        limit = 30
    items = list_one_thing_history(profile_id, profile.get("timezoneId", "Asia/Shanghai"), limit=limit)
    return jsonify(items)


@app.get("/one-thing/record/<record_id>")
def get_one_thing_record(record_id):
    profile_id = request.args.get("profile_id") or request.args.get("profileId")
    if not profile_id:
        return jsonify({"error": "profile_id required"}), 400
    profile = fetch_profile(profile_id)
    if not profile:
        return jsonify({"error": "profile not found"}), 404
    record = fetch_one_thing_divination_by_id(profile_id, record_id, profile.get("timezoneId", "Asia/Shanghai"))
    if not record:
        return jsonify({"error": "not found"}), 404
    return jsonify(record)


@app.delete("/one-thing/record/<record_id>")
def delete_one_thing_record(record_id):
    profile_id = request.args.get("profile_id") or request.args.get("profileId")
    if not profile_id:
        return jsonify({"error": "profile_id required"}), 400
    profile = fetch_profile(profile_id)
    if not profile:
        return jsonify({"error": "profile not found"}), 404
    deleted = delete_one_thing_divination(profile_id, record_id)
    if not deleted:
        return jsonify({"error": "not found"}), 404
    return jsonify({"ok": True})


@app.post("/one-thing/cast")
def cast_one_thing():
    payload = request.get_json(silent=True) or {}
    profile_id = payload.get("profileId") or payload.get("profile_id")
    question = _clean_text(payload.get("question"))
    tosses = _normalize_tosses(payload.get("tosses"))
    if not profile_id:
        return jsonify({"error": "profileId required"}), 400
    if not question:
        return jsonify({"error": "question required"}), 400
    if tosses is None:
        return jsonify({"error": "tosses invalid, expected 6 entries x 3 coins"}), 400

    profile = fetch_profile(profile_id)
    if not profile:
        return jsonify({"error": "profile not found"}), 404

    zone = _resolve_profile_zone(profile)
    started_at = _parse_iso_datetime(payload.get("startedAt"))
    started_local = started_at.astimezone(zone)
    divination_date = started_local.date()

    try:
        from lunar_python import Solar
    except ImportError:
        return jsonify({"error": "lunar_python unavailable"}), 500

    solar = Solar.fromYmdHms(
        started_local.year,
        started_local.month,
        started_local.day,
        started_local.hour,
        started_local.minute,
        started_local.second,
    )
    lunar = solar.getLunar()
    gan_zhi = {
        "year": lunar.getYearInGanZhi(),
        "month": lunar.getMonthInGanZhi(),
        "day": lunar.getDayInGanZhi(),
        "hour": lunar.getTimeInGanZhi(),
        "lunarLabel": lunar.toString() if hasattr(lunar, "toString") else "",
    }

    lines = [_coins_to_line(coins, i + 1) for i, coins in enumerate(tosses)]
    primary_bits = [bool(item["isYang"]) for item in lines]
    changed_bits = [bool(item["changedIsYang"]) for item in lines]
    primary_hexagram = _build_hexagram(primary_bits)
    changed_hexagram = _build_hexagram(changed_bits)
    moving_lines = [int(item["line"]) for item in lines if item.get("isMoving")]
    day_gan = gan_zhi["day"][0] if gan_zhi.get("day") else ""
    base_six_relatives = _build_six_relatives(lines, day_gan, primary_hexagram)

    llm_parsed = None
    try:
        prompt = build_liuyao_prompt(
            question=question,
            gan_zhi=gan_zhi,
            primary_hexagram=primary_hexagram,
            changed_hexagram=changed_hexagram,
            lines=lines,
            six_relatives=base_six_relatives,
        )
        llm_raw = spark_chat(
            [
                {"role": "system", "content": prompt},
                {"role": "user", "content": "请输出六爻解读 JSON。"},
            ],
            recv_timeout=2,
            max_duration=4,
        )
        llm_parsed = parse_liuyao_response(llm_raw)
    except Exception as exc:  # noqa: BLE001
        print(f"[one_thing] llm parse fallback: {exc}")

    fallback_analysis = _default_liuyao_analysis(
        question=question,
        primary_hexagram=primary_hexagram,
        changed_hexagram=changed_hexagram,
        moving_lines=moving_lines,
    )
    if not isinstance(llm_parsed, dict):
        llm_parsed = fallback_analysis

    conclusion = _clean_text(llm_parsed.get("conclusion"))
    if conclusion not in {"吉", "平", "凶"}:
        conclusion = fallback_analysis["conclusion"]
    summary = _clean_text(llm_parsed.get("summary")) or fallback_analysis["summary"]
    five_elements = _clean_text(llm_parsed.get("fiveElements")) or fallback_analysis["fiveElements"]
    advice = _clean_text(llm_parsed.get("advice")) or fallback_analysis["advice"]
    six_relatives = _merge_six_relatives(base_six_relatives, llm_parsed.get("sixRelatives"))

    for item in six_relatives:
        if not _clean_text(item.get("note")):
            item["note"] = f"此爻以{item.get('role', '兄弟')}象为主，宜结合问事场景取象。"

    with get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO one_thing_divinations (
                    profile_id, divination_date, question, started_at,
                    ganzhi_year, ganzhi_month, ganzhi_day, ganzhi_hour, lunar_label,
                    tosses, lines, primary_hexagram, changed_hexagram, moving_lines,
                    conclusion, summary, five_elements, advice, six_relatives
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
                """,
                (
                    str(profile_id),
                    divination_date,
                    question,
                    started_local,
                    gan_zhi["year"],
                    gan_zhi["month"],
                    gan_zhi["day"],
                    gan_zhi["hour"],
                    gan_zhi["lunarLabel"],
                    psycopg2.extras.Json(tosses),
                    psycopg2.extras.Json(lines),
                    psycopg2.extras.Json(primary_hexagram),
                    psycopg2.extras.Json(changed_hexagram),
                    psycopg2.extras.Json(moving_lines),
                    conclusion,
                    summary,
                    five_elements,
                    advice,
                    psycopg2.extras.Json(six_relatives),
                ),
            )
            inserted = cur.fetchone()
    new_id = inserted[0] if inserted else None

    stored = fetch_one_thing_divination_by_id(profile_id, new_id, profile.get("timezoneId", "Asia/Shanghai"))
    if not stored:
        return jsonify({"error": "failed to persist divination"}), 500
    return jsonify(stored)


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


def spark_chat(messages, recv_timeout=15, max_duration=120):
    ws_url = create_signed_url()
    if not ws_url:
        return "服务端未配置 Spark 凭证，请联系管理员。"

    payload = build_spark_payload(messages)
    ws = websocket.create_connection(ws_url, timeout=recv_timeout, sslopt={"cert_reqs": ssl.CERT_NONE})
    ws.settimeout(recv_timeout)
    try:
        ws.send(json.dumps(payload))
        response_text = ""
        start_ts = time.time()
        while True:
            if max_duration and time.time() - start_ts > max_duration:
                raise TimeoutError("spark timeout")
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


def spark_chat_stream(messages, recv_timeout=45, max_duration=180):
    ws_url = create_signed_url()
    if not ws_url:
        yield "服务端未配置 Spark 凭证，请联系管理员。"
        return

    payload = build_spark_payload(messages)
    ws = websocket.create_connection(
        ws_url,
        timeout=recv_timeout,
        sslopt={"cert_reqs": ssl.CERT_NONE},
    )
    ws.settimeout(recv_timeout)
    start_ts = time.time()
    try:
        ws.send(json.dumps(payload))
        while True:
            if max_duration and time.time() - start_ts > max_duration:
                raise TimeoutError("spark stream timeout")
            try:
                raw = ws.recv()
            except (socket.timeout, websocket.WebSocketTimeoutException) as exc:
                raise TimeoutError("spark stream timeout") from exc
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
                else:
                    yield None
            else:
                yield None

            if status == 2:
                break
    finally:
        ws.close()


@app.post("/spark/chat")
def chat():
    payload = request.get_json(silent=True) or {}
    messages = payload.get("messages", [])
    profile_id = payload.get("profileId")
    tianshi_id = payload.get("tianshiId")
    if not isinstance(messages, list) or not messages:
        return jsonify({"error": "messages required"}), 400
    try:
        profile = fetch_profile(profile_id) if profile_id else {}
        chat_messages = build_chat_messages(messages, profile, tianshi_id)
        print(f"[chat] profileId={profile_id} tianshiId={tianshi_id} profile_found={bool(profile)}")
        print(chat_messages)
        answer = spark_chat(chat_messages)
        return jsonify({"content": answer})
    except Exception as exc:  # noqa: BLE001
        print(f"[chat_error] {exc}")
        return jsonify({"error": str(exc)}), 500


@app.post("/spark/chat/stream")
def chat_stream():
    payload = request.get_json(silent=True) or {}
    messages = payload.get("messages", [])
    profile_id = payload.get("profileId")
    tianshi_id = payload.get("tianshiId")
    if not isinstance(messages, list) or not messages:
        return jsonify({"error": "messages required"}), 400

    def generate():
        try:
            profile = fetch_profile(profile_id) if profile_id else {}
            chat_messages = build_chat_messages(messages, profile, tianshi_id)
            print(f"[chat_stream] profileId={profile_id} tianshiId={tianshi_id} profile_found={bool(profile)}")
            print(chat_messages)
            last_keep_alive = 0.0
            for chunk in spark_chat_stream(chat_messages):
                if chunk is None:
                    now = time.time()
                    if now - last_keep_alive >= 5:
                        yield ": keep-alive\n\n"
                        last_keep_alive = now
                    continue
                safe = chunk.replace("\r", "").replace("\n", "\\n")
                yield f"data: {safe}\n\n"
            yield "event: done\ndata: [DONE]\n\n"
        except Exception as exc:  # noqa: BLE001
            print(f"[chat_stream_error] {exc}")
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
    backfill_profile_locations()
    app.run(host="0.0.0.0", port=8000, debug=False)
