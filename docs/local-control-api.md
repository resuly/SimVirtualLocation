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

`start` 异步注入，响应的 `injection_status` 首先为 `starting`；继续查询 `status`，`active` 表示 simctl 已确认开始。失败为 `failed` 并带 `injection_error`。CLI 的 `ok:false` 会退出非零；收到请求与模拟器已开始移动是两个状态。

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

## 直接 JSON 调用

```sh
printf '%s\n' '{"command":"status"}' | ./simvirtual -
./simvirtual '{"command":"configure","speed_kmh":36}'
```

底层是 `~/.simvirtuallocation/control.sock` 的 Unix domain socket，一连接一行 JSON、一行响应。仅当前用户可访问：目录 0700、socket 0600，无 TCP 监听。结构化请求包含 `command`，支持 `status / simulators / configure / load-route / start / pause / resume / stop / route / debug`。这层接口后续可包装成 MCP，无需重新实现路线和状态逻辑。

## 本轮验收

2026-09-10，iPhone 17 / iOS 26.5 模拟器与 AuDrive Debug 原生导航：

- GeoJSON API 往返保留 Carlton Route 9 Stage 1 全部 103 个坐标。
- 命令回放中 AuDrive 显示 36 km/h，调整后 54 km/h；已走路线变灰，前方路线保持 Stage 色。
- 无效配置不部分生效，无效导入保留现有路线；暂停 6 秒观察位置不变，AuDrive 过期读数显示 `—`；恢复和 App 前后台切换后读数继续更新。
- 原始 Core Location 实测 simctl 的速度正确，但 speedAccuracy=-1。AuDrive 只在 Debug Simulator 中标注 `Simulated speed`，真机 GPS 校验没有放宽。
- Apple GUI 缺段保护通过 30 项实际源码行为检查，覆盖首段、中段、末段失败、完整路线、成功重试与过期回调；分别移除发布和启动保护后，检查均能捕获行为错误。Mac Debug 重新构建通过。

道路实测、物理手机的定位注入以及商店发布不包含在这些模拟器证据中。
