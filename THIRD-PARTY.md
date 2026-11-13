# Third-party software

TouchFlow 自己的代码以 MIT 发布。仓库里只有一个第三方二进制：MediaRemote 适配器，
它是宽松许可（BSD-3-Clause）。

## MediaRemoteMini.dylib

- **文件**：`vendor/mediaremote-mini/build/mediaremote-mini/MediaRemoteMini.dylib`
- **许可**：BSD 3-Clause，全文见 [`LICENSES/BSD-3-Clause.txt`](LICENSES/BSD-3-Clause.txt)
- **版权**：© 2025 Jonas van den Berg and contributors
- **上游**：[kirtan-shah/nowplaying-cli](https://github.com/kirtan-shah/nowplaying-cli)
  的 `src/mediaremote-mini/`，源自 [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
- **固定的 commit**：`8c8c1fa4820681fd4bbd6a17ce0a5655e1f4ebe7`
- **如何重新编译**：`./scripts/build-adapter.sh`（arm64 + x86_64，lipo 合并）
- **用途**：`scripts/read-nowplaying.pl` 加载它读取系统 Now Playing 信息；
  app 本身不链接这个库

## 其它

- 读取系统播放信息必须经过 `/usr/bin/perl`：macOS 只对系统签名的进程返回
  Now Playing 数据，自建二进制拿到的是空结果。
- 播放/暂停直接通过 `MediaRemote.framework` 的 `MRMediaRemoteSendCommand` 发送，
  不依赖第三方工具。
- 与网易云的通信只发生在 `127.0.0.1:9222`（本机 DevTools 端口），不重分发任何
  Apple 或网易云的代码。
