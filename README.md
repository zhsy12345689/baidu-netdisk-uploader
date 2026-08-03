# bdupload

把本地文件和目录传到百度网盘的命令行工具。基于
[BaiduPCS-Go](https://github.com/qjfoidnh/BaiduPCS-Go) 封装，补上了它没有的东西：
排除规则、预演、tmux 后台、登录态预检、结构化日志。

自带一个 [Claude Code](https://claude.com/claude-code) skill，可以让 Claude 全程
辅助完成上传、监控和完整性核对。

## 为什么不直接用 BaiduPCS-Go

它本身很好用，但缺几样东西，传大数据集时会比较难受：

| 需求 | BaiduPCS-Go | bdupload |
|---|---|---|
| 排除某些文件/目录 | 没有 exclude 参数 | `-x` 可重复指定，支持文件名和路径两种匹配 |
| 传之前看看会传什么 | 无 | `-n` 预演，列出清单和总体积 |
| 后台跑、断连不断传 | 自己套 tmux | `-T` 一个参数搞定 |
| 登录不全就开传 | 每个文件失败一次才发现 | 开传前预检，直接告诉你缺什么 |
| 传完核对 | 手动 | 自动打印网盘实际内容 |

## 安装

```bash
git clone <你的仓库地址>
cd bdupload
./install.sh            # 自动探测平台，拉最新版 BaiduPCS-Go 到 ./bin/
```

需要 `bash`、`curl`、`unzip`，用 `-T` 的话还要 `tmux`。

## 登录

需要 **BDUSS 和 STOKEN 两个 cookie，缺一不可**。

1. 浏览器登录 [pan.baidu.com](https://pan.baidu.com)，**停在网盘页面**
2. F12 → Application → Cookies → `https://pan.baidu.com`
3. 分别点中 `BDUSS` 和 `STOKEN` 两行，从表格**下方的 Value 面板**复制完整值
4. 登录并验证：

```bash
./bin/BaiduPCS-Go login -bduss="..." -stoken="..."
./bin/BaiduPCS-Go who
```

三个容易踩的坑：

- **别从表格单元格里拖选** —— 长值显示不全，拖出来是截断的。要点中行，从下方 Value 面板复制。
- **STOKEN 只挂在 `pan.baidu.com` 域下**。当前页是 `www.baidu.com` 的话，Cookies 列表里根本没有它。
- 少了 STOKEN 的症状很有迷惑性：`who` 和 `quota` 都正常，但一开传每个文件都报
  `获取用户uk错误`。别去查网络或路径，就是缺 STOKEN。

> **这两个值等同于账号密码**，拿到就能读写删你整个网盘。别贴进聊天窗口、
> 别提交进 git、别写进脚本。万一泄露了，去浏览器对百度账号执行一次「退出登录」，
> 所有已签发的 BDUSS 都会作废。

## 用法

```bash
./bdupload.sh -s <本地路径> -d <网盘目录> [选项]
```

| 参数 | 说明 |
|---|---|
| `-s, --src PATH` | 要上传的本地文件或目录，**可重复**，一次传多个 |
| `-d, --dst PATH` | 网盘目标目录，不存在自动创建 |
| `-x, --exclude PAT` | 排除规则，**可重复**。不含 `/` 匹配文件名（`.cache`、`*.tmp`），含 `/` 匹配完整路径（`*/logs/*`） |
| `-n, --dry-run` | 只打印会传什么、多大，不实际执行 |
| `-T, --tmux NAME` | 在指定 tmux 会话里后台运行 |
| `-p, --threads N` | 单文件上传线程数（默认 4） |
| `-l, --load N` | 同时上传的文件数（默认 3） |
| `--retry N` | 单文件失败重试次数（默认 5） |
| `--policy P` | 同名文件策略：`skip`（默认）/ `overwrite` / `rsync` |
| `--log PATH` | 日志路径（默认 `./<网盘目录名>_upload.log`） |
| `-h, --help` | 完整帮助 |

### 例子

```bash
# 先预演，看看会传什么
./bdupload.sh -s ./PianoVAM -d /datasets/PianoVAM -x .cache -n

# 确认无误后正式传，后台跑
./bdupload.sh -s ./PianoVAM -d /datasets/PianoVAM -x .cache -T pianovam

# 一次传多个源，排除临时文件
./bdupload.sh -s ./modelA -s ./modelB -d /backup/models \
              -x '*.tmp' -x '*.ckpt.part' -T models

# 看进度
tmux attach -t pianovam        # Ctrl-B 松开再按 D 退出看板，上传继续
tail -f PianoVAM_upload.log
```

## 路径映射

源是**目录**时，上传的是它的**内容**，不会再套一层同名目录：

```
-s ./mydata -d /backup/mydata    =>    /backup/mydata/<mydata 里的东西>
```

源是**文件**时，直接落在目标目录下：

```
-s ./a.txt -d /backup            =>    /backup/a.txt
```

## 几个行为上的设计

**断点续传靠 `--policy skip`。** 中断了原样重跑同一条命令即可，网盘上已存在的
同名文件会被跳过。这也意味着如果源文件改过但文件名没变，默认不会更新 ——
那种情况要用 `--policy overwrite`。

**排除是靠下钻实现的**，因为 BaiduPCS-Go 本身没有 exclude 参数。做了个优化：
子树里没有任何排除项的目录整个一把提交，只有真含排除项的才逐层展开。所以
`-x .cache` 不会因为一个几百 K 的缓存目录，就让整个几十 G 的传输退化成逐文件调用。

**普通文件排在目录前面上传。** 它们通常只有几 KB，几秒就传完，链路或登录态有问题
能立刻发现，不用等一个几十 G 的目录传到一半才报错。

**预演不需要二进制、也不需要登录**，所以你可以在任何机器上先跑 `-n` 确认路径对不对。

## 读进度的注意事项

按文件数算的百分比常常严重高估。如果大文件集中在队列末尾，文件数到 60% 时
字节数可能才 20%。估时要按字节算。

日志里出现 `秒传成功` 是正常的 —— 百度服务器上已存在相同哈希的文件，直接引用，
不消耗流量。公开数据集命中率往往很高，实际耗时会明显低于按体积的估算。

## 传完核对

别只看退出码，有可能部分文件静默失败：

```bash
./bin/BaiduPCS-Go ls /你的网盘目录        # 逐级核对目录结构和文件数
grep -c '上传文件失败\|错误' *.log        # 应为 0
```

本地和网盘的文件数逐目录对上才算完成。对不上就重跑同一条命令补缺失的。

## Claude Code skill

仓库里带了 `.claude/skills/baidu-upload/`。在这个目录下开 Claude Code，
直接说「把 xxx 传到百度网盘」，它会按标准流程走：装工具 → 查登录态 →
预演并跟你确认排除规则 → tmux 后台启动 → 监控进度 → 传完核对完整性。

skill 里写死了一条：**不会让你把 BDUSS/STOKEN 贴进对话**，登录命令只给模板，
由你自己在终端执行。

## 常见问题

**`获取用户uk错误, 请确保登录信息包含了STOKEN`**
登录时漏了 STOKEN，带上重新登录即可。报错里跟着的「或更换保存路径」是百度的
通用文案，跟路径无关。

**单文件超过 4G 传不上去**
普通用户单文件上限 4G，SVIP 是 20G。超了先切分：`split -b 3G bigfile bigfile.part`

**大量视频文件被拦**
百度网盘对视频有自动审核，偶尔误伤。可以先 `tar` 打包再传。

**速度慢**
实测上传能到 ~11 MB/s，长时间大流量后可能降速。可以调 `-p` 和 `-l`，
但调太高容易触发风控，默认的 `-p 4 -l 3` 比较稳。

## 合规提醒

上传第三方数据集前确认许可证允许再分发。私人备份基本都没问题，**公开分享链接**
才涉及再分发条款。CC BY-NC-SA 这类协议允许分享，但要保留署名、注明许可证、不得商用。
数据里含人脸声音等个人信息的，别扩散到公开渠道。

建议在上传目录里放一个 `LICENSE-AND-ATTRIBUTION.txt`，写清来源、作者、许可证和引用格式。

## 许可

MIT，见 [LICENSE](LICENSE)。

BaiduPCS-Go 是独立的第三方项目，有自己的许可证，本仓库不分发它的二进制，
由 `install.sh` 在运行时下载。
