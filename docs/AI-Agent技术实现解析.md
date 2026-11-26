# AI Agent 技术实现解析（面试向）

> 代码位置：`fastapi/agent/`（注册表 / 主管 / 模型工厂 / 工具）+ `fastapi/routers/agent.py`（SSE 编排）+ `fastapi/services/agent_service.py`（会话与配置）
> 依赖：LangChain 1.4.6 / LangGraph 1.2.16 / langgraph-supervisor 0.0.31 / langchain-deepseek 1.1.1

---

## 一、整体架构：Supervisor 模式的多智能体

两套场景各自独立建图，互不干扰：

| 场景 | 接口 | 主管 | 子 Agent |
|---|---|---|---|
| 用户端「开黑小助手」 | `POST /agent/chat` | `supervisor_user` | `recommendation_agent` `order_agent` `faq_agent` |
| 管理端「经营分析师」 | `POST /agent/analysis/chat`（仅管理员） | `supervisor_analyst` | `metrics_agent` `sql_agent` |

### 实际编译出的图（实测 dump）

```
用户端                                  管理端
节点: __start__ supervisor              节点: __start__ supervisor
      recommendation_agent                    metrics_agent
      order_agent                             sql_agent
      faq_agent                       
边:   __start__ -> supervisor             边:   __start__ -> supervisor
      supervisor -> {3 个子 Agent} 条件边        supervisor -> {2 个子 Agent} 条件边
      {3 个子 Agent} -> supervisor           {2 个子 Agent} -> supervisor
      supervisor -> __end__ 条件边             supervisor -> __end__ 条件边
```

三个关键点：

1. **主管不带任何工具**，它唯一的职责是"决定交给谁"。业务能力全在子 Agent 身上。
2. **边是条件边**，路由由 LLM 调用移交工具的结果决定，不是写死的 if-else。
3. **子 Agent 执行完一定回到 supervisor**，由主管统一组织最终答复后再结束——保证用户只看到一个完整答案。

### 代码分层

```
agent/
├── registry.py     # AgentSpec 注册表(唯一事实来源) + build_supervisor
├── llm.py          # 大模型工厂(ChatDeepSeek)
├── user_assistant.py  # 用户端图构建
├── analyst.py      # 管理端图构建
└── tools/
    ├── user_tools.py  # 业务工具(推荐/订单/FAQ)
    ├── stat_tools.py  # 预置经营指标工具
    └── sql_tools.py   # NL2SQL 安全沙箱
```

---

## 二、主管层：LangGraph Supervisor

`registry.build_supervisor()` 调 `langgraph_supervisor.create_supervisor`：

```python
create_supervisor(
    worker_agents,                      # 子 Agent 列表
    model=model,                        # 主管模型
    prompt=prompt,                      # 主管系统提示词
    supervisor_name="supervisor",
    output_mode="last_message",         # 关键: 子 Agent 只回传最后一条消息
)
```

### Handoff（移交）机制

langgraph-supervisor 会**自动为每个 worker 生成一个移交工具**：

```
transfer_to_recommendation_agent
transfer_to_order_agent
transfer_to_faq_agent
```

主管 LLM 看到这三个工具，调用 `transfer_to_order_agent` 即可移交。内部实现是返回 `Command(goto=...)`，LangGraph 依此走条件边跳进对应子图。

### output_mode="last_message" 为什么重要

子 Agent 干活时会产生大量中间内容：思考、工具调用参数、原始工具返回。如果全部塞回主管上下文：

- 上下文被污染，主管容易被工具原始数据带偏
- token 成本爆炸（工具返回往往几千字符）

`last_message` 只把子 Agent 的**最终自然语言答复**回传给主管，中间过程丢弃。

配合 `add_handoff_messages=True`（默认），移交时补一对 `(AIMessage, ToolMessage)` 让多轮路由的上下文自洽。

---

## 三、子 Agent 层：ReAct 循环

每个专职 Agent 用 `langgraph.prebuilt.create_react_agent` 构建：

```python
create_react_agent(
    model=build_llm(temperature),   # 每个 Agent 独立模型实例(独立温度)
    tools=spec.tools_builder(user_id),
    name=spec.key,                  # 图中节点名 = 注册键, 主管按此移交
    prompt=prompt,
)
```

