# 构建 Cassotis IME - 言泉输入法

本版本面向 Apple Silicon 和 macOS 14+，使用 Free Pascal 3.2.2、Xcode 命令行工具和 Python 3.11+，不依赖 Lazarus/LCL。其他系统和架构的验证范围见 [COMPATIBILITY.md](COMPATIBILITY.md)。以下命令均在本仓库根目录执行。

## 准备依赖

安装 Xcode 命令行工具（`xcode-select --install`）、Free Pascal 3.2.2 和 Python 3.11+。将 `fpc` 和 `python3` 加入 `PATH`；编译器也可通过 `CASSOTIS_FPC_BIN=/path/to/fpc` 指定。`/path/to/...` 是示例占位路径，请替换为自己的实际位置。

```sh
./scripts/check_environment.sh
```

词库来自 [Cassotis Lexicon](https://github.com/shenmin/cassotis-lexicon) 项目。本仓库在 `macos/` 旁的 `lexicon/` 目录收录了它的 `v2.6.0` 发布内容，构建默认就读那里，不用另外检出。要换用其他检出，用环境变量指定：

```sh
export CASSOTIS_LEXICON_ROOT="/path/to/cassotis-lexicon"
```

该目录必须包含 `data/generated/` 下简繁两套共 28 个生成文本。构建时按 `data/lexicon-inputs.json` 验证输入 SHA-256，再导入 schema 24 数据库；各表记录数和数据库摘要也记录在该清单中。带候选指纹的短词提升表和通用文本词频表均为必需输入，不能省略；构建及组包会检查词频表非空。词库生成过程和许可见词库项目自身的文档。

一个共享 ONNX 字符模型、词表和拼音读音表已随源码提供。共享字符模型以 `char_lm.onnx.000`、`.001`、`.002`、`.003` 分片保存，构建时按顺序原子合并并验证 SHA-256；合并文件不提交到 Git，安装应用仅携带合并模型。`data/runtime-assets.sha256` 记录模型和数据库 schema 的校验值。首次构建会下载官方 ONNX Runtime 1.20.1 arm64 发行包，核对固定 SHA-256 后解压。已安装的输入法无需编译器、Python、联网推理或另外下载模型。

### Core ML（可选）

在 macOS 15 及以上、带至少 16 核神经网络引擎（ANE）的 Mac（M1 及以后）上，同一个字符模型还可以用 Core ML 在 ANE 上运行。算法、词表和清单都不变，只是换了推理后端：`src/host/native/nc_char_lm_coreml.mm` 导出与 ONNX Runtime 桥接库同名的 `nc_lm_*` 函数，构建为 `libcassotis_coreml.dylib`。应用里同时有 Core ML 模型和这个库时，引擎优先用 Core ML。以下情况自动退回 ONNX Runtime：系统低于 macOS 15；没有 16 核 ANE，例如 Intel Mac；模型缺失或打不开。选择逻辑见 `src/host/nc_lm_runtime.pas`。

Core ML 模型由 `char_lm.onnx` 转换而来，转换要用 numpy、onnx 和 coremltools（已验证 coremltools 9.0）。在一个装有它们的 Python 环境里执行：

```sh
python3 -m venv /path/to/coreml-venv
/path/to/coreml-venv/bin/pip install numpy onnx coremltools
CASSOTIS_COREML_PYTHON=/path/to/coreml-venv/bin/python ./scripts/build_coreml_model.sh
```

输出 `build/coreml/char_lm.mlmodelc`，约 170 MB。完整构建也会调用这个脚本，找不到 coremltools 时只提示并跳过；组包时若有这个模型，就放进 `Cassotis.app/Contents/Resources/models/char_lm/`。模型元数据记录了源 ONNX 的 SHA-256，引擎打开前会与 `runtime_manifest.json` 核对。第一次打开某个模型文件时，系统要为 ANE 编译，约 10–15 秒，之后在 0.2 秒内打开；编译在后台线程进行，期间候选不使用模型。

在 M1 Pro 上，用同一组 615 句语料回放约 1 万键：Core ML 和 ONNX Runtime 的整句首选率分别为 66.0% 和 66.6%，94% 的句子上屏结果相同；单键 P95 分别为 80 ms 和 113 ms；回放进程内存分别为 160 MB 和 396 MB。

繁体字形映射已作为源码表提供，正常构建不需要生成或下载。`tools/build_traditional_chars.py` 可从固定的 OpenCC 上游输入重新生成映射；来源与许可证见 [NOTICE.md](NOTICE.md)。应用同时携带 OpenCC 的 Apache-2.0 许可证。

## 构建

```sh
./rebuild_all.sh        # 清理 build/ 并完整重建
./build_all.sh          # 增量构建
./build_all.sh --force  # 重新编译 Pascal 单元
./clean_all.sh          # 清理构建产物
```

构建依次生成原生推理桥接库、FPC 引擎、简繁数据库、AppKit 前端和图形安装器，不依赖测试工具或语料。

构建脚本保留与 Delphi Win64 一致的浮点精度，使用 `-CF64`，并在编译参数改变时重新生成 Pascal 单元。引擎也包含 FPC 3.2.2 ARM64 最小整数比较问题的等价写法修正；请保留这些适配，避免有效候选被误判为缺失。

| 输出 | 用途 |
| --- | --- |
| `build/arm64/Cassotis.app` | 输入法应用，包含引擎、运行库、模型与词库 |
| `build/arm64/言泉输入法安装器.app` | 图形安装器；打包时加入安装负载 |
| `build/arm64/bin/` | 引擎、词库导入器、输入源管理工具及推理运行库（ONNX Runtime 与 Core ML） |
| `build/coreml/` | Core ML 模型（`scripts/build_coreml_model.sh`，可选） |
| `build/dictionaries/` | 简繁 SQLite 数据库及导入记录 |
| `build/arm64/units/`、`logs/`、`symbols/` | 编译中间文件、日志与调试符号 |

`VERSION` 控制显示版本，`BUILD_NUMBER` 控制应用和安装器的 `CFBundleVersion`。修改后需重新构建；打包器会拒绝版本或构建号不匹配的旧应用。

## 延后排序

输入法默认打开延后排序：

- 按键先只按词库排序，结果标为待定，立即返回。前端随即发出轮询，引擎这时用字符模型重建候选；前端在之后的 25 ms 定时器里取回并显示。按键不等轮询：轮询结果还没取回就来了新按键时，前端读掉那份结果，不显示。
- 轮询进行中，服务端有一个线程窥探（`MSG_PEEK`）客户端 socket。新到的拼音字母或退格会打断这次重建，按键不用等它做完。空格、回车、选候选不打断，上屏的仍是模型排好的结果。
- 要回到每个按键里都用模型排序，给引擎加 `--no-char-lm-deferred`。

`tools/bench/socket_replay.cpp` 像输入法那样通过 socket 驱动运行中的引擎：每次一个键，按固定间隔，期间照前端的方式轮询。每个键从该按下的时刻计到结果返回，排在轮询后面等着的时间也算在内。

```sh
xcrun clang++ -std=c++20 -O2 tools/bench/socket_replay.cpp src/macos/EngineClient.cpp -o build/socket_replay
rm -rf build/bench && mkdir -p build/bench
build/arm64/Cassotis.app/Contents/MacOS/cassotis-engine --serve --dictionary build/dictionaries/dict_sc.db \
    --user-dictionary build/bench/user.db --socket build/bench/engine.sock &
engine=$!
until [ -S build/bench/engine.sock ]; do sleep 0.1; done
build/socket_replay --socket build/bench/engine.sock --corpus ../ios/bench/corpus.tsv \
    --keys 200 --pace-us 170000 > /dev/null    # 预热
build/socket_replay --socket build/bench/engine.sock --corpus ../ios/bench/corpus.tsv \
    --keys 1519 --pace-us 170000 --output build/bench/result.json
kill $engine
```

- 用应用里的引擎，它会找到应用里的 Core ML 模型。`build/arm64/bin/` 里的引擎旁边只有 ONNX 模型，会用 ONNX Runtime。
- socket 路径要短于 104 字节。
- 开头先删掉 `build/bench`，每次测量都用新的用户词库，免得上一次学到的东西影响结果。

M1 Pro 上的结果。用 Core ML，回放 55 句共 1,519 键，先预热 200 键：

| 按键间隔 | 按键里排序 P50 / P95 / P99 | 延后排序 P50 / P95 / P99 |
| --- | --- | --- |
| 170 ms | 37.0 / 131.8 / 181.5 ms | 21.0 / 75.8 / 99.9 ms |
| 80 ms | 32.8 / 129.7 / 183.5 ms | 21.2 / 68.1 / 102.4 ms |

两种方式首选都是 35 句。下一个键按下时还没答复的轮询，170 ms 间隔有 38 次，80 ms 间隔有 357 次。

## 从源码安装

```sh
./install.sh
./uninstall.sh
```

以当前桌面用户运行，不要使用 `sudo`。安装后在“系统设置 → 键盘 → 文字输入 → 编辑 → + → 中文（简体）”中添加言泉输入法，再从菜单栏选用。应用安装到 macOS 的当前用户输入法目录 `~/Library/Input Methods/`；升级和卸载保留用户数据。数据与日志位置见 [CONFIGURATION.md](CONFIGURATION.md)。

## 打包与签名

```sh
./scripts/package.sh
```

输出位于 `dist/`，包括带图形安装器的 DMG、命令行安装 ZIP 和各自的 SHA-256。默认 `-local` 包使用临时签名。

DMG 图形安装器在文件安装成功后请求系统启用输入法，按需显示 macOS 的授权确认。确认启用后可直接从输入菜单选用；未成功时提供“重试启用”和键盘设置入口。命令行安装保留上述手动添加步骤。

Developer ID 签名的 DMG 固定命名为 `cassotis-ime-macos-<版本号>-arm64-installer-signed.dmg`，例如 `cassotis-ime-macos-2.6.0-arm64-installer-signed.dmg`。后续版本只替换版本号；完成公证后也保持此名称。未指定签名身份的本机构建使用 `-installer-local.dmg` 后缀。

DMG 附带普通与 Retina 分辨率的背景，自动保存安装器与说明文件的位置。打包步骤需要已登录的 macOS 桌面，由系统 Finder 设置镜像外观；如系统首次询问终端是否可以控制 Finder，请允许。背景已随源码提供，不需要下载字体或访问官网。临时镜像在完成或失败后自动清理；若系统仍占用挂载卷，脚本会保留并显示其位置。

拥有 Developer ID 证书时，可以使用自己的身份和钥匙串公证配置：

```sh
./scripts/package.sh --identity 'Developer ID Application: YOUR NAME (TEAMID)' --notary-profile YOUR_PROFILE
```

指定 Developer ID 身份时，打包器默认要求同时提供 `--notary-profile`，并在打包前验证公证凭据。流程依次对输入法、安装器和最终 DMG 提交 Apple 公证，每一层确认通过后装订并验证自身票据。输入法和安装器还须通过系统分发检查，最终磁盘镜像须通过 Gatekeeper 检查。仅供开发排查的签名包可显式添加 `--allow-unnotarized`，此选项不适用于正式发布。`-signed.dmg` 文件名本身不能证明已公证。证书、私钥和钥匙串配置由构建者自行管理。打包器使用暂存副本，不修改已安装应用。

评分方法、测试环境和汇总结果见 [BENCHMARK.md](BENCHMARK.md)。测试程序、桌面自动化、基准工具、语料和逐例诊断不随源码分发。

应用组装时会校验模型清单，只保留运行参数、模型校验值和来源信息。模型清单不包含训练路径或逐例评估记录。
