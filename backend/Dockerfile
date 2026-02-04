# DeepFate 后端：Spark 代理 + 排盘 + PostgreSQL
FROM python:3.12-slim

WORKDIR /app

# 先装依赖，便于利用镜像层缓存
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 应用代码与数据文件
COPY spark_server.py .
COPY locations.json .
COPY profiles.json .

# 运行时通过 env_file / environment 注入 .env 和数据库连接
EXPOSE 8000
CMD ["python", "spark_server.py"]