ReAct = Reason + Act，循环结构：

```
用户问题 → LLM 思考
              ├─ 要调工具？→ 执行工具 → 结果回灌 → 再思考（循环）
              └─ 不用调了 → 输出自然语言答复 → 移交回 supervisor
```

**每个 Agent 有独立的 prompt、独立 temperature、独立的工具集**，互不干扰。这是"多智能体"和"一个大提示词塞所有规则"的本质区别：上下文窗口小、职责清晰、可单独灰度。

---

## 四、动态配置：DB 驱动的 Agent 热更新

这是本项目最有工程价值的设计之一——**Agent 的提示词、温度、启停状态存在数据库里，管理后台改完下次对话立即生效，不用重启服务**。

### 数据流

```
agent_config 表(prompt/temperature/enabled)
        ↓ get_effective_configs(scene)
services/agent_service.py  (开短会话读 DB, 异常时返回空字典)
        ↓
build_user_assistant / build_analyst  (每次请求重新构建图)
        ↓
create_react_agent(prompt=DB值 or 注册表默认值, temperature=...)
```

### 三层降级策略

| 层级 | 情况 | 行为 |
|---|---|---|
| 1 | DB 无该 Agent 记录 | 用 `registry.py` 里的代码默认值 |
| 2 | DB 读取失败（表不存在/连不上） | `get_effective_configs` 捕获异常返回 `{}`，全部回退默认值，**不阻断对话** |
| 3 | 某子 Agent `enabled != 0`（停用） | 该 Agent 不进图，同时从主管提示词的"当前可用助手"名单里剔除 |
| 4 | 所有子 Agent 都停用 | 退化为**无工具单 Agent**，主管直接对话并告知"能力维护中" |

### 为什么要每次请求重建图

图是**纯内存组装**，开销可忽略；而重建换来的是「配置即时生效」。这是典型的 **配置与代码分离**：代码是唯一事实来源（工具清单、Agent 身份），DB 只覆盖运行时可变的部分（提示词、温度、启停）。

> 注意 `agent_config.enabled` 语义是 **0 启用 / 1 停用**（与直觉相反），代码里到处在写 `enabled != 0 → skip`。

---

## 五、工具层：三种工厂，两种安全模型

工具用 `@tool` 装饰器，**docstring 就是 LLM 看到的工具说明**——写好 docstring 就是写好 prompt。

### 1. 公共工具（不涉及用户数据）

```python
build_recommendation_tools()  # search_companions / get_companion_detail / list_games
build_faq_tools()             # search_faq / list_notices
build_stat_tools()            # 5 个预置经营指标
```

### 2. 用户私有工具：闭包绑定 user_id（关键安全设计）

```python
def build_order_tools(user_id: int) -> list:
    @tool
    def query_my_orders(status=None, limit=10) -> str:
        # user_id 来自闭包, 不在函数签名里
        _, rows = order_service.select_my_orders(db, user_id, status, 1, ...)
```

**为什么 user_id 不放进工具参数？**

如果写成 `query_my_orders(user_id: int)`，user_id 就会出现在 LLM 的工具 schema 里，模型可能填别人的 ID 去查别人的订单——**提示词约束不是安全边界**。用闭包把 user_id 焊死在服务端，**LLM 根本没有伪造的入口**，参数 schema 里根本不存在这个字段。

同理 `get_order_detail` 查不到就返回"订单不存在或不属于当前用户"，不区分两种情况，**不泄露订单是否存在**。

### 3. NL2SQL 安全沙箱（sql_tools.py）—— 面试重点

`sql_agent` 是自由查询兜底：预置指标覆盖不到的问题，让 LLM 自己写 SQL。安全上做了**五重防护**：

