# 签名与真机调试（AppGallery Connect 操作步骤）

装到真机需要三样东西，它们都由华为侧签发/校验，**不在这个仓库里**（`signing/` 已被 `.gitignore` 忽略）：

| 文件 | 是什么 |
|---|---|
| `debug.p12` | 你自己的密钥库（EC NIST-P-256），私钥在这里 |
| `debug.cer` | AGC 用你的 CSR 签发的**调试证书** |
| `debug.p7b` | AGC 用你的 App ID + 证书 + 设备 UDID 签发的**调试 Profile**（provisioning profile） |

> ⚠️ `.p12` 是私钥、`.p7b` 绑定你的开发者账号 —— **绝对不要提交到 Git**。密钥库口令请用环境变量
> `SUPERTUX_OHOS_KEY_PWD` 传给脚本，不要写进文件。

---

## 1. 本地生成密钥库和 CSR

用华为命令行工具自带的 `hap-sign-tool.jar`（口令自己定，别用示例里的）：

```powershell
$CLT = 'E:\harmony_os\command-line-tools'          # 换成你的命令行工具路径
$jar = "$CLT\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar"
$alias = 'supertux'                                 # 记住这个别名，签名时要用
$pwd   = Read-Host -AsSecureString 'keystore password'   # 自己输入，不要落盘

java -jar $jar generate-keypair -keyAlias $alias -keyPwd <你的口令> `
     -keyAlg ECC -keySize NIST-P-256 `
     -keystoreFile signing\debug.p12 -keystorePwd <你的口令>

java -jar $jar generate-csr -keyAlias $alias -keyPwd <你的口令> `
     -subject "C=CN,O=SuperTux,OU=SuperTux,CN=supertux" -signAlg SHA256withECDSA `
     -keystoreFile signing\debug.p12 -keystorePwd <你的口令> -outFile signing\debug.csr
```

## 2. 在 AppGallery Connect 里办三件事

打开 <https://developer.huawei.com/consumer/cn/service/josp/agc/index.html> 并登录（需要实名开发者账号）。

1. **建应用**：「我的应用」→ 新建应用
   - 应用包名：与 `app/supertux-ohos/AppScope/app.json5` 的 `bundleName` **一致**（默认 `com.example.supertux2`）
   - 名称/分类/默认语言随意填（分类选不选"游戏"都行，见下方说明）

2. **「证书、App ID和Profile」→ 证书管理 → 新增证书**
   - 证书类型：**调试证书**
   - 上传文件：`signing\debug.csr`
   - 提交后下载 `.cer` → 存为 `signing\debug.cer`

3. **设备管理 → 新增设备**
   - 名称随意；UDID 用这条命令取（要连上手机并开启 USB 调试）：
     ```powershell
     hdc shell bm get -u
     ```

4. **Profile 管理 → 新增 Profile**
   - 类型：**调试**
   - 选择上面的 App ID、刚建的调试证书、刚注册的设备
   - 提交后下载 `.p7b` → 存为 `signing\debug.p7b`

## 3. 构建、签名、安装

```powershell
$env:SUPERTUX_OHOS_KEY_PWD = '<你的密钥库口令>'
.\scripts\build-supertux-hap.ps1
```

脚本会：打包 HAP → 用 `hap-sign-tool sign-app -mode localSign` 本地签名 → `hdc install -r` →
`aa start` → 抓 hilog → 截图。等价的手工命令：

```powershell
java -jar $jar sign-app -keyAlias supertux -keyPwd <口令> -signAlg SHA256withECDSA -mode localSign `
  -appCertFile signing\debug.cer -profileFile signing\debug.p7b `
  -inFile   app\supertux-ohos\entry\build\default\outputs\default\entry-default-unsigned.hap `
  -outFile  app\supertux-ohos\entry\build\default\outputs\default\entry-default-signed.hap `
  -keystoreFile signing\debug.p12 -keystorePwd <口令> -compatibleVersion 26 -signCode 1

hdc install -r app\supertux-ohos\entry\build\default\outputs\default\entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.example.supertux2
hdc shell "hilog -x -e supertux -v time"
```

---

## 4. 几个踩过的坑

- **hvigor 的 `signingConfigs` 用不了**：它要求 DevEco 那种加密过的口令格式（长度 ≥ 32 的字符串），
  自己用 CSR 申请的证书没有这种口令，所以本仓库走 `hap-sign-tool` 手工签名，而不是让 hvigor 签。
- **bundleName 必须和 AGC 的 App ID 一致**：Profile 是按包名签发的，设备会校验两者；不一致会报
  `error: verify signature failed`（不是证书坏了）。
- **证书类型没有"游戏证书"**：AGC 只有调试证书 / 发布证书（另有企业应用发布证书）。应用 vs 游戏是
  **应用分类 + 上架资质**的差别（游戏要选游戏分类/标签、走游戏审核），不影响运行时的窗口/系统栏行为。
- **Profile 有效期通常 ~半年到一年**，过期后重新在 AGC 签一份即可（`signing/` 里旧文件直接替换）。
- 换设备（UDID 变了）也要在 AGC 设备管理里加新设备并重新签 Profile。
