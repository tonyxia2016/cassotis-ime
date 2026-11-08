# 仓库结构

本仓库（`tonyxia2016/cassotis-ime`）统一管理言泉输入法的 Windows、macOS、iOS 三端和词库。所有开发都在 `master` 分支完成，不再另建兄弟目录或单独的仓库。

| 目录 | 内容 | 来源 | 构建入口 |
|---|---|---|---|
| 根目录（`src/`、`out/`、`installer/` …） | Windows 版，Delphi + TSF | fork 自 [shenmin/cassotis-ime](https://github.com/shenmin/cassotis-ime)，`upstream` 远程 | [BUILD.md](BUILD.md) |
| `macos/` | macOS 版，Free Pascal 引擎 + InputMethodKit / AppKit 前端 | [shenmin/cassotis-ime-mac](https://github.com/shenmin/cassotis-ime-mac) v2.6.0 快照 | [macos/BUILD.md](macos/BUILD.md) |
| `ios/` | iOS 键盘扩展（第 0 阶段已通过；字符模型经 Core ML 运行） | 本仓库自有 | [ios/README.md](ios/README.md) |
| `lexicon/` | 词库构建产物与脚本 | [shenmin/cassotis-lexicon](https://github.com/shenmin/cassotis-lexicon) v2.6.0 快照 | [lexicon/README.zh-Hans.md](lexicon/README.zh-Hans.md) |

## 各部分的关系

- **引擎：** Windows 版的引擎在根目录 `src/engine`。macOS 版移植时已经分叉（37 个引擎单元里多数有差异），所以 `macos/src` 单独保留。iOS 不带自己的副本，直接编译 `macos/src`；嵌入用的 C ABI 在 `macos/src/embed/`，只在定义 `CASSOTIS_EMBEDDED` 时参与编译，macOS 构建不受影响。
- **词库：** Windows 的 `out/rebuild_dict.ps1` 和 macOS 的 `macos/scripts/build_dictionaries.py` 默认读取 `lexicon/`，找不到时才用旁边的 `../cassotis-lexicon` 检出。iOS 用 macOS 构建出的 `macos/build/dictionaries/dict_sc.db`。
- **模型：** 根目录 `data/models/char_lm` 与 `macos/data/models/char_lm` 的四个模型分片是同一批 git blob，只存一份。macOS 和 iOS 还可以用同一个模型的 Core ML 形式：`macos/scripts/build_coreml_model.sh` 把 `char_lm.onnx` 转成 `macos/build/coreml/char_lm.mlmodelc`，转换结果不入库。

## 与上游 v2.6.0 的差异

`macos/` 和 `lexicon/` 都按上游 `v2.6.0` 标签逐字节导入（macOS 提交 `a56d9ef`，词库提交 `bbf3ae3`）。之后在本仓库里的改动：

- **macOS 加固：** 删除了 `CASSOTIS_RUNTIME_LIBRARY`、`CASSOTIS_SQLITE_LIBRARY`、`CASSOTIS_SOCKET`、`CASSOTIS_ENGINE_EXECUTABLE` 四个环境变量，它们能改写引擎加载的动态库、输入法连接的 socket 和启动的引擎。
- **引擎：**
  - 支持嵌入 iOS 键盘扩展。
  - 新增内存旋钮，默认值等于 macOS 原值。
  - 修复 FPC 3.2.2 `TQueue` 无界增长，给几张原来没有上限的表加了界。这两项修复对 macOS 也生效。
  - 用回放语料核对过：缓存 100% 时，候选与原始引擎逐键相同。
- **构建：** 两端默认读取仓库内的 `lexicon/`。
- **Core ML 推理：** 新增 `macos/src/host/native/nc_char_lm_coreml.mm`，与 ONNX Runtime 桥接库导出同一组 `nc_lm_*` 函数，共用 `nc_char_lm_ort.inc` 里的全部算法，在神经网络引擎上运行。`macos/src/host/nc_lm_runtime.pas` 负责选择后端：macOS 有 Core ML 模型时优先用它，否则用 ONNX Runtime；iOS 只有 Core ML，并且直接静态链接。嵌入构建因此重新编进了字符模型和整句纠错两个宿主，可用 `char_lm` 选项关闭。
- **延后排序（嵌入构建）：** `char_lm_deferred` 打开时，按键先只按词库排序并立即返回，前端轮询时再用模型重建候选；`cassotis_core_interrupt` 让新按键打断正在进行的重建。iOS 键盘默认打开。macOS 桌面版不受影响。
- **只读候选页（IPC 新请求 `imt_candidate_pages`）：** 按候选版本号读取之后最多三页候选，引擎的当前页和选择不动。iOS 键盘的候选列表靠它边滚动边加载；改用翻页键的话会被当成用户翻页，延后排序就不再生效。新类型追加在枚举末尾，不影响已有消息；macOS 客户端不发这个请求。

`lexicon/` 的内容没有改动。

## 与上游同步

- **Windows 部分：** `git fetch upstream` 后合并 `upstream/master`。`macos/`、`ios/`、`lexicon/` 不在上游里，合并不会冲突。
- **macOS 和词库：** 上游发布新版时，用 `git archive <标签>` 导出，覆盖到对应目录，再把上面列出的本地差异重新核对一遍。每次单独提交，提交说明写明上游提交号。

## 许可

- 输入法代码（根目录、`macos/`、`ios/`）：GPL-3.0。
- `lexicon/` 的数据：CC BY-SA 4.0，附 THUOCL 与 chinese-poetry 的许可，见 `lexicon/LICENSE` 和 `lexicon/attribution/`。
- `ios/` 构建时从 fcitx5-ios 取的面板源码（GPL-3.0）：不入库。
