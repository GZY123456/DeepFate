# Spark 后端服务 (Python)

这是一个最小化的后端服务，用于处理 Spark API 的鉴权、系统提示词管理以及流式响应。

## 安装依赖

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 配置环境变量

设置以下环境变量：

```bash
export SPARK_APP_ID="你的_app_id"
export SPARK_API_KEY="你的_api_key"
export SPARK_API_SECRET="你的_api_secret"
export SPARK_URL="wss://spark-api.xf-yun.com/v1/x1"
export SPARK_DOMAIN="spark-x"
export SPARK_SYSTEM_PROMPT="你的系统提示词"
```

## 启动服务

```bash
python spark_server.py
```

服务将在 `http://0.0.0.0:8000` 启动。

## Docker 部署（推荐上线使用）

后端已封装为 Docker 服务，与 PostgreSQL 一起编排：

```bash
cd backend
docker-compose up -d
```

- **db**：PostgreSQL（端口 5432）
- **backend**：Python 后端（端口 8000），内含排盘库 `lunar_python` 及 Spark 代理
- **pgadmin**：数据库管理（端口 8080）

首次启动会构建 `backend` 镜像；`.env` 中的 Spark 等配置会通过 `env_file` 注入，数据库连接在容器内自动指向 `db`。  
上线到服务器时，将 `backend` 目录（含 `Dockerfile`、`docker-compose.yml`、`.env`）拷贝或从 Git 拉取后，在同一目录执行 `docker-compose up -d` 即可。

## 测试接口

### 1. 测试握手接口（已弃用）

```bash
curl http://127.0.0.1:8000/spark/handshake
```

预期响应：

```json
{
  "app_id": "你的_app_id",
  "ws_url": "wss://spark-api.xf-yun.com/v1/x1?authorization=...&date=...&host=..."
}
```

### 2. 测试聊天接口（非流式）

```bash
curl -X POST http://127.0.0.1:8000/spark/chat \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"你好"}],"profileId":"PROFILE_ID"}'
```

响应示例：

```json
{
  "content": "你好！有什么我可以帮助你的吗？"
}
```

### 3. 测试流式聊天接口（推荐）

```bash
curl -N -X POST http://127.0.0.1:8000/spark/chat/stream \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"你好"}],"profileId":"PROFILE_ID"}'

### 4. 测试档案存储（JSON）

```bash
curl -X POST http://127.0.0.1:8000/profiles \
  -H "Content-Type: application/json" \
  -d '{"id":"PROFILE_ID","name":"张三","gender":"男","location":"广东深圳南山","solar":"1994-05-10 08:00","lunar":"一九九四年四月初一 08:00","trueSolar":"1994-05-10 08:16"}'
```

### 5. 查看档案列表

```bash
curl http://127.0.0.1:8000/profiles
```
```

响应格式（SSE 流式）：

```
data: {"delta": "你"}

data: {"delta": "好"}

data: {"delta": "！"}

data: {"done": true}
```

### 4. 测试省市区数据源

```bash
curl http://127.0.0.1:8000/locations
```

## 接口说明

### `POST /spark/chat/stream`（推荐使用）
- **功能**：实时流式返回 AI 响应（SSE）
- **请求体**：`{"messages": [{"role": "user", "content": "..."}]}`
- **响应**：Server-Sent Events (SSE) 流，逐段推送内容
- **用途**：App 端实现打字机效果

### `POST /spark/chat`（备用）
- **功能**：一次性返回完整 AI 响应
- **请求体**：`{"messages": [{"role": "user", "content": "..."}]}`
- **响应**：`{"content": "完整回复内容"}`

### `GET /spark/handshake`（已弃用）
- **功能**：返回签名后的 WebSocket URL
- **说明**：旧版接口，现在推荐使用 `/spark/chat/stream`

## 架构说明

- **系统提示词**：在服务端配置（环境变量 `SPARK_SYSTEM_PROMPT`）
- **工具链配置**：在服务端的 `gen_params()` 中定义
- **多轮对话**：App 发送完整对话历史，服务端组装后转发给 Spark API
- **流式响应**：服务端接收 Spark 的 WebSocket 流，转为 SSE 推送给 App

## 注意事项

1. **真机测试**：将 `baseURL` 改为电脑的局域网 IP（如 `http://10.10.13.2:8000`）
2. **环境变量**：每次重启终端需要重新 `export` 环境变量
3. **端口占用**：默认使用 8000 端口，如需修改请在代码中更改
