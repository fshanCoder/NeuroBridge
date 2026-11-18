# NeuroBridge AI 设计说明

面向说话、听觉或运动能力受限的人，核心流程是选择自己能控制的输入方式，表达需求，看到对方的回应。照护者负责日常响应，医生负责查看经授权的长期变化。

| 原文依据 | 产品需求 | 设计落点 |
|---|---|---|
| 第 1、5–7 页 | 首次建档与日常沟通 | 首次进入登记向导，完成后直达沟通页。照护者代填时保留操作者身份 |
| 第 2–5 页 | 唇动、手势、眼动、姿态与语音 | 手机本地处理；低可信结果先确认，无法使用摄像头时仍可点选短语 |
| 第 4–5、10 页 | 求助与离线运行 | 本机立即反馈，远端分别显示待同步、已提交、已确认，保留误报标记 |
| 第 5–9 页 | 照护与康复随访 | 照护者看近期状态和求助，医生看基线、趋势、治疗记录与报告 |
| 第 9–11 页 | 权限、同步与隐私 | 按患者关系和同意用途授权，默认仅传结构化结果 |

## 运行当前版本

在项目根目录安装后端依赖并构建 Flutter Web。首次构建需要联网和 stable 版 Flutter SDK。

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r backend/requirements.txt
(cd frontend && flutter pub get && flutter build web --no-web-resources-cdn)
.venv/bin/python -m uvicorn backend.main:app --host 127.0.0.1 --port 8000
```

打开 [本机沟通板](http://127.0.0.1:8000)。首页可直接点选短语试用朗读。点击「Set up my board」，填写双方称呼并勾选分享许可；在「Link a caregiver device」中复制密钥。用另一款浏览器或独立无痕窗口打开同一地址，选择「Pair with a care board」，粘贴密钥。患者点「I need water」后，双方都能看到消息；点「Call for help」后，照护者点「Acknowledge request」，患者端会显示接手人的称呼。照护页面应保持打开。离开页面期间的待处理求助会在下次打开时显示。

开发调试可在 frontend 下执行 `flutter run -d chrome --web-port 8080 --dart-define=API_URL=http://127.0.0.1:8000`。Android 模拟器使用 `flutter run --dart-define=API_URL=http://10.0.2.2:8000`，iOS 模拟器可使用本机地址。为真机配置可访问的 HTTPS API 地址。API 文档位于 [本机 Swagger UI](http://127.0.0.1:8000/docs)。

### 当前实现边界

此版用于本机或受控环境演示。可选填写监护、验证电话、病史和联络资料；持有照护密钥的人有权查看该患者的表达和接手求助。凭证随应用本地存储，清除浏览器数据会清除本机身份和待同步队列。服务端 SQLite 文件默认位于 backend/care.sqlite3，可用 NB_DATABASE 指定路径。端侧队列使用平台偏好存储，每个事件携带设备生成的唯一 ID，恢复连接后重试。前台每三秒刷新；客户端关闭会停止轮询。在线启动的确认时限与投递任务由服务器继续处理。朗读依赖设备英文语音，声音和振动遵循平台能力。请使用虚构资料试用。

### 交互参考