| # | 防护 | 实现 |
|---|---|---|
| 1 | 语句类型 | `sqlparse.parse()` 解析后 `get_type() != "SELECT"` 直接拒 |
| 2 | 多语句 | `sqlparse.split()` 后语句数 ≠ 1 直接拒（防分号拼接注入） |
| 3 | 危险片段 | 正则黑名单：`INTO OUTFILE` `DUMPFILE` `FOR UPDATE` `LOCK IN` `load_file` `/* */` `--` `;` |
| 4 | 表名白名单 | 正则提取 from/join/into 后的表名，与 19 张业务表白名单求差集，多出的拒。**权限表 menu/role/role_menu 不在白名单内** |
| 5 | 结果兜底 | 无 LIMIT 自动包 `LIMIT 1000`；结果剔除 `password` 列；序列化超 8000 字符截断 |

### 关键设计：校验失败不抛异常，而是"还给 LLM"

```python
error = _validate(sql)
if error:
    return json.dumps({
        "error": error,
        "hint": "请调整 SQL 后重试, 仅允许单条 SELECT 且只能查白名单业务表"
    }, ensure_ascii=False)
```

被拒绝的 SQL **不会让整个请求失败**，而是把拒绝原因 + 修正提示作为工具返回值交给 LLM，LLM 自己改写后重试。这构成了一个**自愈循环**：模型第一次写错了，第二轮自己纠正。实测中 Agent 遇到被拒的 SQL 会自动调整口径重试。

同理，`get_table_schemas` 工具先让 LLM 读表结构再写 SQL——**把 schema 显式喂给模型，比让模型猜表名字段名可靠得多**。

---

## 六、流式输出：SSE 协议

`routers/agent.py` 的 `_event_stream()` 是整个 AI 链路的输出层。

### 四种事件

| 事件 | 载荷 | 前端用途 |
|---|---|---|
| `status` | `{agent, tool, targetAgent, msg}` | 渲染"已移交「陪玩推荐专家」处理"进度气泡 |
| `token` | `{content}` | 打字机增量文本；`{content:"", reset:true}` 表示清空 |
| `done` | `{conversationId, messageId, title}` | 更新会话列表与标题 |
| `error` | `{msg}` | 异常提示（SSE 已是 200，业务错误走事件） |

### 消费机制

```python
async for ev in graph.astream_events({"messages": messages}, version="v2"):
```

`astream_events(v2)` 是 LangGraph 官方通用流式接口，对 supervisor **嵌套子图**也能拿到事件。

### 关键技巧：checkpoint_ns 区分 token 归属

```python
owner = str(meta.get("checkpoint_ns", "")).split(":", 1)[0].split("|", 1)[0]
if kind == "on_chat_model_stream":
    if owner in _WORKER_KEYS:   # 子 Agent 的 token 全部丢弃
        continue
```

`checkpoint_ns` 形如 `supervisor:uuid|agent:uuid`，首段就是产出该 token 的节点名。**只有 supervisor 的 token 外发给前端**，子 Agent 的中间输出不干扰正文。

### reset 事件：移交时的"清屏"

主管在决定移交前可能已经吐了一段开场白（如"我来帮你找找"），这段不是最终答案。代码检测到移交时若已有文案，就发一个 `reset` 事件让前端清空并重计：

```python
if answer_text:
    answer_text = ""
    await queue.put(("token", {"content": "", "reset": True}))
```

### 心跳保活

生产协程把事件塞进 `asyncio.Queue`，消费端 `asyncio.wait_for(queue.get(), timeout=15)`，超时发 SSE 注释行 `: ping`（前端忽略）。**防止 vite 代理 / 浏览器空闲断连**。模型思考超过 15 秒时不会卡死。

---

## 七、模型层

```python
ChatDeepSeek(
    model=settings.deepseek_model,
    api_key=settings.deepseek_api_key,
    api_base=settings.deepseek_base_url,   # 可指向中转网关
    temperature=temperature,                # 每个 Agent 独立
    timeout=60,
    max_retries=1,
    streaming=True,
    extra_body={"thinking": {"type": "disabled"}},
)
```

**`streaming=True` 是必须的**：supervisor 图内嵌套 `ainvoke` 时，只有 token 级 chunk 才能冒泡到 `astream(messages)`。

**`thinking: disabled` 是个踩坑后的修复**：思考模式下带 tools 的多轮请求必须完整回传 `reasoning_content`，而 LangChain 不会回传，DeepSeek 会报 400（`The reasoning_content ... must be passed back`）。业务 Agent 不需要思维链，关掉后响应更快更省 token。

