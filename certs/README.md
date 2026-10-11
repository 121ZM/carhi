# CarHi 签名证书目录

HarmonyOS 应用要装进真机，HAP 必须签名。签名需要**三件套**：

| 文件 | 扩展名 | 作用 | 来源 | 能否公开 |
|---|---|---|---|---|
| 密钥库 | `.p12` | 私钥 + 证书链 | 本地生成（`gen_key.sh`）或 DevEco 导出 | **绝不外传** |
| 应用证书 | `.cer` | 应用签名证书（证书链，三级-二级-根） | AGC 用 CSR 换取 | 可公开 |
| Profile | `.p7b` | 权限声明 + 设备白名单 | AGC 生成 | 可公开 |
| CSR | `.csr` | 证书签名请求，用 p12 生成 | 本地生成（`gen_key.sh`） | 可公开 |

调试包（debug）的 Profile **绑定了真机 UDID**，换机器就要重申请。
发布包（release）不绑设备，但要走 AGC 上架/企业分发审核。

## 目录约定

```
certs/
  keystore.p12              生成本地私钥库（gen_key.sh 产出，勿提交 git）
  carhi.csr                 上传 AGC 用（gen_key.sh 产出）
  carhi-debug.cer           AGC 下载，应用证书链
  carhi-debug.p7b           AGC 下载，调试 Profile
  carhi-release.cer         AGC 下载，发布证书链
  carhi-release.p7b         AGC 下载，发布 Profile
  .gitignore                存在则本目录已被忽略
```

## 三步走

### 1. 本地生成私钥 + CSR

```bash
bash tools/sign.sh genkey
```

产出 `certs/keystore.p12` 与 `certs/carhi.csr`。**密码记牢**，后面签名要用。

### 2. 去 AGC 申请证书和 Profile

登录 https://developer.huawei.com/consumer/cn/service/josp/agc/index.html

- **证书管理 → 新增证书** → 上传 `certs/carhi.csr` → 下载 `.cer`
- **Profile 管理 → 新增 Profile**
  - 类型选「调试」→ 需要先注册真机 UDID → 下载 `.p7b`
  - 类型选「发布」→ 无需设备 → 下载 `.p7b`
- 注意：Profile 里的 **bundleName 必须和 `harmony/AppScope/app.json5` 里的一致**（当前 `com.carhi.carlifephone`）。

取真机 UDID：

```bash
hdc shell bm get --udid
# 若报错，换： HdcExternal.exe shell bm get --udid
```

### 3. 落盘后签名

把 AGC 下载的文件按上表命名放进 `certs/`，然后：

```bash
bash tools/sign.sh              # 用 debug 证书签
bash tools/sign.sh release      # 用 release 证书签
```

或者让构建一步到位（构建 + 签名）：

```bash
bash tools/build.sh signed
```

## 关于 SDK 自带的 OpenHarmony.p12

`E:/AITools/command-line-tools/sdk/default/openharmony/toolchains/lib/OpenHarmony.p12`
（密码 `123456`）是 **OpenHarmony 官方 demo 用的**，**不能用于 HarmonyOS 真机安装**。实测结论：

- 里面 8 个别名中，`openharmony application release` 等应用证书是**自签的**
  （issuer == subject），并非由 `OpenHarmony Application CA` 签发。
- 因此拼成三级-二级-根的链条必然报
  `verify certificate chain failed! Signature does not match.`
- 唯一带 2 级链的非自签别名是 `openharmony application ca`，但它不是软件签名证书，
  签出来的包在 `verify-app` 阶段报 `verify permission signature failed, msg: Wrong key usage`。

结论：**申请华为开发者证书是必须的，没有捷径。** 本目录里的 `keystore.p12`
必须是自己生成的、与 AGC 上那张 `.cer` 配对的那一份。

---

## 复用旧证书？先搞清"三件套缺哪个"

签名需要三样，**缺一不可**。最容易误解的一点是：
**Profile（`.p7b`）只是"授权声明"，里面没有私钥。**

| 需要 | 作用 | 能否改 | 能否从别处推导 |
|---|---|---|---|
| `.p12` | **私钥**，真正用来签名 | 不能 | **不能** —— 丢了就签不了 |
| `.cer` | 证书链（三级-二级-根） | 不能 | 若 `.p12` 自带链，可自行导出 |
| `.p7b` | Profile：授权 + 设备白名单 | **不能改**（华为签过名） | 必须 AGC 生成 |

### 判定方法

拿到任何一份 `.p12`，先跑：

```bash
bash tools/sign.sh inspect <p12路径> <密码>
```

它会输出：别名、**自带证书链长度**、并与已有 `.p7b` 内嵌的开发证书**比对 sha256 指纹**
（判断是不是同一张证书）。

判读规则：

- **链长度 >= 3** → 可直接当 `-appCertFile` 用，不用单独找 `.cer`
- **链长度 = 0** → 只有私钥，还需要 AGC 那张 `.cer`
- **指纹 NO 不匹配** → 这份 p12 与那个 p7b 不是一对，不能混用

### 三条路线

假设你手上有一个旧项目的 `.p7b`（例如 `HomeGameDebug.p7b`），
但它的 `bundle-name` 与当前工程不同。此时：

| 路线 | 做法 | AGC 操作 | 风险 |
|---|---|---|---|
| **A（推荐）** | 保持自己的包名，去 AGC **只新建一个 Profile**（可引用同一张证书 + 同一台设备） | 1 步 | 无 |
| **B** | 用 `tools/bundle.sh` 把包名改成与旧 Profile 一致，直接用旧 `.p7b` | 0 步 | ⚠️ 同包名 + 同证书 = 系统判定为**升级**，会**覆盖手机上的那个应用** |
| **C（不依赖旧机器）** | 用本目录已生成的 `carhi.csr` 去 AGC 新建证书 + 新建 Profile | 2 步 | 无 |

**三条路线都需要 `.p12` 私钥**（除了 C 用的是本目录新生成的那份）。
没有私钥，A 和 B 都无从谈起。

### 路线 B 的操作

```bash
bash tools/bundle.sh cn.zm.homegame.controller   # 切换包名
bash tools/build.sh signed                        # 构建 + 签名
# 调试完务必改回：
bash tools/bundle.sh reset
```

**为什么风险栏要写"覆盖"**：HarmonyOS 判定两个包是不是同一个应用，看的是
`bundleName` + 签名证书。两者都相同 → 视为同一应用的升级包，直接替换。
如果那个包名的应用已经在手机上且有数据，数据会丢。

