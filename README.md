# GameMate‑Agent · 一起开黑吧

> 游戏陪玩交易多智能体平台。基于 **LangGraph Supervisor** 实现 C 端 AI 智能助手与 B 端经营数据分析 Agent，集成 NL2SQL 安全查询、RBAC 权限、SSE 流式输出、WebSocket 实时通讯。

## ✨ 项目特性

- **完整业务后端**：FastAPI + SQLAlchemy 2.0 + MySQL，28 张业务表，RBAC 四类角色权限（管理员 / 用户 / 陪玩师 / 客服），事务保障订单资金一致性
- **Multi‑Agent Supervisor 架构**：4 个 C 端业务 Agent + 3 个 B 端数据分析 Agent，共享状态协同，支持降级兜底
- **可配置 Agent**：数据库存储提示词、模型参数、启停状态，会话持久化
- **NL2SQL 安全沙箱**：表白名单、只读限制、敏感列过滤、行数限流，防范越权查询
- **SSE Token 流式输出 + ping 心跳保活**；WebSocket 实现私聊消息；ECharts 6 运营数据看板

## 🛠 技术栈

| 层 | 技术 |
|---|---|
| 后端 | Python 3.10+、FastAPI、SQLAlchemy 2.0、PyMySQL、PyJWT、Pydantic Settings |
| AI | LangChain、LangGraph、langgraph‑supervisor、langchain‑deepseek |
| 数据库 | MySQL 8.0 |
| 前端 | Vue 3、Vite 7、Pinia、Vue Router、Tailwind CSS 4、ECharts 6、Axios、markdown‑it |

## 📁 目录结构

```
gaming-buddy/
├── fastapi/                 # 后端服务
│   ├── main.py              # 应用入口(uvicorn main:app --port 8080)
│   ├── core/                # 配置 / 数据库 / 依赖 / 异常 / 安全 / WebSocket
│   ├── models/entities.py   # 28 张表的 SQLAlchemy ORM 实体
│   ├── schemas/             # 请求体与响应模型(Pydantic)
│   ├── routers/             # 141 个 HTTP 接口
│   ├── services/            # 业务逻辑层
│   ├── agent/               # 多智能体编排(注册表 / 主管 / 工具工厂)
│   └── .env.example         # 配置模板(复制为 .env 后填值)
├── vue/                     # 前端项目
│   ├── src/api/             # 按业务域拆分的接口封装
│   ├── src/views/           # 页面(C 端商城 / B 端后台)
│   └── vite.config.js       # 开发代理: /base -> http://localhost:8080
└── gaming-buddy.sql         # 数据库全量脚本(含种子数据)
```

## 🚀 快速启动

### 0. 环境要求

- Python 3.10+（已在 3.13 验证）
- Node.js 18+（已在 22 验证）
- MySQL 8.0+（已在 8.0.46 验证）

### 1. 准备数据库

```bash
mysql -uroot -p -e "CREATE DATABASE \`gaming-buddy\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql -uroot -p --default-character-set=utf8mb4 gaming-buddy < gaming-buddy.sql
```

> `gaming-buddy.sql` 来自 Navicat 导出，包含建表语句 + 全量种子数据（陪玩师 32 位、订单 5 笔、Agent 配置 7 条等），导入后即可直接体验。

### 2. 启动后端

```bash
cd fastapi
python -m venv .venv
# Windows: .venv\Scripts\activate    Linux/macOS: source .venv/bin/activate
pip install -r requirements.txt
```

复制配置模板并填入自己的值：

```bash
cd fastapi
cp .env.example .env        # Windows: copy .env.example .env
```

`.env` 关键项：

