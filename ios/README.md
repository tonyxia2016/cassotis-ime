# 言泉输入法 iOS 版

iOS 键盘扩展。第 0 阶段验证了 Pascal 引擎能放进键盘扩展，结论和实测数字见 [REPORT.md](REPORT.md)：四条通过标准在 iPhone 15 Pro 上都已达到。第 1 阶段让键盘扩展用上与 macOS 相同的字符模型：模型经 Core ML 在神经网络引擎上运行，见 [REPORT-MODEL.md](REPORT-MODEL.md)。

引擎不在本目录：iOS 与 macOS 编译同一份 `../macos/src`，嵌入用的 C ABI 在 `../macos/src/embed/`。词库数据来自 `../lexicon/`，经 macOS 的构建脚本生成 `dict_sc.db`。

## 需要什么

- macOS、Xcode、Homebrew 的 `fpc`（3.2.2）、Python 3.11+
- 一个装有 numpy、onnx、coremltools 的 Python 环境，用来把字符模型转成 Core ML（见 `../macos/BUILD.md` 的 Core ML 一节），用 `CASSOTIS_COREML_PYTHON` 指向它
- 运行模型要 iOS 18 以上，且神经引擎至少 16 核（A14 及以后）。iPhone 12 Pro Max（A14）实测可用，见 REPORT-MODEL.md 第 7 节；iPhone XS Max（A12）等机型上，键盘照常工作，只是不用模型，见第 6 节
- 真机：Apple Development 证书和能覆盖设备的开发 profile。`scripts/build_app.sh` 只在本地签名，不改动开发者账号。默认找钥匙串里的 `Apple Development` 证书和名为 `iOS Team Provisioning Profile: *` 的通配 profile，可用 `CASSOTIS_IDENTITY`、`CASSOTIS_PROFILE` 指定。
- Xcode 工程里的 bundle ID 是 `com.hustmobile.cassotis.poc*`，团队是 `TR78TGFZDE`。换账号时改 `scripts/gen_xcodeproj.py` 和 `scripts/build_app.sh`。

## 从零构建

以下命令都在 `ios/` 下执行。先让 macOS 部分生成词库：

```bash
(cd ../macos && ./scripts/build_fpc.sh && python3 scripts/build_dictionaries.py)
```

再构建 iOS：

```bash
./scripts/build_toolchain.sh          # 拉 FPC 3.2.2 源码，交叉构建 iOS 运行库，约 2 分钟
CASSOTIS_COREML_PYTHON=/path/to/coreml-venv/bin/python \
  ./scripts/setup_resources.sh        # 取 dict_sc.db，生成 build/res/char_lm（Core ML 模型，约 170 MB）
./scripts/import_fcitx_ui.sh          # 取 fcitx5-ios 的面板源码到 build/fcitxui
python3 scripts/gen_xcodeproj.py
CASSOTIS_FPC_DEFINES=-dCASSOTIS_CMEM ./scripts/build_engine.sh ios
./scripts/build_app.sh                # Release，真机，签名
```

安装到连着的 iPhone：

```bash
xcrun devicectl device install app --device "$(python3 scripts/find_device.py)" build/dd/Build/Products/Release-iphoneos/CassotisPOC.app
```

模拟器：FPC 3.2.2 没有 aarch64-iphonesim，`scripts/sim-clang-wrapper.sh` 让汇编器把目标平台改成模拟器即可，不用换编译器：

```bash
CASSOTIS_SIMULATOR=1 ./scripts/build_toolchain.sh
CASSOTIS_FPC_DEFINES=-dCASSOTIS_CMEM ./scripts/build_engine.sh ios-sim
```

`scripts/build_sim.sh` 构建并安装到 `build/sim.udid` 记录的模拟器。新建一台测试用模拟器，并在它的设置里加上两个键盘（只改这台模拟器）：

```bash
UDID=$(xcrun simctl create "Cassotis Test" com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-2)
echo "$UDID" > build/sim.udid && xcrun simctl boot "$UDID"
xcrun simctl spawn "$UDID" defaults write -g AppleKeyboards -array "en_US@sw=QWERTY;hw=Automatic" \
  "com.hustmobile.cassotis.poc.swiftui" "com.hustmobile.cassotis.poc.keyboard"
./scripts/build_sim.sh
```

