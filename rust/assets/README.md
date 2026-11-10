# DNS 信任根

`cacert.pem` 下载自 [curl CA Extract](https://curl.se/docs/caextract.html)，内容来自 Mozilla NSS，采用 Mozilla Public License 2.0。证书包内保留来源日期和各证书指纹；许可全文随应用位于 `assets/licenses/mozilla-mpl-2.0.txt`。

本次文件 SHA-256：`427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285`，已与官方 `cacert.pem.sha256` 核对。

Courierust 优先加载操作系统信任库；仅在平台无法读取该库时使用此包。维护版本时从 `https://curl.se/ca/cacert.pem` 更新，核对下载内容与官方 SHA-256，再运行加密 DNS 联网测试。不要向该文件添加私人 CA、代理证书或私钥。
