# 本地 API 与导航回放

SimVirtualLocation 保留地图窗口作为观察面，也可通过 `./simvirtual` 命令控制。命令与界面使用同一个 LocationController。回放控制不需要点击界面，也不需要 HTTP 服务。

## 构建与启动

```sh
./build-api.sh
./simvirtual launch
./simvirtual simulators
./simvirtual configure '{"simulator":"填入上一条返回的 UDID","speed_kmh":36,"interval_s":1}'
./simvirtual load-route examples/audrive-carlton-route9-stage1.geojson
./simvirtual start
./simvirtual status
```

构建是增量 Debug 构建，不清理旧产物。App 在 `build/Build/Products/Debug/SimVirtualLocation.app`，CLI 在 `build/cli/`。启动前退出另一个正在运行的旧版 App。模拟器必须已启动，API 要求明确选择一个 iOS 模拟器。

`start` 异步注入，响应的 `injection_status` 首先为 `starting`；继续查询 `status`，`active` 表示 simctl 已确认开始。原轨迹模拟器回放的本地观察标记到达文件终点只代表估计位置到达，仍保持 `active`，不会据此清除 simctl 场景或宣称设备已完成；需要用户调用 `stop` 清理后才能重新 `start`。失败为 `failed` 并带 `injection_error`。CLI 的 `ok:false` 会退出非零；收到请求与模拟器已开始移动是两个状态。

```sh
./simvirtual configure '{"speed_kmh":54}'
./simvirtual pause
./simvirtual resume
./simvirtual stop
./simvirtual route > original-route.json
./simvirtual debug > route-feedback.json
```

- 速度为 km/h，回放使用正数，最大 200。停止移动用 `pause`；运行时设 0 会暂停，恢复前需设正数。
- 间隔为 0.5–2 秒。更换目标或间隔前先停止。`pause` 保留位置和路线；`resume` 从保存的位置继续；`stop` 后再次 `start` 从头回放。
- `estimated_position` 是 Mac 观察标记的估计坐标 `[longitude,latitude]`，不是 iPhone 的定位回执。`requested_speed_mps` 也是请求值，实际读数必须在目标 App 中核验。
- 原轨迹回放通过 Xcode `simctl location` 注入，避免旧通知通道中未被模拟器采用的 speed/course 字段。App 正常退出时会清除其回放；强制终止后可用 `xcrun simctl location <UDID> clear` 清理。
- 同一模拟器只允许一个定位写入者；回放过程中不要另开 Xcode GPX、其他工具或独立 simctl scenario。

## 原轨迹输入与 Apple 对照

`load-route` 接受 GeoJSON `LineString` 或 `Feature` 包含 `LineString`，坐标为 `[longitude,latitude]`，可带 `properties.name`。要求至少两个不同点，最多 100,000 点，请求最大 8 MiB。原始点序全部保留，不调用 MKDirections，不重新选择道路。导入失败不改已有路线。

界面入口仍保留 `Locations → Import Route (GeoJSON)…`。导入后点击/拖动地图不会重规划；切换 Points mode 才退出原轨迹模式。Debug 明确显示数据来源。

获取 Apple Maps 的反馈不需要打开 App：

```sh
./simvirtual apple-directions examples/apple-waypoints.json > apple-route.json
```

输入是 2–25 个途经点的 `[[longitude,latitude],...]`，按相邻点顺序请求 automobile 路线。结果含总距离/时间、完整 polyline、分段名称/收费/高速/提示以及每步指令和几何；任何分段失败或全局 60 秒超时都整体失败，不把残缺结果当成功。

Apple 输出是该组途经点的地图规划对照，不是 AuDrive 已审核路线，也不是法定限速或 STOP 数据源。示例 `apple-waypoints.json` 仅含原轨迹首尾，专门用来观察 Apple 的不同选路；不要把两个端点规划当作路线保真验证。

旧 GUI 的 Apple 诊断仍可用 `⌘⇧D` 打开。

GUI 的途经点规划也要求每一段都成功；任一段失败会提示对应段号，并阻止启动残缺路线。调整途经点后可重新规划。

## 历史 GPS 时间轴

历史录制使用独立的 `gps_samples` JSON，不改变 `load-route` 的恒速 GeoJSON 行为：

```json
{
  "version": 1,
  "max_gap_s": 10,
  "points": [
    {
      "elapsed_s": 0,
      "latitude": 0.0,
      "longitude": 0.0,
      "speed_mps": 0.0,
      "horizontal_accuracy_m": 5.0,
      "course_deg": -1
    },
    {
      "elapsed_s": 2,
      "latitude": 0.00009,
      "longitude": 0.0,
      "speed_mps": 5.0,
      "horizontal_accuracy_m": 5.0,
      "course_deg": 0.0
    }
  ]
}
```

每个点的 `elapsed_s` 是从回放起点开始的相对秒数，必须从 0 开始严格递增；至少两个点，最多 100,000 点，整个请求仍受 8 MiB 限制。`speed_mps`、`horizontal_accuracy_m`、`course_deg` 会原样保留，缺失或 `-1` 可表示录制端没有有效读数。`max_gap_s` 可选，默认 10 秒；`source` 等额外字段会被忽略，不参与注入。