模拟器没有神经网络引擎，键盘在模拟器里不用模型。

## 在 Mac 上回放

同一份引擎、语料和回放代码，在 Mac 上跑得快，用来比较内存策略和候选：

```bash
CASSOTIS_VARIANT=macos-cmem CASSOTIS_FPC_DEFINES=-dCASSOTIS_CMEM ./scripts/build_engine.sh macos
./scripts/build_replay_macos.sh macos-cmem
./scripts/sweep_macos.sh macos-cmem "base:cache_percent=100" \
  "tuned:cache_percent=6 sqlite_cache_kib=2048 sqlite_mmap_mib=320 query_path_on_demand=1 prewarm_short_lookups=0"
```

回放会给每次运行算一个候选摘要。语料前 300 句在缓存 100% 时应得到 `24ca8ec5e807ec1e`，1 万键在 iOS 配置下应得到 `87b8ed8b46c2e479`，可以用来确认引擎改动有没有改变候选。这两个摘要是不加载模型时的：比较时加 `--option char_lm=0`。

带模型回放要让资源目录里有 `char_lm/`，并用 `--wait-model 秒数` 等模型就绪后再开始。要和键盘一样延后用模型，再加 `--option char_lm_deferred=1 --poll 1`。加 `--pace-us` 时，下一个键在上一个结果出来后隔这么久按下，延迟从按下时算起。例如：

```bash
./build/macos/replay --dictionary ../macos/build/dictionaries/dict_sc.db --resources build/res \
  --data /tmp/cassotis-data --corpus bench/corpus.tsv --wait-model 120 --output /tmp/coreml.json
```

## 真机测量

键盘要在手机上手动添加一次：设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 言泉 POC。这个 App 带两个键盘，要点进子页面把“言泉 POC”和“言泉 POC SwiftUI”都加上。Full Access 不用开。

之后不用碰手机。宿主 App 会切到指定键盘；命令和报告都走输入框往返，所以不需要 App Group，也不需要 Full Access。脚本默认找第一台用数据线连着的 iPhone，也可以用 `CASSOTIS_DEVICE` 指定。

```bash
./scripts/device_keyboard.sh uikit base-10k "keys=10000"
./scripts/device_keyboard.sh swiftui swiftui-10k "keys=10000"
CASSOTIS_TIMEOUT=2100 ./scripts/device_keyboard.sh swiftui soak-30min "keys=1000000 seconds=1800 pace=170000 loop=1 learning=1 context=1 every=1000"
CASSOTIS_TIMEOUT=720 ./scripts/device_keyboard.sh swiftui idle "mode=idle seconds=600"
./scripts/device_limit.sh swiftui limit 2      # 写满内存直到被系统终止
./scripts/device_selftest.sh selftest "keys=10000"   # 引擎跑在 App 进程里，不需要启用键盘
```

回放选项：`keys`、`seconds`、`pace`（微秒）、`every`、`context`、`learning`、`loop`、`ui`。内存策略选项：`cache`、`sqlite`、`mmap`、`ondemand`、`prewarm`。模型选项：

- `lm=0` 不加载字符模型。
- `defer=0` 让每个按键当场用模型排序。默认是延后：按键先返回只按词库排的候选，键盘空闲时再轮询，取回模型排好的候选。轮询还没结束时来了拼音字母或退格，就中断它；空格、回车、选候选则等它跑完。报告里的 `polls`、`polls_applied`、`polls_interrupted` 和 `poll_*_ms` 记录轮询的次数与耗时。
- `wait` 是回放前最多等模型就绪的秒数，默认 180；报告里的 `model_state`、`model_seconds` 记录结果。
- `det=1` 关掉引擎的时间预算。其他命令：`mode=whoami`、`mode=probe`、`mode=idle`、`mode=limit`、`mode=next`、`mode=exit`，以及 `mode=mltest`（直接用 Core ML 加载各长度函数，测加载时间、内存和单次推理时间；`units=ne|cpu|gpu|all`）。