| 配置项 | 说明 |
|---|---|
| `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` / `DB_NAME` | MySQL 连接信息，库名默认 `gaming-buddy` |
| `TOKEN_SECRET` | JWT 签名密钥，自行生成：`python -c "import secrets; print(secrets.token_hex(32))"` |
| `DEEPSEEK_API_KEY` | 大模型 API 密钥 |
| `DEEPSEEK_BASE_URL` | 接口地址，可指向中转网关 |
| `DEEPSEEK_MODEL` | 模型名，如 `deepseek-flash` / `deepseek-chat` |

启动：

```bash
# 方式一：直接运行 main.py(内置 8080 端口 + 热重载 + 彩色日志)
python main.py

# 方式二：uvicorn 命令
uvicorn main:app --host 0.0.0.0 --port 8080 --reload
```

启动成功会打印 `数据库连接正常 (MySQL x.x.x)` 与访问地址，接口文档在 <http://localhost:8080/docs>。

### 3. 启动前端

```bash
cd vue
npm install
npm run dev
```

访问 <http://localhost:90/>（开发服务器已配置 `/base` → `http://localhost:8080` 代理，无需处理跨域）。

生产构建：

```bash
npm run build      # 产物在 vue/dist
npm run preview
```

### 4. 默认账号

| 用户名 | 密码 | 角色 | 说明 |
|---|---|---|---|
| `admin` | `admin` | 管理员 | 可进入管理后台、经营分析 Agent、系统管理 |
| `张三` | `123456` | 普通用户 | 可下单、充值、体验 C 端 AI 助手 |
| `软软兔` | `123456` | 陪玩师 | 可接单、管理服务项目 |

> ⚠️ 正式部署前请立即修改所有默认密码。

## 🤖 多智能体说明

| 场景 | Agent | 职责 |
|---|---|---|
| 用户端 | `supervisor_user` | 主管：理解需求并分派、整合答复 |
| 用户端 | `recommendation_agent` | 按游戏 / 预算 / 性别 / 评分筛选陪玩师 |
| 用户端 | `order_agent` | 查询本人订单、优惠券、钱包余额 |
| 用户端 | `faq_agent` | 平台规则、下单流程、售后、公告问答 |
| 管理端 | `supervisor_analyst` | 主管：分派分析任务并整合结论 |
| 管理端 | `metrics_agent` | 看板 / 订单趋势 / 陪玩师排行 / 投诉 / 用户增长 |
| 管理端 | `sql_agent` | NL2SQL 兜底：先读表结构，再生成只读 SELECT |

Agent 的提示词、温度、启停状态存于 `agent_config` 表，可在 **管理后台 → Agent 管理** 中在线修改，下次对话立即生效；工具清单由代码注册决定，管理页只读回显。

## ⚠️ 安全提醒

- 敏感配置统一通过 `fastapi/.env` 管理，`.env` 已被 `.gitignore` 排除，仓库中只保留 `.env.example` 模板，**请勿提交密钥文件**
- `DB_PASSWORD` 含 `@` `:` `/` 等特殊字符时无需手动转义，连接串会自动做 URL 编码
- `TOKEN_SECRET` 变更后，已签发的 token 全部失效
- 生产部署建议将 `DOCS_ENABLED` 改为 `false` 关闭接口文档页

## 🐛 常见问题

**启动报 `Can't connect to MySQL server`**
检查 `.env` 中数据库配置是否与实际一致；确认 MySQL 服务已启动、端口 3306 未被占用。

**启动直接退出且看不到报错**
`main.py` 的数据库校验失败时会 `os._exit(1)` 终止进程，stdout 缓冲可能来不及输出。手动执行一次 `python -c "from core.database import engine; ..."` 或直接看 MySQL 是否可连接。

**前端请求 404 / 401**
开发环境请走 `http://localhost:90/base/xxx`（由 Vite 代理转发到后端）；401 表示 token 失效，重新登录即可。

**AI 助手无响应或报模型错误**
确认 `DEEPSEEK_API_KEY` 有效、`DEEPSEEK_MODEL` 与账号权限匹配；可在管理后台查看 Agent 调用情况。
