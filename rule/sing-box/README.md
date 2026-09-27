# sing-box 规则集（Rule-Set）

本目录为 [sing-box](https://sing-box.sagernet.org) 的 **规则集（rule-set）**，由本仓库 `rule/Surge` 下的 `.list` 规则自动转换生成，适配 sing-box **1.11+ 及 alpha / beta** 版本。

每个服务同时提供两种文件：

- `xxx.json` —— 源文件格式（source），可读、可直接引用；
- `xxx.srs` —— 二进制格式（binary），加载更快，使用 sing-box **alpha 版（v1.15.0-alpha.9）** 编译并校验通过。

> 生成脚本：仓库根目录 [`generate_singbox_ruleset.ps1`](../../generate_singbox_ruleset.ps1)

## 格式说明

- 源文件采用 sing-box 规则集 **源文件格式（source format）**，即 JSON；二进制为编译后的 `.srs`。
- `version` 字段为 **3**（sing-box 1.11.0 引入，当前 alpha / beta 及所有 1.11+ 稳定版均兼容）。
- 每个服务目录对应 `rule/Surge` 下的同名目录，文件由 `xxx.list` 转换为 `xxx.json` 并编译为 `xxx.srs`。
- 已跳过 Surge 的 `_Resolve` / `_No_Resolve` 变体（仅 `no-resolve` 标记不同，对 sing-box 无意义）。

参考文档：

- 规则集：https://sing-box.sagernet.org/zh/configuration/rule-set/
- 源文件格式：https://sing-box.sagernet.org/zh/configuration/rule-set/source-format/
- 无头规则：https://sing-box.sagernet.org/zh/configuration/rule-set/headless-rule/

## 字段映射

| Surge 规则       | sing-box 规则项    | 说明 |
| ---------------- | ------------------ | ---- |
| `DOMAIN`         | `domain`           | 完整域名 |
| `DOMAIN-SUFFIX`  | `domain_suffix`    | 域名后缀 |
| `DOMAIN-KEYWORD` | `domain_keyword`   | 域名关键字 |
| `IP-CIDR`        | `ip_cidr`          | IPv4 CIDR |
| `IP-CIDR6`       | `ip_cidr`          | IPv6 CIDR（与 IPv4 合并） |
| `PROCESS-NAME`   | `process_name`     | 进程名（单独作为一条规则，见下） |
| `IP-ASN`         | —                  | 规则集不支持，已跳过 |
| `USER-AGENT`     | —                  | 规则集不支持，已跳过 |
| `URL-REGEX`      | —                  | 仅 HTTP 层，规则集不支持，已跳过 |
| `AND`/`OR`/`NOT` | —                  | 逻辑规则未转换，已跳过 |

### 关于 `domain_suffix`

sing-box 中不带前导点的后缀（如 `google.com`）会同时匹配 **该域名本身**（`google.com`）与 **其子域名**（`*.google.com`），这与 Surge 的 `DOMAIN-SUFFIX` 语义一致，因此值原样传递。

### 关于 `process_name` 单独成条

sing-box 默认规则中，域名 / IP 组与其它字段之间为 **与（AND）** 关系：

```
(domain || domain_suffix || domain_keyword || ip_cidr) && process_name
```

为保持「域名/IP **或** 进程名任一命中即可」的分流语义，进程名被放入 **第二条规则对象**（规则集内多条规则之间为 **或（OR）** 关系）：

```json
{
  "version": 3,
  "rules": [
    { "domain_suffix": ["google.com"], "ip_cidr": ["74.125.0.0/16"] },
    { "process_name": ["com.google.android.gms"] }
  ]
}
```

## 使用方法

### 1. 远程规则集（推荐）

在 sing-box 配置的 `route.rule_set` 中引用（`format` 为 `source`）：

```json
{
  "route": {
    "rule_set": [
      {
        "type": "remote",
        "tag": "google",
        "format": "source",
        "url": "https://raw.githubusercontent.com/MangTianYa/ios_rule_script/master/rule/sing-box/Google/Google.json",
        "update_interval": "1d"
      }
    ],
    "rules": [
      { "rule_set": "google", "outbound": "proxy" }
    ]
  }
}
```

> jsDelivr CDN 加速可将 `https://raw.githubusercontent.com/MangTianYa/ios_rule_script/master/` 替换为 `https://cdn.jsdelivr.net/gh/MangTianYa/ios_rule_script@master/`。

### 2. 编译为二进制 `.srs`（本目录已内置，加载更快）

本目录已提供预编译的 `.srs`，远程引用时把 `format` 改为 `binary`、`url` 指向 `.srs` 文件即可：

```json
{
  "type": "remote",
  "tag": "google",
  "format": "binary",
  "url": "https://raw.githubusercontent.com/MangTianYa/ios_rule_script/master/rule/sing-box/Google/Google.srs",
  "update_interval": "1d"
}
```

如需自行编译：

```bash
sing-box rule-set compile --output Google.srs Google.json
```

### 3. 本地规则集

```json
{
  "type": "local",
  "tag": "google",
  "format": "source",
  "path": "rule/sing-box/Google/Google.json"
}
```

## 重新生成

在仓库根目录执行（Windows PowerShell）：

```powershell
# 全量生成
powershell -ExecutionPolicy Bypass -File .\generate_singbox_ruleset.ps1

# 仅生成指定服务
powershell -ExecutionPolicy Bypass -File .\generate_singbox_ruleset.ps1 -Services Google

# 生成并编译为 .srs（需已安装 sing-box）
powershell -ExecutionPolicy Bypass -File .\generate_singbox_ruleset.ps1 -Compile
```

## 已知限制

- **纯 `IP-ASN` / `USER-AGENT` / `URL-REGEX` 的规则**（如 `ChinaASN`、`MOOMusic`）在 sing-box 规则集中无对应项，生成的文件为空规则集（`"rules": []`，匹配为空）。ASN 分流请改用 sing-box 内建能力。
- 规则数据全部来自本仓库 `rule/Surge`，规则内容与上游保持一致。
