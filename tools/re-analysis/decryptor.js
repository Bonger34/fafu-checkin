// ============================================================
// jsjiami.com.v7 解混淆参考实现（历史实例，2026-09）
//
// 用途：打卡系统改版时，参考本文件的解码逻辑处理新版混淆代码；
//       完整流程与适配步骤见同目录 README.md。
//
// 组成：
//   SRC     原始静态数组（从混淆源码原样提取，38 项）
//   RUNTIME 运行时数组 = SRC[2:] 左旋 30（本实例的轮转结果；
//           新实例需重新求值：枚举轮转位置使自校验公式命中）
//   p()     解码器（自定义字母表 base64 → UTF-8 → RC4，可复用）
//
// 验证样例：p(177,"1d^G") === "floor"
// ============================================================

var SRC = [
  "jsjiami.com.v7",
  "yyjsKWljhXLibarmiJR.lcoTDKmXA.MuvKEK7nJh==",
  "WQbSW5tcQCoL",
  "WQddVmkOW5dcH8k+",
  "W7ZcHqGLWQ0",
  "rmo+ESoXW4ZdUNWKg8kCAsdcVG",
  "W7xcQxNdO8oM",
  "WOpdHSo6dI7dI8k2W7ZcHLtcMKxcTW",
  "lSoXWRdcNNVdG07cPxNdNblcGJP4",
  "FmkOWPFcGSohf3/dNuJcR3VdISkn",
  "WPVcNCkpor4",
  "WQKXDCkremkrWR5IvCkDWR8KW7K+",
  "aCkSf8oCW58",
  "psT+wCovF0iyWQu0WRO7FG",
  "W70ADSk5W5hcMmkR",
  "W5JcP8k5W43cI8kjWQXYd8kJBa",
  "nsr/wSoBF01+WOe9WOCaBSo2",
  "W6tcSeTWl8oIDsXo",
  "iSoUWRxcMgG",
  "WRFcRN/dTSonW5NdLG",
  "ds41o11Gbq",
  "FmooBSogWOBcQmo9",
  "yNeGbSkr",
  "sSo6E2tdKG",
  "WOnUWQiHWPXeimoQWOFdK2y",
  "EKa8W6b/",
  "WR/cL3FdLeGwc8ozW4ddLmomWRPd",
  "qWitAmoL",
  "W5BdUmoRWQNcTCkSW4ZcVmkacIpdNmkpWPy",
  "WOtcSmk5EMtcNmou",
  "WQy+WOa2a8klWRe",
  "DCkFmCkAW5xdM8kkublcGCkaWRiN",
  "WRNcLxtdLK8xbmohW7ddP8oNWRnc",
  "smo6kKmoW4XKWPbDf8kifvi",
  "WQLmo8kVW7VcVSkxFd8",
  "WPBdGtf2kCoVAXbFhSkLj33cMXJdT3X+uCoCW6VcL1riWP/cPbXbWRdcKmknfSopqSkHuLWWa8kRWQldIGxcSCkGWORcU8o5WOmNo05fjfT7W65DESopW4VcPW",
  "W5tdH8oef2a",
  "WOxcVCkWW7ddOSo4WPZdHmk0aIFcSmkk",
];

// 还原运行时轮转（本实例：去掉前 2 项后左旋 30）
var RUNTIME = SRC.slice(2);
for (var i = 0; i < 30; i++) RUNTIME.push(RUNTIME.shift());

function b() { return RUNTIME; }

function p(e,n){var t=b();return p=function(n,c){n-=155;var a=t[n];if(void 0===p["KCEGTn"]){var u=function(e){for(var n,t,c="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=",a="",u="",o=0,r=0;t=e["charAt"](r++);~t&&(n=o%4?64*n+t:t,o++%4)?a+=String["fromCharCode"](255&n>>(-2*o&6)):0)t=c["indexOf"](t);for(var i=0,h=a["length"];i<h;i++)u+="%"+("00"+a["charCodeAt"](i)["toString"](16))["slice"](-2);return decodeURIComponent(u)},o=function(e,n){var t,c,a=[],o=0,r="";for(e=u(e),c=0;c<256;c++)a[c]=c;for(c=0;c<256;c++)o=(o+a[c]+n["charCodeAt"](c%n["length"]))%256,t=a[c],a[c]=a[o],a[o]=t;c=0,o=0;for(var i=0;i<e["length"];i++)c=(c+1)%256,o=(o+a[c])%256,t=a[c],a[c]=a[o],a[o]=t,r+=String["fromCharCode"](e["charCodeAt"](i)^a[(a[c]+a[o])%256]);return r};p["bvbdYA"]=o,e=arguments,p["KCEGTn"]=!0}var r=t[0],i=n+r,h=e[i];return h?a=h:(void 0===p["TXImix"]&&(p["TXImix"]=!0),a=p["bvbdYA"](a,c),e[i]=a),a},p(e,n)}