```sh
./simvirtual load-timeline gps-samples.json
./simvirtual start-timeline
./simvirtual status
./simvirtual timeline > original-gps-samples.json
```

时间轴回放逐段调用真实的 `xcrun simctl location`：移动段通过 stdin 传坐标，避免负纬度被命令行解析成选项；优先使用录制 `speed_mps`，但只有它与该段距离/时间相差不超过 10% 时才会采用，否则为保证时间轴到达下一个原始点，使用几何估速。静止段使用 `simctl location set` 保持坐标到下一个时间点，但 `set` 后设备速度可能为 `nil`，因此状态源为 `stationary_unknown`，不会把录制的 0 m/s 宣称为设备已注入。`status` 的 `timeline_injection_speed_mode` 会报告 `recorded_speed_mps`、`geometry_derived`、`mixed`、`stationary_unknown` 或 `gap_unknown`，同时保留 `timeline_recorded_speed_mps` 供对照。

如果相邻点间隔超过 `max_gap_s`，调度器会在已知起点清除 simctl 场景，保持原始时间等待，不把未知区间默默插值成慢速行驶；到下一个已知点时重新 `set` 坐标。此时 `timeline_status=gap`、`timeline_gap_status=unknown`，速度不可知；可将 `max_gap_s` 显式调大才允许该区间按普通段回放。当前 `simctl location` 没有时间戳、course 或 accuracy 参数，因此 `horizontal_accuracy_m`、`course_deg` 只用于原始数据回读和对照，不会伪装成已注入的设备字段。`timeline_schedule_complete` 只表示调度器发出了最后一段命令并走完了源时间轴，不是模拟器或目标 App 的完成回执；仍需在目标 App 读取 Core Location 并显式调用 `stop` 清理。

`pause` 会清除当前 simctl 场景；`resume` 从最后一个已调度时间点重新开始，暂停在一个移动段中间时会从该段起点近似恢复。每段重启 simctl 可能产生启动延迟或覆盖前一段尚未完成的移动，状态中的 `estimated_position` 仍只是 Mac 观察标记，不能作为设备端时序或终点完成证据。

## 直接 JSON 调用

```sh
printf '%s\n' '{"command":"status"}' | ./simvirtual -
./simvirtual '{"command":"configure","speed_kmh":36}'
```

底层是 `~/.simvirtuallocation/control.sock` 的 Unix domain socket，一连接一行 JSON、一行响应。仅当前用户可访问：目录 0700、socket 0600，无 TCP 监听。结构化请求包含 `command`，支持 `status / simulators / configure / load-route / load-timeline / start / start-timeline / pause / resume / stop / route / timeline / debug`。这层接口后续可包装成 MCP，无需重新实现路线和状态逻辑。

## 本轮验收

2026-09-10，iPhone 17 / iOS 26.5 模拟器与 AuDrive Debug 原生导航：

- GeoJSON API 往返保留 Carlton Route 9 Stage 1 全部 103 个坐标。
- 命令回放中 AuDrive 显示 36 km/h，调整后 54 km/h；已走路线变灰，前方路线保持 Stage 色。
- 无效配置不部分生效，无效导入保留现有路线；暂停 6 秒观察位置不变，AuDrive 过期读数显示 `—`；恢复和 App 前后台切换后读数继续更新。
- 原始 Core Location 实测 simctl 的速度正确，但 speedAccuracy=-1。AuDrive 只在 Debug Simulator 中标注 `Simulated speed`，真机 GPS 校验没有放宽。
- Apple GUI 缺段保护通过 30 项实际源码行为检查，覆盖首段、中段、末段失败、完整路线、成功重试与过期回调；分别移除发布和启动保护后，检查均能捕获行为错误。Mac Debug 重新构建通过。

道路实测、物理手机的定位注入以及商店发布不包含在这些模拟器证据中。

## 2026-09-22 时间轴回归与边界

- 合成回归覆盖移动点通过 stdin 传入、负纬度 set 参数、长缺口默认 clear、静止段速度未知；不操作模拟器即可运行：

```bash
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  SimVirtualLocation/Models/GeoJSONRoute.swift \
  SimVirtualLocation/Logic/SimulatorRouteReplay.swift \
  Tests/TimelineReplayRegression.swift -o /tmp/simvirtual-timeline-check
/tmp/simvirtual-timeline-check
```

- AuDrive 的历史样本实际运行 590 点/1150 秒，App 独立报告完成。原始 speed 与 geometry/time 有冲突，因此只按 status 标明来源，不声称传感器速度完全保真。15 个长缺口按未知区间处理。
- 完整历史 watcher 初期 3 次工具状态读取失败，后续短回归与冷启动均未复现；仍保留整轮失败状态，根因未确证。Debug 新增私有 control-timing.jsonl，只记阶段/命令/耗时，不含坐标或 token，用来定位延迟，不擅自扩大超时。
- 调度结束不是 App 到达，Mac estimated_position 不是手机定位回执。上述证据来自 iOS 模拟器，不包含物理手机注入或实车导航。
