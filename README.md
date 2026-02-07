# DeepFate

**DeepFate** 是一款将传统命理与 AI 结合在一起的 iOS 应用：既有八字排盘、每日抽签、修心木鱼等经典玩法，也支持基于讯飞 Spark 的命理对话与「一事一测」解读，适合对传统文化和现代 AI 都感兴趣的开发者与用户。

---

## 项目介绍

DeepFate 面向「命理 + 智能」场景，在 iOS 端提供完整体验，后端使用 Python 提供排盘、档案与 AI 对话能力。

### 主要功能

| 功能 | 说明 |
|------|------|
| **今日运势 / 一事一测** | 每日一签，在卡面上画下符号即可抽签；支持结合当前档案请 AI 解读。 |
| **命理详批** | 基于生辰八字（含真太阳时）排盘，展示四柱、十神等命理信息。 |
| **每日锦囊** | 首页展示简短运势提示与能量标签。 |
| **AI 命理对话** | 多轮对话，可结合用户档案做运势、情感、命格等分析（流式输出）。 |
| **档案馆** | 多用户档案管理：姓名、性别、出生时间与地点，支持真太阳时与八字同步。 |
| **修心** | 五行修心与木鱼等轻量互动，用于放松与专注。 |

### 技术栈

- **iOS**：Swift、SwiftUI，XcodeGen 生成工程；依赖 MarkdownUI 等。
- **后端**：Python（Flask）、讯飞 Spark API（流式对话）、`lunar_python`（八字排盘）、PostgreSQL（档案与扩展数据）。
- **部署**：Docker Compose 一键起库 + 后端 + pgAdmin。

后端负责鉴权、系统提示词、排盘接口与档案 CRUD，App 通过 HTTP/SSE 调用；真机调试时可将 baseURL 指向本机或局域网后端。

---

## 项目结构

- **DeepFate/** — iOS 客户端（Swift / SwiftUI）
- **backend/** — 后端服务（Python、Spark API、排盘、Docker 部署）
- **project.yml** — XcodeGen 配置，用于生成 Xcode 工程

## 环境要求

- **iOS**：Xcode 15+，iOS 16.0+
- **后端**：Python 3.10+ 或 Docker

## 快速开始

### 1. 生成并打开 iOS 工程

```bash
# 安装 XcodeGen（若未安装）
brew install xcodegen

# 在项目根目录
xcodegen generate
open DeepFate.xcodeproj
```

在 Xcode 中选择真机或模拟器运行即可。

### 2. 启动后端

本地开发可参考 [backend/README.md](backend/README.md) 配置 Python 虚拟环境与 `.env`；生产环境推荐使用 Docker：

```bash
cd backend
cp .env.example .env   # 编辑 .env 填入 Spark 等配置
docker-compose up -d
```

## 许可证

本项目采用 [MIT 许可证](LICENSE)。
