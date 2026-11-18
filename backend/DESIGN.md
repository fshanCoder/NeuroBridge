# FastAPI 服务设计

客户端通过 HTTPS 写入事件，SQL Server 持久化，后台任务处理外部通知、聚合和导出。WebSocket 推送状态变更；重连时用游标补取事件。对象存储保存授权样本、按用户版本化的模型及有期限的报告。原始视频默认留在设备端。

## 接口契约（统一前缀 /v1）

| 方法与路径 | 请求 / 返回 | 权限 |
|---|---|---|
| POST /auth/otp、/auth/verify、/auth/refresh | 手机号、一次性验证码或刷新凭证；验证后签发短期访问令牌 | OTP 限速、一次性消费 |
| GET、PATCH /patients/{id} | 档案与版本；修改携带预期版本，冲突返回 409 | 本人、授权代管人；医生按授权只读 |
| POST /patients/{id}/consents | 用途、授权或撤回、代理人依据、生效时间 | 本人或已核验监护人 |
| POST /patients/{id}/events | 批量设备事件；逐项返回接受、重复或校验失败 | 已绑定设备或允许该操作的成员 |
| POST /patients/{id}/alerts | 设备生成的 alertId、原因、发生时间、可选定位及定位时间；返回状态 | 本人或绑定设备 |
| POST /alerts/{id}/acknowledge、/resolve | 操作 ID、备注、误报标记；返回接手人和更新时间 | 关联照护者 |
| GET /patients/{id}/status、/events?after= | 最新状态、来源时间或游标分页 | 已授权成员 |
| WS /patients/{id}/live | 认证后订阅，消息含事件游标 | 每次订阅校验患者关系，撤权断开 |
| GET /patients/{id}/progress | 起止日期、粒度；返回基线、分子分母、缺测和变化量 | 本人及获授权成员 |
| POST /patients/{id}/notes、/reports | 治疗记录或报告区间；报告返回 202 和任务 ID | 关联医生 |
| GET /reports/{id} | 任务状态或短期下载地址 | 当前仍获授权的申请人 |

聊天回复作为 communication 事件写入并经订阅分发。翻译、个性化训练、设备令牌注册及提醒调度分别由独立服务模块承接；训练前与发布模型前复核授权，模型保留回滚版本。

## SQL Server 实体

账户 Account 与患者 Patient 分离；PatientMember(patientId, accountId, role, scope, validUntil) 表示多对多照护关系。Consent 保存用途、授权人、授予及撤回时间。MedicalHistory、EmergencyContact、Hospital 按患者关联。Device 保存设备归属、最近上线和推送令牌。

Event 保存 UUID、patientId、deviceId、deviceSequence、occurredAt、receivedAt、kind、schemaVersion、payload；按种类校验文本、语言、置信度、候选、确认和修正字段。唯一键 (deviceId, deviceSequence) 去重，(patientId, occurredAt) 索引支持时间线。修正追加引用原事件的新记录。Baseline、DailyMetric、TherapyNote、ReportJob 保存对照数据与报告；ModelVersion、Reminder 和 AuditEntry 管理模型、提醒及访问记录。

## 告警一致性

Alert 记录触发、取消、接手与关闭；Delivery 独立记录每位联系人的每个渠道、尝试次数、提供方回执和错误。创建告警与写入 Outbox 使用同一事务。工作进程发送推送，再按联系策略发送短信；定位缺失仍发送原因与时间。提供方回执仅代表渠道状态。超时未接手则升级下一联系人；可选电话和医院通知需配置。接手用条件更新，重复点击返回现有接手人。

设备离线时先事务写入 SQLite。联网后按设备顺序重放，保留原始发生时间；对同一离线期间已经取消的告警，一并同步生命周期，服务端先归并状态再决定是否通知。任务重试复用投递键，供应商结果不明时核对回执。撤权后禁止补传被撤用途的数据。

## 验收场景

两个照护者同时接手只产生一次状态转移；重复上报同一告警只创建一条记录；跨患者读取和已撤权订阅被拒绝；断线重连可补齐消息；缺少基线时返回缺测原因；报告下载时复核关系。敏感字段加密、传输使用 TLS，导出与删除覆盖对象存储和派生数据，审计保留操作主体、时间与用途。
