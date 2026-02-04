# DeepFate

DeepFate 是一款结合传统命理与 AI 的 iOS 应用，支持排盘、抽签、档案与对话等功能。

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