`device_selftest.sh` 也接受 `mode=mltest`，以及 `mode=mlplan`（用 `MLComputePlan` 看算子派到哪个计算单元；`length` 指定函数）。它们在宿主 App 里跑，不需要先启用键盘。手机连了不止一台时，用 `CASSOTIS_DEVICE` 指定。

模型在引擎打开后由后台线程加载，就绪前候选不使用模型。新装的模型第一次加载时，系统要为神经网络引擎编译，约 8 秒；之后每次进程启动约 0.2 秒。

## 按键测试

`mode=type` 让一串按键走和屏幕上点按相同的调用，最后报告输入框里的文字、剩下的拼音和候选、用户词库大小；加 `debug=1` 时还报告引擎排序用的上下文。模拟器用 `sim_keyboard.sh`，真机用 `device_keyboard.sh`：

```bash
./scripts/sim_keyboard.sh swiftui "label=context mode=type prefix=我们今天 keys=chifan debug=1"
./scripts/device_keyboard.sh swiftui type-check "mode=type keys=shuru#3#2 learning=0"
```

- `keys`：a–z、数字、`'` 和标点照原样输入；`_` 空格，`<` 退格，`~` 回车；`#N` 点列表里第 N 个候选（包括滚动读进来的），`+` 把候选列表滚到末尾，读入后面的页；`{en}`、`{zh}` 切换英文和拼音，`{reset}` 是面板的 resetInput，`{sym:X}` 是从符号面板点 X。
- `prefix`：先插入输入框的文字，当作之前打的内容（不能有空格）。
- `pace`：两键之间的毫秒数，默认 300，够模型的轮询跑完。
- `learning=0`：不打开用户词库。在自己的手机上测试时用它，免得测试内容被学进去。

正常打字时：

- **学习：** 用户词库是键盘扩展自己容器里的 `Library/Application Support/Cassotis/user_dict.db`，不需要 Full Access。每次上屏都直接写进 SQLite，扩展被系统结束也不会丢。两个键盘各有一份。测量回放默认不学习，`learning=1` 才打开。
- **上下文：** 开始一段新输入前，键盘把光标前最多 1024 个 UTF-16 单位交给引擎，和 macOS 相同；输入框不提供时告诉引擎“没有上下文”，不沿用上一个输入框的。
- **标点和数字：** 标点按引擎的中文标点规则输出；光标前是数字时，句号保持为“.”。拼音还没上屏时按数字，先按第一个候选上屏，再输入数字：屏幕上的数字不用来选候选，只有用拼音转数字这类要读数字的模式除外。
- **中英文：** 长按地球键在“拼音”和“英文”之间切换，空格键上显示当前模式。引擎不保存这个模式（macOS 由前端按应用记住），键盘自己记住上次的；测量回放总是从拼音开始。引擎不处理的按键（英文模式下的字母、空格等）由键盘直接输入，有拼音时先上屏。
- **符号面板：** 面板插入符号前会先重置输入，键盘这时把拼音按第一个候选上屏，再插入符号，顺序与点按顺序一致。
- **候选：** 候选栏和展开后的候选区是同一个能一直往下滚的列表。快滚到末尾时，键盘趁引擎空闲读取后面的页（`imt_candidate_pages`，只读），所以按空格仍上屏第一个，延后的模型排序也照常生效。点到后面某页的候选时，先翻到那一页再按数字选中。

## 目录

| 路径 | 内容 |
|---|---|
| `app/Host/` | 宿主 App：发命令、收报告、切换键盘、App 进程内自测 |
| `app/Keyboard/` | UIKit 最小键盘，两个键盘共用的命令通道和引擎线程，也放词库 |
| `app/KeyboardSwiftUI/` | fcitx5-ios 的 SwiftUI 面板接言泉引擎 |
| `client/` | macOS 版的 `EngineClient`，传输层从 socket 换成函数调用 |
| `bench/` | 回放语料与代码、内存和延迟统计，Mac 与真机共用 |
| `scripts/` | 工具链、引擎、App、模拟器、真机测量脚本 |
| `results/` | 第 0 阶段的原始测量数据 |
| `toolchain/`、`build/` | 生成物，不入库 |

fcitx5-ios 的源码不进本仓库，`scripts/import_fcitx_ui.sh` 在构建时从上游 commit 取；它和本项目都是 GPL-3.0。