---

## 八、会话与数据持久化

### 上下文注入

```python
history = agent_service.history_messages(db, conversation_id)  # 最近 20 条
messages = [("human" if h["role"] == "user" else "assistant", h["content"]) for h in history]
```

`HISTORY_WINDOW = 20`，**最近 20 条消息**（含本轮输入）注入 LLM 上下文。超出部分靠数据库留存但不入上下文——典型的**上下文窗口 + 持久化分离**。

### 会话生命周期

```
新对话 → create_conversation(scene) → conversation_id
       → append_message(user) → touch_title(首轮取输入前 20 字)
       → history_messages → 构建图 → SSE 流
       → final 时 append_message(assistant, agent_name)
       → 发 done(conversationId, messageId, title)
```

### agent_name 字段的妙用

`agent_message.agent_name` 记录"这条回复主要由哪个 Agent 贡献"。按它聚合就是**近 30 天各 Agent 调用次数**（`agent_call_stats`），管理页的 Agent 调用统计直接由此而来。**同一份数据既是对话历史，也是运营指标。**

---

## 九、容错全景

| 故障点 | 处理 |
|---|---|
| DB 读 agent_config 失败 | 捕获异常返回 `{}`，回退代码默认值，不阻断对话 |
| 所有子 Agent 被停用 | 退化为无工具单 Agent，主管告知能力维护中 |
| LLM 生成的 SQL 不安全 | 校验拒绝 + 返回 hint，LLM 自愈重试 |
| 工具执行报错 | 捕获异常，把错误信息作为工具返回给 LLM 自行修正 |
| 模型/网络异常 | `produce()` 捕获 → 发 `error` 事件 → 结束哨兵 |
| 全程无有效输出 | 发 `error` 事件"AI 助手暂时没有生成答复" |
| 客户端中途断开 | `finally` 中 `producer.cancel()`，回收后台协程 |

---

## 十、面试高频问题与回答要点

**Q：为什么用 Supervisor 而不是 Agent 自主协商（A2A）？**
Supervisor 路由是**中心化的、可控的**：路由决策集中在一个节点，便于加权限、便于埋点、便于降级。A2A 自主协商在生产里难以控制成本和循环次数。

**Q：多智能体相比一个大 Agent + 长提示词，优势在哪？**
① 上下文小，每个 Agent 只装自己那点知识；② 可单独灰度（停用一个不影响其他）；③ 权限可按 Agent 粒度控制（订单 Agent 绑 user_id，统计 Agent 不绑）；④ 职责清晰，便于定位问题。

**Q：NL2SQL 的安全怎么保证？光靠提示词够吗？**
不够。提示词是软约束，模型可能不遵守。真正的安全边界必须在**执行层**：语句类型校验 + 多语句拦截 + 危险关键字黑名单 + 表白名单 + 限行 + 敏感列剔除。本项目六层全在代码里，不依赖模型自觉。

**Q：为什么校验失败不直接报错？**
把错误信息连同 hint 返回给 LLM，让它在同一轮里改写重试，形成自愈；直接报错则整个对话失败，用户体验更差。

**Q：SSE 断连怎么处理？**
生产协程与消费端解耦（asyncio.Queue），15 秒无产出发 `: ping` 心跳保活；客户端断开时在 `finally` 里 cancel 生产协程，避免后台任务泄漏。

**Q：怎么防止子 Agent 的中间输出污染最终答复？**
两道：图层面 `output_mode="last_message"` 让中间消息不进主管上下文；流式层面用 `checkpoint_ns` 判断 token 归属，只透出 supervisor 的 token。

**Q：Agent 配置怎么做到不发版就改？**
提示词/温度/启停存 `agent_config` 表，每次请求重建图时读取。代码注册表是唯一事实来源（决定 Agent 身份和工具），DB 只覆盖运行时可变部分。

**Q：这个架构的成本瓶颈在哪？**
① 每次请求重建图 + 建 5 个 LLM 实例（连接池开销）；② 多 Agent 移交 = 多轮 LLM 调用，token 与延迟叠加；③ 长上下文（20 条历史 + 工具返回）仍是主要 token 消耗点。
