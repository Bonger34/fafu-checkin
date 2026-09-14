# 重新逆向参考（re-analysis）

打卡系统改版、签到失效时（判定方法见 [docs/DEVELOPMENT.md](../../docs/DEVELOPMENT.md) §4），
用本目录的参考实现处理新版混淆代码。

## 文件

| 文件 | 说明 |
|---|---|
| `decryptor.js` | jsjiami.com.v7 解混淆参考实现（可直接运行验证）：`SRC` 原始静态数组、`RUNTIME` 还原轮转后的数组、`p()` 解码器 |

## 适配新版步骤

1. **提取**：从新版 `app.*.js` 提取字符串表（形如 `[m,"…","…"].concat(…)` 的嵌套结构），替换 `decryptor.js` 的 `SRC`；
2. **还原轮转**：字符串表在运行时会被自校验代码轮转（静态顺序不对）。
   还原方法：枚举所有轮转位置，对每个位置用自校验公式验证，命中校验和（本实例为 `832533`，
   在源码 IIFE 的调用参数中）即为正确位置；
3. **解码**：用 `p(idx, key)` 逐条解码（`key` 是调用处的第二个参数，如 `t(177,"1d^G")`）；
4. **验证**：解出的 `hashStr` 应指向标准 MD5；密钥应为 32 位可见字符串
   （当前值见 [docs/DEVELOPMENT.md](../../docs/DEVELOPMENT.md) §1.3）；
5. **同步模块**：按 §4 更新 `fafu_checkin.sh` 中的 `SECRET` 与接口路径。

## 验证样例（本实例，可复现）

```js
p(177, "1d^G") === "floor"
p(167, "1d^G") === "jsjiami.com.v7"
p(189, "ZRR#") === "hashStr"
p(162, "9wks") === "random"
p(173, "kx3]") === "getTime"
p(158, "AP*a") === "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
```

> 跑法：`node decryptor.js` 后用上述断言自检，或把文件加载进任意 JS 引擎调用 `p()`。