- 固定位置的图文短语覆盖饮水、进食、如厕、休息和肯否回答，参考 [OpenAAC 的 CBoard 词表](https://www.openaac.org/vocabularies/cbc)。
- 短语选择后直接显示大字幕、调用设备朗读，并可单独重读，参考 [Leeloo AAC 的卡片与朗读交互](https://assistivecards.com/leeloo/)。

## 设计路线

1. 首版验证可手动完成的闭环：建档与授权 → 选短语 → 大字幕和本地朗读 → 离线留存 → 联网同步 → 照护确认 → 医生随访。
2. 采集经过同意的校准样本，再分输入方式验证端侧模型。分别统计候选确认率、误触发次数、响应延迟及各用户群的可用性。
3. 接入推送、短信、报告任务和个性化模型版本管理；真机验证断网、撤权、系统权限变化和端侧功耗后再讨论上线。

## 待确认的产品决策

原文同时列出 12 类模型情绪与 15–30 个手动选项。设计保留两个词表和来源字段。原文给出的检测时长与置信度仅作为可配置起点。康复百分比缺少权重和有效性依据，首版显示可复核的原始指标、样本量及变化量。后台摄像涉及设备能力及授权差异，首版限定用户主动开启的前台会话。

详细交互见 [前端设计](frontend/DESIGN.md)，接口、数据和告警时序见 [后端设计](backend/DESIGN.md)。

## Integrated care workspace

After setup, open **Care workspace**. In **Profile**, save the medical history and emergency contact and enable simulation. In **Recognition**, run demo calibration, choose a modality, run a sample, and confirm or correct a candidate. The timeline labels every sample as simulated. Lip-reading and gesture confirmations can also be spoken and shared. Custom gesture meanings appear in subsequent gesture samples.

**Progress** shows actual communication counts and simulated observation counts separately, with day, week and month windows. A patient can record a seven-day baseline. **Care team** supports replies, scheduled reminders and completion. Due reminders appear on the open board. Caregivers can acknowledge requests, mark false alarms and resolve requests. Patients can cancel open requests.

To grant a doctor access, create a doctor key in **Profile** and use **Pair with a care board** in a separate browser. The doctor can review the linked patient, record therapy notes and export a progress PDF. Replacing or revoking the key invalidates the previous credential. Only a doctor can request report data. Camera preview is opt-in and local. Recognition uses deterministic demo samples.

The **Language** tab connects to a small phrase cache and returns an explicit unavailable state for missing translations. Its personalization preview records a demo version and the count of confirmed samples. The app uses SQLite, scoped pairing keys and foreground polling for this integration phase. OTP and external notifications use the optional delivery adapter below.

## Safety checks and accessible input

On the patient board choose **Simulate safety signal**, or enable simulation, calibrate and run a **Fall detection**, **Eye movement** or **Head movement** sample in Recognition. The generated fall includes five seconds of stillness; the unresponsive sample includes ten seconds of inactivity. Change the thresholds in **Profile**. A qualifying signal opens **Are you okay?**. **I am okay** cancels the check, **Send help now** requests immediate help, and an unanswered check escalates at its deadline. The default response window is 15 seconds. Server time determines the outcome of a late response. Online checks survive patient-page closure and service restart. A check started offline is stored locally; the open client processes the deadline, or resumes it when reopened. Queued alerts are submitted after reconnection.

**Assisted communication** offers automatic scanning, pause, Space/Enter selection, and pointer dwell. Dwell can also be used with an assistive device that supplies pointer events. The safety prompt uses the same controls. Timing is adjustable in **Profile**. The additional needs include pain, medicine and calling family.

**My patients** lets a doctor switch among separately authorized boards on this device. Battery and location can be shared explicitly; last-seen time comes from patient board refreshes. **Progress** includes rolling comparisons, an optional clinician-set therapy start, hourly simulated moods and observed sample confirmation time. **Language** includes a bundled nine-language starter phrase dictionary. A previously calibrated patient can confirm simulated samples offline after opening their workspace online; observations sync with stable IDs.

### Optional notifications and phone verification

Set `NB_DELIVERY_URL` to your HTTPS provider adapter endpoint and optionally set `NB_DELIVERY_TOKEN` for bearer authorization. For alerts, the worker sends a JSON POST with channel, event ID, patient ID, message, creation time and configured emergency contact. The adapter maps these fields to the intended provider recipient and deduplicates by the `Idempotency-Key` header. Push is queued immediately and SMS becomes eligible after 60 seconds without acknowledgement. The worker retries failed attempts; acknowledgement or closure suppresses pending delivery. A successful HTTP response means the adapter accepted the request. Without an adapter, the board displays its unconfigured state. No external provider is required for board-to-board acknowledgement.

**Phone and guardian details** in enrollment supports optional phone verification and guardian consent for a minor. OTPs expire after five minutes. The OTP adapter receives the phone, code and channel. For local OTP testing only, `NB_DEMO_OTP=1` returns the demo code to the enrollment screen.

### Verification

Run `.venv/bin/python -m unittest discover -s backend`. For the browser regression suite, first build Flutter Web, install `httpx` and `playwright` in the test environment and make Google Chrome available. Run `.venv/bin/python tests/safety_browser.py` from the project root. The suite starts a temporary API process and isolated SQLite database. Run `.venv/bin/python tests/enrollment_browser.py` for guardian enrollment with a local test OTP.
