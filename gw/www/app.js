/* app.js v3.32 (P2: WPA3虚假选项移除(hostapd仅WPA2-PSK); plmnScan XSS修复(textContent); v3.31: sse带token) -- v3 gateway console SPA
 * v3.28: 聚合五模式选择; v3.27: SSE 实时信号; v3.26: 聚合滑块应用后回读同步
 * v3.4: WiFi 分析仪(信道图/信道评级/AP列表/时间图 canvas多视图) + 信道下拉统一(2.4G补select, 双频加"自动"档)
 * 刷新机制彻底重做: 页面骨架只建一次(进入时), 轮询仅更新文本槽/小表格
 *   T(id,v) 文本槽(带变化检测)  H(id,v) 局部HTML(tbody级,带变化检测)
 *   F(id,v) 表单值(聚焦中不打扰)  —— 整页DOM永不重建: 无滚动丢失/无闪烁/
 *   下拉不打断/扫描状态天然存活 */
"use strict";

/* ---------- api client ---------- */
let TOKEN = sessionStorage.getItem("gw_token") || "";
async function api(ep, body) {
    const opt = body
        ? { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: body + (TOKEN ? `&token=${TOKEN}` : "") }
        : { cache: "no-store", url: undefined };
    const url = body ? "/api/" + ep : `/api/${ep}${TOKEN ? `?token=${TOKEN}` : ""}`;
    const r = await fetch(url, opt);
    const j = await r.json().catch(() => ({ error: "bad_json" }));
    if (j.error === "need_login") { setLogin(false); showLoginWall(); throw new Error("need_login"); }
    return j;
}
function esc(s) { return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function fmtB(b) { b = +b; if (!isFinite(b)) return "--"; if (b > 1e9) return (b / 1e9).toFixed(2) + " GB"; if (b > 1e6) return (b / 1e6).toFixed(1) + " MB"; if (b > 1e3) return (b / 1e3).toFixed(0) + " KB"; return Math.round(b) + " B"; }
function toast(msg, bad) {
    const t = document.getElementById("toast");
    t.textContent = msg; t.className = "show" + (bad ? " bad" : "");
    setTimeout(() => t.className = "", 2600);
}
function modal(title, html) {
    document.getElementById("modal-title").textContent = title;
    document.getElementById("modal-body").innerHTML = html;
    document.getElementById("modal").classList.remove("hidden");
}
function modalClose() { document.getElementById("modal").classList.add("hidden"); }
document.getElementById("modal").addEventListener("click", e => { if (e.target.id === "modal") modalClose(); });

/* ---------- 用户可见文案基准: docs/GUI_TERMINOLOGY.md ---------- */
/* 错误码 -> 中文原因 (api.sh jerr 全集); 未列码兜底"操作失败" (术语表第七节) */
const ERR = {
    need_login: "登录已过期，请重新登录", bad_login: "密码错误", bad_old: "当前密码错误", locked: "失败次数过多，请 15 分钟后再试",
    bad_pass: "密码不符合要求（8-63 位字母、数字或连字符）", need_guest_pass: "开启访客网络前请先设置访客密码",
    bad_chars: "名称含不支持的字符（仅限字母、数字、空格与 . _ -）", bad_len: "名称过长（最多 32 个字符）",
    bad_ip: "IP 地址格式不正确", bad_mac: "MAC 地址格式不正确", bad_num: "请输入数字",
    bad_lease: "租期格式不正确（示例：12h）", dnsmasq_fail: "局域网服务启动失败",
    bad_proto: "协议只能是 TCP 或 UDP", bad_port: "端口需为 1-65535", bad_pct: "权重需在 5-95 之间",
    bad_mode: "模式取值无效", bad_op: "操作类型无效", bad_flag: "开关取值无效", bad_action: "操作类型无效",
    bad_ch: "2.4GHz 信道需为 0-13", bad_ch5: "5GHz 信道取值无效", bad_bw: "带宽取值无效",
    bad_power: "发射功率需为 25-100", bad_auth: "加密方式无效", bad_band: "访客频段无效",
    bad_bands: "频段格式不正确（逗号分隔的数字）", empty_bands: "请至少填写一个频段",
    bad_arfcn: "频点（ARFCN）需为 0-875000", bad_pci: "PCI 需为 0-2000", bad_act: "制式无效",
    bad_idx: "序号无效", dup_cell: "该小区已在列表中", list_full: "列表已满（最多 20 条）",
    mipc_fail: "模组设置失败", tree_fail: "配置写入失败", at_fail: "模组无响应，请稍后重试",
    ioctl_fail: "硬件接口调用失败", pin_fail: "PIN 操作失败", bad_pin: "PIN 码只能为数字",
    bad_name: "主机名含不支持的字符", bad_srv: "服务器地址格式不正确", bad_tz: "时区格式不正确",
    bad_ucs2: "短信编码格式不正确", empty_text: "短信内容不能为空", too_long: "内容过长",
    need_ucs2: "暂不支持中文短信（仅英文/数字）", send_fail: "短信发送失败",
    scan_failed: "扫描失败，请重试", tool_missing: "扫描组件缺失，请重试",
    uplink_no_conf: "请先填写静态 IP 与网关", mac_fail: "MAC 地址设置失败", addr_fail: "IP 地址设置失败",
    bad_cmd: "认证命令仅限命令行修改", bad_form: "档案类型无效", sse_busy: "实时刷新通道繁忙，请稍后重试", unknown: "未知操作",
    post_only: "请求方式不正确", bad_json: "响应解析失败", ubus: "系统信息服务暂不可用"
};
const eMsg = e => ERR[e] ? "操作失败：" + ERR[e] : "操作失败";
/* 蜂窝频段统一写法: mipc 出 N41, 树出 41 -> n41 / B41 (术语表第六节; G-03) */
const fmtBand = b => { b = String(b == null ? "" : b).trim(); if (!b || b === "--") return "--"; if (/^N/i.test(b)) return "n" + b.slice(1); if (/^B/i.test(b)) return b; return /^\d+$/.test(b) ? "B" + b : b; };
/* /tmp/wan_mode 内容(off|agg:S1:S2) -> 运行状态文案; 空=检测中 (G-13/G-14, 不直出内部 token) */
const wanModeTxt = v => !v ? "检测中" : (v === "off" ? "已停用" : "运行中");
/* v3.29: 聚合五模式文案(status.agg.m5); 状态页权重行仅 weight 模式有意义 */
const AGG_MODE_TXT = { weight: "按权重分流", cell_prio: "蜂窝优先", eth_prio: "有线宽带优先", cell_only: "仅蜂窝", eth_only: "仅有线宽带" };
const aggModeTxt = m => AGG_MODE_TXT[m] || (m ? m : "—");
const TZ_TXT = { "CST-8": "北京时间（UTC+8）", "UTC": "UTC" };
/* cells 归一: mipc=对象数组, 树=逗号串五元组 -> [{band,arfcn,pci,rsrp,sinr}] (G-05) */
const celRows = j => {
    const c = j && j.cells;
    if (Array.isArray(c)) return c.map(x => ({ band: x.band, arfcn: x.arfcn, pci: x.pci, rsrp: x.rsrp, sinr: x.sinr }));
    if (c && c.band) {
        const g = k => String(c[k] || "").split(",");
        return g("band").filter(Boolean).map((b, i) => ({ band: b, arfcn: g("arfcn")[i], pci: g("pci")[i], rsrp: g("rsrp")[i], sinr: g("sinr")[i] }));
    }
    return [];
};

/* ---------- DOM 更新助手 (刷新机制v4核心) ---------- */
const $ = id => document.getElementById(id);
const T = (id, v) => { const e = $(id); if (e && e.textContent !== v) e.textContent = v; };
const H = (id, v) => { const e = $(id); if (e && e.innerHTML !== v) e.innerHTML = v; };
/* v3.8 脏标记: 用户改过的表单控件不再被轮询回填(原 F() 只护聚焦控件, 改完第二个
 * 字段时第一个已被打回服务器值)。服务器值追平(应用成功)或换页时自动解除。 */
const DIRTY = new Set();
document.addEventListener("input", markDirty);
document.addEventListener("change", markDirty);
function markDirty(ev) {
    const t = ev.target;
    if (t && t.id && /^(input|select|textarea)$/i.test(t.tagName)) {
        DIRTY.add(t.id);
        t.classList.add("dirty");
    }
}
const F = (id, v) => {
    const e = $(id); if (!e) return;
    if (String(e.value) === String(v)) {          // 收敛: 服务器已追平 -> 解除脏标
        if (DIRTY.delete(id)) e.classList.remove("dirty");
        return;
    }
    if (DIRTY.has(id) || document.activeElement === e) return;   // 脏或聚焦: 不打扰
    e.value = v;
};

function setLogin(on) {
    TOKEN = on ? TOKEN : "";
    if (!on) sessionStorage.removeItem("gw_token");
}
function logout() { api("logout").catch(() => {}); setLogin(false); showLoginWall(); }
window.logout = logout;

/* ---------- 视图小件 ---------- */
function card(title, inner, wide, id) { return `<div class="card${wide ? " wide" : ""}"${id ? ` id="${id}"` : ""}><h3>${title}</h3>${inner}</div>`; }
function kv(k, id, mono) {
    return `<div class="kv"><span>${k}</span><b id="${id}" class="${mono ? "mono" : ""}">--</b></div>`;
}
function tag(id, onTxt, offTxt) { return `<span class="tag" id="${id}" data-on="${onTxt}" data-off="${offTxt}">--</span>`; }
function setTag(id, ok) { const e = $(id); if (!e) return; const v = ok == null ? "--" : (ok ? e.dataset.on : e.dataset.off); if (e.textContent !== v) { e.textContent = v; e.className = "tag " + (ok == null ? "" : (ok ? "on" : "off")); } }   // v3.29: null=未知态(G-09)

/* ---------- pages ---------- */
const PAGES = {};
let timer = null;

/* ================ 状态 ================ */
PAGES.status = {
    html: `<div class="grid">
      ${card("系统", kv("运行时间", "up-up") + kv("负载", "up-load") + kv("内存", "up-mem") + kv("LAN", "up-lan"))}
      ${card("上网线路 · 蜂窝（5G/4G） " + tag("tg-5g", "已连接", "未连接"),
        kv("接口", "w5-if") + kv("IPv4", "w5-ip", 1) + kv("IPv6", "w5-v6", 1) +
        `<div class="rate"><span>下行 <b id="w5-rx">…</b></span><span>上行 <b id="w5-tx">…</b></span></div>`)}
      ${card("上网线路 · 有线宽带 " + tag("tg-home", "已连接", "未连接"),
        kv("IPv4", "ho-ip", 1) + kv("IPv6", "ho-v6", 1) +
        `<div class="rate"><span>下行 <b id="ho-rx">…</b></span><span>上行 <b id="ho-tx">…</b></span></div>`)}
      ${card("蜂窝 " + tag("tg-cel", "已驻网", "无服务"),
        kv("运营商", "cel-op") + kv("服务小区", "cel-cell", 1) + kv("信号强度", "cel-sig") + kv("小区数", "cel-n"))}
      ${card("聚合 " + tag("tg-agg", "运行中", "已停用"),
        kv("转发引擎", "agg-eng") + kv("聚合模式", "agg-mode") + kv("分流权重 蜂窝/有线宽带", "agg-w") + kv("运行状态", "agg-st"))}
      ${card("WiFi " + tag("tg-wifi", "正常", "异常"),
        kv("2.4GHz", "wf-2g") + kv("5GHz", "wf-5g") + kv("无线服务", "wf-hap"))}
      ${card("温度", '<div id="tp-body"></div>')}
      ${card("IPv6 LAN", kv("ULA", "v6-ula", 1) + kv("方式", "v6-mode"))}
    </div>`,
    async tick() {
        const j = await api("status");
        const cel = await api("cellular").catch(() => null);
        const ms = lastTs ? (j.ts - lastTs) * 1000 : 0;
        const rate = (cur, prev) => ms > 0 ? fmtB((cur - prev) * 1000 / ms) + "/s" : "…";
        T("up-up", j.uptime); T("up-load", j.load);
        T("up-mem", `${((1 - j.mem.avail / j.mem.total) * 100).toFixed(0)}% (${fmtB(j.mem.avail * 1024)} 可用)`);
        T("up-lan", "192.168.9.1/24");
        setTag("tg-5g", j.wan5g.ip !== "无");
        T("w5-if", j.wan5g.if || "--"); T("w5-ip", j.wan5g.ip); T("w5-v6", j.wan5g.v6);
        T("w5-rx", lastCounters ? rate(+j.counters.rx5g, +lastCounters.rx5g) : "…");
        T("w5-tx", lastCounters ? rate(+j.counters.tx5g, +lastCounters.tx5g) : "…");
        setTag("tg-home", j.home.carrier === "1");
        T("ho-ip", j.home.ip); T("ho-v6", j.home.v6);
        T("ho-rx", lastCounters ? rate(+j.counters.rxeth, +lastCounters.rxeth) : "…");
        T("ho-tx", lastCounters ? rate(+j.counters.txeth, +lastCounters.txeth) : "…");
        if (cel && cel.serving) {
            setTag("tg-cel", fmtBand(cel.serving.band) !== "--");   // G-02: mipc 无 rat 字段, 按频段判驻网
            T("cel-op", `${cel.operator.name} (${cel.operator.plmn})`);
            T("cel-cell", `${fmtBand(cel.serving.band)} · ARFCN ${cel.serving.arfcn} · PCI ${cel.serving.pci}`);
            T("cel-sig", `RSRP ${cel.serving.rsrp} dBm · SINR ${cel.serving.sinr} dB`);
            T("cel-n", `${cel.n != null ? cel.n : celRows(cel).length} 个小区`);   // G-04: mipc 下 cells 是数组, 读顶层 n
        } else { setTag("tg-cel", false); T("cel-op", "--"); T("cel-cell", "--"); T("cel-sig", "--"); T("cel-n", "--"); }
        const aggUnk = j.agg.on === "1" && !j.agg.wanmode;   // G-09: wan_mode 文件缺失时 on 误报 1
        setTag("tg-agg", aggUnk ? null : j.agg.on === "1");
        T("agg-eng", j.agg.engine === "vendor" ? "硬件加速" : (j.agg.engine ? "软件转发" : "--"));
        T("agg-mode", aggModeTxt(j.agg.m5));
        const inWeight = j.agg.m5 === "weight";   // v3.29: 权重仅 weight 模式有意义, 其余模式显不适用
        const wpOk = inWeight && /^\d+$/.test(j.agg.w1pct);
        T("agg-w", wpOk ? `${j.agg.w1pct}% / ${100 - j.agg.w1pct}%` : (inWeight ? "—" : "不适用"));
        T("agg-st", aggUnk ? "--" : wanModeTxt(j.agg.wanmode));   // G-14: 不直出日志行
        const w = j.wifi || {};
        setTag("tg-wifi", (w.hostapd2g > 0) && (w.hostapd5g > 0));
        T("wf-2g", `${w.ssid2g || "?"} · ${w.secured ? "已加密" : "开放"} · ch${w.ch2g}`);
        T("wf-5g", `${w.ssid5g || "?"} · ${w.secured ? "已加密" : "开放"} · ch${w.ch5g}`);
        T("wf-hap", `${w.hostapd2g > 0 ? "2.4GHz 正常" : "2.4GHz 异常"} · ${w.hostapd5g > 0 ? "5GHz 正常" : "5GHz 异常"}`);
        H("tp-body", Object.entries(j.temps || {}).map(([k, v]) => `<div class="kv"><span>${k}</span><b>${(v / 1000).toFixed(1)} °C</b></div>`).join(""));
        T("v6-ula", "fd42:9ac1:7e50::/64"); T("v6-mode", "自动分配 + NAT 兼容");
        document.getElementById("hdr-sub").textContent = !j.agg.m5 ? "蜂窝 + 有线宽带聚合" : (inWeight ? `蜂窝 ${j.agg.w1pct}% / 有线宽带 ${100 - j.agg.w1pct}%` : aggModeTxt(j.agg.m5));   // v3.29: 非 weight 模式显模式名; G-07/G-37
        lastCounters = j.counters; lastTs = j.ts;
    }
};
let lastCounters = null, lastTs = 0;

/* ================ 终端 ================ */
PAGES.clients = {
    html: `<div id="cl-body">
      ${card(`终端列表（DHCP） <span class="tag on" id="cl-n">0 台</span>`, '<table><thead><tr><th>主机名</th><th>IP</th><th>MAC</th><th>状态</th><th></th></tr></thead><tbody id="cl-tb"></tbody></table>', 1)}
      ${card("DHCP 静态绑定", `<table><thead><tr><th>MAC</th><th>IP 地址</th><th>主机名</th><th></th></tr></thead><tbody id="ds-tb"></tbody></table>
         <div class="row3" style="margin-top:8px">
           <div class="frm"><label>MAC</label><input id="ds-mac" class="mono" placeholder="aa:bb:cc:dd:ee:ff"></div>
           <div class="frm"><label>IP 地址</label><input id="ds-ip" class="mono" placeholder="192.168.9.150"></div>
           <div class="frm"><label>主机名</label><input id="ds-name" placeholder="mypc"></div>
         </div>
         <button class="pri" onclick="dsAdd()">添加</button>`)}
      ${card("WiFi 已连接终端", '<table><thead><tr><th>接口</th><th>MAC</th><th>信号</th><th>↓</th><th>↑</th></tr></thead><tbody id="st-tb"></tbody></table>', 1)}
    </div>`,
    async tick() {
        const j = await api("clients");
        const fw = await api("fw");
        const blocked = new Set(fw.blocked || []);
        T("cl-n", `${(j.clients || []).length} 台`);
        H("cl-tb", (j.clients || []).map(c => `<tr><td>${esc(c.name) || "*"}</td><td class="mono">${c.ip}</td><td class="mono">${c.mac}</td>
            <td>${blocked.has(c.mac) ? `<span class="tag off">已禁网</span>` : `<span class="tag on">正常</span>`}</td>
            <td><button class="mini ${blocked.has(c.mac) ? "pri" : "ghost"}" onclick="blk('${c.mac}',${blocked.has(c.mac) ? 1 : 0})">${blocked.has(c.mac) ? "解禁" : "禁网"}</button></td></tr>`).join(""));
        H("st-tb", (j.stations || []).map(s => `<tr><td>${s.if}</td><td class="mono">${s.mac}</td><td>${s.signal} dBm</td><td>${fmtB(s.rx)}</td><td>${fmtB(s.tx)}</td></tr>`).join(""));
        const ds = await api("dhcp_static").catch(() => ({ entries: [] }));
        H("ds-tb", (ds.entries || []).map(e => `<tr><td class="mono">${e.mac}</td><td class="mono">${e.ip}</td><td>${esc(e.name)}</td>
            <td><button class="mini ghost" onclick="dsDel('${e.mac}')">删除</button></td></tr>`).join(""));
    }
};
window.blk = async (mac, del) => {
    const j = await api("block_set", `mac=${mac}&del=${del}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast(del ? "已解禁" : "已禁网"); PAGES.clients.tick(); } else toast(eMsg(j.error), 1);
};
window.dsAdd = async () => {
    const j = await api("dhcp_static_set", `op=add&mac=${$("ds-mac").value}&ip=${$("ds-ip").value}&name=${encodeURIComponent($("ds-name").value)}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已添加"); PAGES.clients.tick(); } else toast(eMsg(j.error), 1);
};
window.dsDel = async (m) => {
    const j = await api("dhcp_static_set", `op=del&mac=${m}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已删除"); PAGES.clients.tick(); } else toast(eMsg(j.error), 1);
};

/* v3.27: SSE 实时信号推送 — /api/sse 每3s推服务小区信号, 蜂窝卡免轮询等待;
 * EventSource 断线自动重连(浏览器原生), 轮询路径保留兜底。 */
(() => {
    if (window.SSE_SIG) return;
    try {
        const es = new EventSource("/api/sse" + (TOKEN ? `?token=${TOKEN}` : ""));   // v3.31: sse 已加 token 门
        window.SSE_SIG = es;
        let esf = 0;   // v3.31: 重连退避 — 未登录/凭证失效/连败3次即关流(防无限重连), 轮询兜底
        es.onopen = () => { esf = 0; };
        es.onerror = () => { if (!TOKEN || ++esf > 3) { es.close(); window.SSE_SIG = null; } };
        es.onmessage = e => {
            try {
                const j = JSON.parse(e.data);
                if (j && j.sig && j.sig.rsrp !== undefined) {
                    setTag("tg-cel", true);
                    T("cel-cell", `${fmtBand(j.sig.band)} · ARFCN ${j.sig.arfcn} · PCI ${j.sig.pci}`);
                    T("cel-sig", `RSRP ${j.sig.rsrp} dBm · SINR ${j.sig.sinr} dB`);
                }
            } catch (_) { }
        };
    } catch (_) { }
})();

/* ================ WiFi ================ */
PAGES.wifi = {
    html: `<div>
      ${card("WiFi 状态 " + tag("tg-wfst", "正常", "异常"),
        kv("2.4GHz", "wfs-2g") + kv("5GHz", "wfs-5g") + kv("加密方式", "wfs-sec") + kv("无线服务", "wfs-hap"))}
      ${card("主 WiFi 设置", `
        <div class="row3">
          <div class="frm"><label>网络名称（SSID）</label><input id="wa-base"></div>
          <div class="frm"><label>WiFi 密码（8-63 位）</label><input id="wa-pass" type="password" placeholder="留空=不修改"></div>
          <div class="frm"><label>加密方式</label><select id="wa-auth"><option value="WPA2PSK">WPA2</option></select><span class="hint">本机 hostapd 仅支持 WPA2-PSK（fh 魔改版不接受 SAE 口令派生），"WPA2+WPA3" 选项因名不符实已移除</span></div>
          <div class="frm"><label>2.4GHz 信道</label><select id="wa-ch2"><option value="0">自动 (启动时扫描选道)</option>${Array.from({length:13},(_,i)=>i+1).map(c=>`<option value="${c}">${c}</option>`).join("")}</select></div>
          <div class="frm"><label>2.4GHz 带宽（MHz）</label><select id="wa-bw2"><option value="20">20</option><option value="40">40</option></select></div>
          <div class="frm"><label>5GHz 信道</label><select id="wa-ch5"><option value="0">自动 (启动时扫描选道)</option>${[36,40,44,48,149,153,157,161].map(c=>`<option value="${c}">${c}</option>`).join("")}</select></div>
          <div class="frm"><label>5GHz 带宽（MHz）</label><select id="wa-bw5"><option value="20">20</option><option value="40">40</option><option value="80">80</option><option value="160">160 (含雷达信道，启用前检测约 1 分钟)</option></select></div>
          <div class="frm"><label>发射功率（%）</label><select id="wa-pw">${[25,50,75,100].map(p => `<option value="${p}">${p}</option>`).join("")}</select></div>
          <div class="frm"><label>隐藏网络名称</label><select id="wa-hid"><option value="0">关闭</option><option value="1">开启</option></select></div>
          <div class="frm"><label>双频同名</label><select id="wa-inone"><option value="0">独立双频</option><option value="1">同名双频（漫游）</option><option value="2">MLO 真双链路（WiFi7 并发）</option></select></div>
        </div>
        <button class="pri" onclick="waSave()">应用主 WiFi 设置</button>
        <span class="hint">应用后无线会短暂重启，已连接终端需重连；独立双频时自动加 -2.4G/-5G 后缀</span>`)}
      ${card("访客网络", `
        <div class="row3">
          <div class="frm"><label>访客网络</label><select id="wa-guest"><option value="0">关闭</option><option value="1">开启</option></select></div>
          <div class="frm"><label>访客网络名称</label><input id="wa-gssid" placeholder="空 = 默认名称"></div>
          <div class="frm"><label>访客频段</label><select id="wa-gband"><option value="5g">5GHz</option><option value="2g">2.4GHz</option><option value="both">双频（同名漫游）</option></select></div>
          <div class="frm"><label>访客密码</label><input id="wa-gpass" type="password" placeholder="8-63 位，开启时必填"></div>
        </div>
        <button class="pri" onclick="waSave()">应用访客设置</button>
        <span class="hint">名称、频段、密码独立于主 WiFi；访客仅可上网，与内网隔离</span>`)}
      ${card("终端频段锁定", `
        <div class="row3">
          <div class="frm"><label>MAC 地址</label><input id="bp-mac" placeholder="例如 aa:bb:cc:dd:ee:ff" class="mono"></div>
          <div class="frm"><label>锁定频段</label><select id="bp-band"><option value="2g">2.4GHz</option><option value="5g">5GHz</option></select></div>
          <div class="frm" style="align-self:end"><button class="pri mini" onclick="bpAdd()">添加</button></div>
        </div>
        <table><thead><tr><th>MAC 地址</th><th>锁定频段</th><th></th></tr></thead><tbody id="bp-tb"></tbody></table>
        <button class="pri" onclick="bpApply()">应用变更</button>
        <span class="hint">将终端固定在单一频段，避免双频之间频繁切换；应用后无线会短暂重启，已连接终端需重连。MLO 真双链路开启时，已锁定的终端自动回落单链路</span>`)}
      ${card("已连接终端", '<table><thead><tr><th>接口</th><th>MAC</th><th>信号</th><th>↓</th><th>↑</th></tr></thead><tbody id="wfs-tb"></tbody></table>')}
      ${card("WiFi 分析仪 (邻居网络)", `
        <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:8px">
          <button class="pri mini" onclick="waScan()">扫描</button>
          <label class="hint" style="display:flex;gap:5px;align-items:center;margin:0"><input type="checkbox" id="wa-auto" style="width:auto" onchange="waAuto(this.checked)"> 自动(15s)</label>
          <span id="wa-tabs" style="display:inline-flex;gap:2px">
            <button class="tb act" data-v="ch" onclick="waView('ch')">信道图</button>
            <button class="tb" data-v="rate" onclick="waView('rate')">信道评级</button>
            <button class="tb" data-v="list" onclick="waView('list')">AP列表</button>
            <button class="tb" data-v="time" onclick="waView('time')">时间图</button>
          </span>
          <span id="wa-band" style="display:inline-flex;gap:2px;margin-left:auto">
            <button class="tb act" data-b="2" onclick="waBand(2)">2.4GHz</button>
            <button class="tb" data-b="5" onclick="waBand(5)">5GHz</button>
          </span>
        </div>
        <canvas id="wa-cv" style="width:100%;height:340px"></canvas>
        <div id="wa-list" style="display:none"></div>
        <span class="hint" id="wa-info">点击扫描 — 信道图 / 信道评级 / AP 列表 / 信号时间图</span>`, 1)}
    </div>`,
    async tick() {
        const j = await api("wifi");
        WA.own = [j.ssid2g, j.ssid5g];   // 信道图只标注本机 SSID
        WA.ownCh = { 2: +j.ch2g || 0, 5: +j.ch5g || 0 };   // 本机信道(apcli扫不到自家BSS, 合成绘制)
        WA.ownBw = { 2: 20, 5: 80 };   // v3.17: 本机带宽(adv0 就绪后更新) — 信道图按真实频宽画矩形
        setTag("tg-wfst", (j.hostapd2g > 0) && (j.hostapd5g > 0));
        T("wfs-2g", `${j.ssid2g} · ch${j.ch2g}`); T("wfs-5g", `${j.ssid5g} · ch${j.ch5g}`);
        const adv0 = await api("wifi_adv").catch(() => ({}));
        if (adv0.bw2g) WA.ownBw[2] = +adv0.bw2g;
        if (adv0.bw5g) WA.ownBw[5] = +adv0.bw5g;
        F("wa-base", adv0.ssid_base || "");
        T("wfs-sec", j.secured ? "WPA2" : "开放");   // v3.32: WPA3 选项已移除(hostapd 不支持 SAE, 名不符实); 存量 WPA2PSKWPA3PSK 值实际亦为 WPA2
        T("wfs-hap", `${j.hostapd2g > 0 ? "2.4GHz 正常" : "2.4GHz 异常"} · ${j.hostapd5g > 0 ? "5GHz 正常" : "5GHz 异常"}`);
        H("wfs-tb", (j.stations || []).map(s => `<tr><td>${s.if}</td><td class="mono">${s.mac}</td><td>${s.signal} dBm</td><td>${fmtB(s.rx)}</td><td>${fmtB(s.tx)}</td></tr>`).join(""));
        const adv = await api("wifi_adv");
        F("wa-ch2", adv.ch2g); F("wa-bw2", adv.bw2g); F("wa-ch5", adv.ch5g);
        F("wa-bw5", adv.bw5g); F("wa-pw", adv.power); F("wa-hid", adv.hidden2g);
        F("wa-guest", adv.guest); F("wa-inone", adv.mlo == 1 ? "2" : adv.inone);
        F("wa-gband", adv.guest_band || "5g"); F("wa-gssid", adv.guest_ssid || "");
        F("wa-auth", "WPA2PSK");   // v3.32: 单一真实选项; 存量 WPA2+WPA3 存值回落
        $("wa-gssid").placeholder = `空 = 默认 ${adv.guest_ssid_eff || "名称-Guest"}`;
        bpList();   // v3.30: 终端频段锁定列表(带diff守卫, 不打字扰)
    }
};
/* v3.22: 主WiFi卡与访客卡共用一个原子提交(端点要求全字段);
 * 密码类字段仅在非空时上送(留空=不修改)。
 * v3.23: 双频合一 select 第3值=MLO真双链路(映射 mlo=1&inone=1, 其余映射 mlo=0) */
window.waSave = async () => {
    const io = $("wa-inone").value;
    const body = `ch2=${$("wa-ch2").value}&ch5=${$("wa-ch5").value}&bw2=${$("wa-bw2").value}&bw5=${$("wa-bw5").value}&power=${$("wa-pw").value}&hidden=${$("wa-hid").value}&guest=${$("wa-guest").value}&inone=${io === "2" ? 1 : io}&mlo=${io === "2" ? 1 : 0}&guest_ssid=${encodeURIComponent($("wa-gssid").value)}&guest_band=${$("wa-gband").value}&ssid_base=${encodeURIComponent($("wa-base").value)}&auth=${$("wa-auth").value}` +
        ($("wa-pass").value ? `&pass=${encodeURIComponent($("wa-pass").value)}` : "") +
        ($("wa-gpass").value ? `&guest_pass=${encodeURIComponent($("wa-gpass").value)}` : "");
    const j = await api("wifi_adv_set", body).catch(e => ({ error: e.message }));
    if (j.ok) {
        toast(j.mlo_changed ? "已应用 — MLO 开关已变化，无线正在重建（无需重启整机）" : "已应用，无线重启中");   // G-01: v2.43 起在线生效, mlo_reboot 死分支已删
        $("wa-pass").value = ""; $("wa-gpass").value = "";
        setTimeout(() => PAGES.wifi.tick(), 4000);
    } else toast(eMsg(j.error), 1);
};
/* ---------- 终端频段锁定 (v3.30: 主WiFi按MAC钉死单频段 — 承接访客兼容需求, 访客隔离已强制开启) ---------- */
let _bpLast = "";
const bpList = async () => {
    const j = await api("band_pin").catch(() => ({ pins: [] }));
    const html = (j.pins || []).map(p =>
        `<tr><td class="mono">${p.mac}</td><td>${p.band === "2g" ? "2.4GHz" : "5GHz"}</td><td><button class="ghost mini" onclick="bpDel('${p.mac}')">删除</button></td></tr>`).join("")
        || `<tr><td colspan="3" class="hint">暂无锁定终端</td></tr>`;
    if (html !== _bpLast) { _bpLast = html; H("bp-tb", html); }
};
window.bpAdd = async () => {
    const mac = $("bp-mac").value.trim();
    const j = await api("band_pin_add", `mac=${encodeURIComponent(mac)}&band=${$("bp-band").value}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已添加，应用变更后生效"); $("bp-mac").value = ""; bpList(); }
    else toast(eMsg(j.error), 1);
};
window.bpDel = async (mac) => {
    const j = await api("band_pin_del", `mac=${encodeURIComponent(mac)}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已删除，应用变更后生效"); bpList(); }
    else toast(eMsg(j.error), 1);
};
window.bpApply = async () => {
    const j = await api("wifi_restart").catch(e => ({ error: e.message }));
    if (j.ok) { toast("已应用，无线重启中"); setTimeout(() => PAGES.wifi.tick(), 4000); }
    else toast(eMsg(j.error), 1);
};
/* ---------- WiFi 分析仪 (仿 WiFi Analyzer: 信道图/信道评级/AP列表/时间图) ----------
 * 数据只来自 wifiscan 端点; 画布一次建骨架, 扫描后重绘; 时间图靠「自动」积累历史 */
const WA = { view: "ch", band: 2, aps: [], hist: [], colors: {}, timer: null, busy: false, own: [], ownCh: { 2: 0, 5: 0 } };
const CH2_LIST = Array.from({ length: 13 }, (_, i) => i + 1);
const CH5_LIST = [36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144, 149, 153, 157, 161, 165];
const waChOf = f => { f = +f; return f === 2484 ? 14 : f < 4000 ? Math.round((f - 2407) / 5) : Math.round((f - 5000) / 5); };
const waColor = mac => {
    if (!WA.colors[mac]) {
        let h = 0; for (const c of mac) h = (h * 33 + c.charCodeAt(0)) % 360;
        WA.colors[mac] = `hsl(${h},80%,62%)`;
    }
    return WA.colors[mac];
};
window.waView = v => {
    WA.view = v;
    document.querySelectorAll("#wa-tabs button").forEach(b => b.classList.toggle("act", b.dataset.v === v));
    waRender();
};
window.waBand = b => {
    WA.band = +b;
    document.querySelectorAll("#wa-band button").forEach(x => x.classList.toggle("act", +x.dataset.b === WA.band));
    waRender();
};
window.waScan = async silent => {
    if (WA.busy) return;
    WA.busy = true;
    if (!silent) T("wa-info", "扫描中…（约 10s）");
    try {
        const j = await api("wifiscan").catch(() => ({ aps: [] }));
        WA.aps = (j.aps || []).map(a => ({ ssid: a.ssid, mac: a.mac, sec: a.sec, fr: +a.freq, sig: +a.signal, ch: waChOf(a.freq), bw: +a.bw || 20, ctr: +a.ctr || 0 })).filter(a => a.ch > 0);
        WA.hist.push({ t: Date.now(), m: WA.aps.reduce((o, a) => (o[a.mac] = a.sig, o), {}) });
        if (WA.hist.length > 60) WA.hist.shift();
        waRender();
    } finally { WA.busy = false; }
};
window.waAuto = on => {
    if (WA.timer) { clearInterval(WA.timer); WA.timer = null; }
    if (on) WA.timer = setInterval(() => window.waScan(true), 15000);
};
window.waStop = () => {
    if (WA.timer) { clearInterval(WA.timer); WA.timer = null; }
    const cb = $("wa-auto"); if (cb) cb.checked = false;
};
window.addEventListener("resize", () => { if ($("wa-cv") && WA.aps.length) waRender(); });

const waBandAps = () => WA.band === 2 ? WA.aps.filter(a => a.fr < 4000) : WA.aps.filter(a => a.fr >= 4000);
function waCanvas() {
    const cv = $("wa-cv"), dpr = window.devicePixelRatio || 1;
    const w = cv.clientWidth || 640, h = cv.clientHeight || 340;
    cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
    const x = cv.getContext("2d");
    x.setTransform(dpr, 0, 0, dpr, 0, 0);
    x.clearRect(0, 0, w, h);
    return [x, w, h];
}
function waRender() {
    const cv = $("wa-cv"), list = $("wa-list");
    if (!cv) return;
    if (WA.view === "list") {
        cv.style.display = "none"; list.style.display = "";
        H("wa-list", waListTable());
        T("wa-info", waSummary());
        return;
    }
    cv.style.display = ""; list.style.display = "none";
    if (!WA.aps.length) {
        const [x, w, h] = waCanvas();
        x.fillStyle = "#7fa3c4"; x.font = "13px sans-serif"; x.textAlign = "center";
        x.fillText("尚无扫描数据 — 点击「扫描」", w / 2, h / 2);
        return;
    }
    if (WA.view === "ch") waDrawChGraph();
    else if (WA.view === "rate") waDrawRating();
    else waDrawTime();
    T("wa-info", waSummary());
}
function waSummary() {
    const n2 = WA.aps.filter(a => a.fr < 4000).length, n5 = WA.aps.length - n2;
    const stamp = WA.hist.length ? new Date(WA.hist[WA.hist.length - 1].t).toLocaleTimeString() : "--";
    return `${WA.aps.length} 个邻居 AP（2.4GHz ${n2} / 5GHz ${n5}）· ${WA.hist.length} 次扫描 · 最后 ${stamp}`;
}
/* 视图1: 信道图 — 每AP一个半透明矩形(±2信道宽, 顶边=信号), 填充/细边框/文字同色;
 * 索引映射向两侧各拓展2格, 最左/最右信道的矩形完整不截断; SSID 横排, 水平碰撞逐行上移 */
function waDrawChGraph() {
    const [x, W, H] = waCanvas();
    const chs = WA.band === 2 ? CH2_LIST : CH5_LIST;
    const aps = waBandAps().slice().sort((a, b) => a.sig - b.sig);   // 弱者先画, 强者居顶
    const padL = 36, padR = 10, padT = 16, padB = 24;
    const n = chs.length;
    const xOfI = i => padL + (i + 2) / (n + 3) * (W - padL - padR);  // i∈[-2, n+1]
    const yOf = s => padT + (-30 - s) / 70 * (H - padT - padB);      // -30..-100 dBm
    x.font = "10px sans-serif";
    for (let s = -30; s >= -100; s -= 10) {
        const y = yOf(s);
        x.strokeStyle = s === -100 ? "#3a5270" : "#1f3451";
        x.beginPath(); x.moveTo(padL, y); x.lineTo(W - padR, y); x.stroke();
        x.fillStyle = "#7fa3c4"; x.textAlign = "right"; x.fillText(String(s), padL - 5, y + 3);
    }
    x.textAlign = "center"; x.fillStyle = "#7fa3c4";
    const step = n > 16 ? 2 : 1;
    for (let i = 0; i < n; i += step) x.fillText(String(chs[i]), xOfI(i), H - 8);
    const base = H - padB;
    const cl = v => Math.max(-100, Math.min(-30, v));
    /* v3.19: CH5_LIST 相邻索引隔 4 信道(80MHz) — "信道像素"须除以索引步。
       v3.17 的 4 倍过宽 bug 即源于把索引步当信道(视觉回归实测抓出)。 */
    const chStep = (chs[1] - chs[0]) || 1;
    const chPx = ((xOfI(1) - xOfI(0)) || 20) / chStep;   // 单信道(20MHz)像素宽
    for (const a of aps) {
        let i = chs.indexOf(a.ch); if (i < 0) continue;
        const col = waColor(a.mac);
        let x0, x1;
        const bw = +a.bw || 20, k = Math.max(1, Math.round(bw / 20));
        if (WA.band === 5) {
            /* 5G: 精确频宽块。中心 = 主信道 + (ctr-主)/20 信道浮点偏移
               (ctr=42 等中心信道号不在 CH5_LIST, indexOf 必失败, 用线性内插) */
            const c = i + (+a.ctr ? ((+a.ctr) - a.ch) / chStep : 0);
            x0 = xOfI(c) - (k * chPx) / 2 - chPx * 0.25;
            x1 = xOfI(c) + (k * chPx) / 2 + chPx * 0.25;
        } else {
            /* 2.4G: 干扰重叠约定 — 20M ±2 信道, 40M ±4 */
            const half = bw >= 40 ? 4 : 2;
            x0 = xOfI(i - half); x1 = xOfI(i + half);
        }
        const yTop = yOf(cl(a.sig));
        const w = x1 - x0, h = base - yTop;
        x.globalAlpha = 0.30;
        x.fillStyle = col;
        x.fillRect(x0, yTop, w, h);
        x.globalAlpha = 1;
        x.lineWidth = 1;
        x.strokeStyle = col;
        x.strokeRect(x0 + 0.5, yTop + 0.5, w - 1, h - 1);
    }
    /* 标签: 邻居过多重叠不可避免 → 邻居只显色块; 本机 BSS 不被自家 apcli 扫描
     * 报告(实测 0 命中), 用已知信道合成绘制专属标记: 斜纹柱 + 加粗名 */
    const ownCh = WA.ownCh[WA.band];
    if (ownCh && chs.includes(ownCh)) {
        const i = chs.indexOf(ownCh);
        const ownSsid = WA.band === 2 ? (WA.own[0] || "网关") : (WA.own[1] || "网关");
        /* v3.17: 本机按真实带宽(BW2G/BW5G)。5G 绕主信道对称铺 k 信道;
           2.4G 维持重叠约定 ±2/±4 */
        const obw = (WA.ownBw && WA.ownBw[WA.band]) || (WA.band === 2 ? 20 : 80);
        let x0, x1;
        if (WA.band === 5) {
            const k = Math.max(1, Math.round(obw / 20));
            x0 = xOfI(i) - (k * chPx) / 2 - chPx * 0.25;
            x1 = xOfI(i) + (k * chPx) / 2 + chPx * 0.25;
        } else {
            const half = obw >= 40 ? 4 : 2;
            x0 = xOfI(i - half); x1 = xOfI(i + half);
        }
        const yTop = yOf(-35), h = base - yTop;
        x.save();
        x.beginPath(); x.rect(x0, yTop, x1 - x0, h); x.clip();
        x.strokeStyle = "#dbe9f6"; x.lineWidth = 1;
        for (let sx = x0 - h; sx < x1; sx += 7) {              // 斜纹填充
            x.beginPath(); x.moveTo(sx, base); x.lineTo(sx + h, yTop); x.stroke();
        }
        x.restore();
        x.strokeStyle = "#dbe9f6"; x.lineWidth = 2;            // 粗边框
        x.strokeRect(x0 + 1, yTop + 1, x1 - x0 - 2, h - 2);
        x.font = "bold 11px sans-serif";
        x.textAlign = "center";
        x.fillStyle = "#dbe9f6";
        x.fillText(ownSsid, Math.min(W - padR - 44, Math.max(padL + 44, (x0 + x1) / 2)), yTop - 6);
    } else {
        x.font = "bold 11px sans-serif";
        x.textAlign = "center";
    }
    /* 扫描结果里若万一出现本机 SSID(如桥接场景)也照常标注 */
    x.font = "bold 11px sans-serif";
    x.textAlign = "center";
    for (const a of aps) {
        if (!a.ssid || !WA.own.includes(a.ssid)) continue;
        const i = chs.indexOf(a.ch); if (i < 0) continue;
        const cx = (xOfI(i - 2) + xOfI(i + 2)) / 2;
        const ly = yOf(cl(a.sig)) - 8;
        x.fillStyle = waColor(a.mac);
        x.fillText(a.ssid, Math.min(W - padR - 40, Math.max(padL + 40, cx)), Math.max(padT + 10, ly));
    }
}
/* 视图2: 信道评级 — 与设备端 wifi_up 自动选道同口径的干扰评分, 星级+最佳 */
function waDrawRating() {
    const [x, W, H] = waCanvas();
    const is2 = WA.band === 2;
    const chs = is2 ? CH2_LIST : [36, 40, 44, 48, 149, 153, 157, 161];
    const aps = waBandAps();
    const ov = is2
        ? (c, d) => Math.abs(d - c) <= 4                                   // 2.4G 20/40M邻道重叠
        : (c, d) => (c < 100 ? (d >= 36 && d <= 48) : (d >= 149 && d <= 161)); // 5G 80M整组(最坏情况)
    const sc = {};
    for (const c of chs) {
        let s = 0;
        for (const a of aps) if (a.sig > -90 && ov(c, a.ch)) s += Math.pow(10, a.sig / 10);
        sc[c] = s;
    }
    const max = Math.max(...Object.values(sc), 1e-12);
    const rank = chs.slice().sort((a, b) => sc[a] - sc[b]);
    const bestSet = new Set(rank.slice(0, is2 ? 3 : 2));
    const padL = 42, padR = 72, padT = 12, padB = 16;
    const rowH = (H - padT - padB) / chs.length;
    const barMax = W - padL - padR - 34;
    x.font = "11px sans-serif";
    chs.forEach((c, i) => {
        const y = padT + i * rowH;
        const n = sc[c] / max;
        const rating = Math.max(1, Math.round(10 - 9 * n));
        const col = rating >= 8 ? "#2ecc8f" : rating >= 5 ? "#d9a441" : "#e06060";
        const stars = Math.round(rating / 2);
        x.fillStyle = "#0c1c2c"; x.textAlign = "right";
        x.fillText("ch" + c, padL - 6, y + rowH / 2 + 4);
        x.fillRect(padL, y + 3, barMax, rowH - 6);
        x.fillStyle = col;
        x.fillRect(padL, y + 3, Math.max(2, barMax * n), rowH - 6);
        x.textAlign = "left";
        x.fillText("★".repeat(stars) + "☆".repeat(5 - stars), padL + barMax + 6, y + rowH / 2 + 4);
        if (bestSet.has(c)) { x.fillText("最佳", padL + barMax + 60, y + rowH / 2 + 4); }
    });
}
/* 视图3: 时间图 — 信号随扫描次数变化, 需「自动」积累历史 */
function waDrawTime() {
    const [x, W, H] = waCanvas();
    const padL = 36, padR = 10, padT = 16, padB = 24;
    const yOf = s => padT + (-30 - s) / 70 * (H - padT - padB);
    x.font = "10px sans-serif";
    for (let s = -30; s >= -100; s -= 10) {
        const y = yOf(s);
        x.strokeStyle = s === -100 ? "#3a5270" : "#1f3451";
        x.beginPath(); x.moveTo(padL, y); x.lineTo(W - padR, y); x.stroke();
        x.fillStyle = "#7fa3c4"; x.textAlign = "right"; x.fillText(String(s), padL - 5, y + 3);
    }
    if (WA.hist.length < 2) {
        x.fillStyle = "#7fa3c4"; x.font = "13px sans-serif"; x.textAlign = "center";
        x.fillText("历史不足 — 勾选「自动」连续扫描积累曲线", W / 2, H / 2);
        return;
    }
    const t0 = WA.hist[0].t, t1 = WA.hist[WA.hist.length - 1].t;
    const xOf = t => padL + (t - t0) / Math.max(1, t1 - t0) * (W - padL - padR);
    const macs = waBandAps().slice().sort((a, b) => b.sig - a.sig).slice(0, 10).map(a => a.mac);
    for (const mac of macs) {
        x.strokeStyle = waColor(mac); x.lineWidth = 1.6;
        x.beginPath(); let started = false;
        for (const h of WA.hist) {
            if (!(mac in h.m)) continue;
            const px = xOf(h.t), py = yOf(Math.max(-100, Math.min(-30, h.m[mac])));
            started ? x.lineTo(px, py) : (x.moveTo(px, py), started = true);
        }
        x.stroke();
    }
    x.fillStyle = "#7fa3c4"; x.textAlign = "center"; x.font = "10px sans-serif";
    for (let i = 0; i < WA.hist.length; i += Math.ceil(WA.hist.length / 6))
        x.fillText(new Date(WA.hist[i].t).toLocaleTimeString(), xOf(WA.hist[i].t), H - 8);
}
/* 视图4: AP列表 — 按信号排序, 信道列 */
function waListTable() {
    const aps = waBandAps().slice().sort((a, b) => b.sig - a.sig);
    return aps.length
        ? `<table><thead><tr><th>SSID</th><th>MAC</th><th>频段</th><th>信道</th><th>信号</th><th>加密方式</th></tr></thead><tbody>` +
          aps.map(a => `<tr><td>${esc(a.ssid) || "(隐藏)"}</td><td class="mono">${a.mac}</td><td>${a.fr < 4000 ? "2.4GHz" : "5GHz"}</td><td class="mono">${a.ch}</td><td>${a.sig} dBm</td><td>${a.sec === "open" ? "开放" : esc(a.sec)}</td></tr>`).join("") + "</tbody></table>"
        : `<span class="hint">该频段未发现邻居 AP</span>`;
}

/* ================ 网络 ================ */
PAGES.net = {
    html: `<div>
      ${card("DHCP 地址池", `
        <div class="row3">
          <div class="frm"><label>起始 IP</label><input id="dh-r1" class="mono"></div>
          <div class="frm"><label>结束 IP</label><input id="dh-r2" class="mono"></div>
          <div class="frm"><label>租期</label><input id="dh-l" class="mono"></div>
        </div>
        <button class="pri" onclick="dhSave()">应用</button>`)}
      ${card("DMZ", `
        <div class="row3">
          <div class="frm"><label>启用</label><select id="dm-en"><option value="0">关闭</option><option value="1">开启</option></select></div>
          <div class="frm"><label>目标 IP</label><input id="dm-ip" class="mono"></div>
        </div>
        <button class="pri" onclick="dmSave()">应用</button>
        <span class="hint">开启后所有未匹配规则的入站流量转发到该终端</span>`)}
      ${card("端口转发", `<table><thead><tr><th>协议</th><th>外部端口</th><th>目标 IP</th><th>内部端口</th><th></th></tr></thead><tbody id="fw-tb"></tbody></table>
         <div class="row3" style="margin-top:8px">
           <div class="frm"><label>协议</label><select id="fw-p"><option>tcp</option><option>udp</option></select></div>
           <div class="frm"><label>外部端口</label><input id="fw-ep" class="mono" placeholder="8080"></div>
           <div class="frm"><label>目标 IP</label><input id="fw-ip" class="mono" placeholder="192.168.9.120"></div>
           <div class="frm"><label>内部端口</label><input id="fw-dp" class="mono" placeholder="80"></div>
         </div>
         <button class="pri" onclick="fwdAdd()">添加规则</button>`, 1)}
    </div>`,
    async tick() {
        const d = await api("dhcp");
        F("dh-r1", d.r1); F("dh-r2", d.r2); F("dh-l", d.lease);
        const f = await api("fw");
        F("dm-en", f.dmz.enabled); F("dm-ip", f.dmz.ip);
        H("fw-tb", (f.forwards || []).map(r => `<tr><td>${r.proto}</td><td class="mono">${r.eport}</td><td class="mono">${r.dip}</td><td class="mono">${r.dport}</td>
            <td><button class="mini ghost" onclick="fwdDel(0,'${r.proto}','${r.eport}')">删除</button></td></tr>`).join(""));
    }
};
window.dhSave = async () => {
    const j = await api("dhcp_set", `r1=${$("dh-r1").value}&r2=${$("dh-r2").value}&lease=${$("dh-l").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("已应用") : toast(eMsg(j.error), 1);
};
window.dmSave = async () => {
    const j = await api("dmz_set", `enabled=${$("dm-en").value}&ip=${$("dm-ip").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("已应用") : toast(eMsg(j.error), 1);
};
window.fwdAdd = async () => {
    const j = await api("fwd_add", `proto=${$("fw-p").value}&eport=${$("fw-ep").value}&dip=${$("fw-ip").value}&dport=${$("fw-dp").value}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已添加"); PAGES.net.tick(); } else toast(eMsg(j.error), 1);
};
window.fwdDel = async (i, p, e) => {
    const j = await api("fwd_del", `proto=${p}&eport=${e}`).catch(x => ({ error: x.message }));
    if (j.ok) { toast("已删除"); PAGES.net.tick(); } else toast(eMsg(j.error), 1);
};

/* ================ 聚合 ================ */
PAGES.agg = {
    html: `<div>
      ${card("聚合模式 " + tag("ag-on", "运行中", "已停用"), `
        <div class="frm"><label>模式选择</label><select id="ag-mode">
          <option value="weight">按权重分流</option>
          <option value="eth_prio">有线宽带优先</option>
          <option value="cell_prio">蜂窝优先</option>
          <option value="eth_only">仅有线宽带</option>
          <option value="cell_only">仅蜂窝</option>
        </select></div>
        <button class="pri" onclick="agMode()">应用模式</button>
        ${kv("转发引擎", "ag-eng") + kv("运行状态", "ag-wm")}
        <span class="hint">优先模式：备用线路在主用线路断开时自动接管，恢复后切回；单路模式不做切换；断线检测与 NAT 不受影响</span>`)}
      ${card("分流权重（蜂窝 / 有线宽带）", `
        <div class="slider-row"><input type="range" id="ag-w" min="5" max="95" step="5" oninput="T('ag-wv', this.value+'% / '+(100-this.value)+'%')"><b id="ag-wv">--</b></div>
        <button class="pri" onclick="agW()">应用权重</button>
        <span class="hint">新连接按此比例分流；已有连接保持原线路；仅在「按权重分流」模式下生效</span>`, 0, "card-aggw")}
      ${card("终端固定出口", `<table><thead><tr><th>MAC</th><th>出口线路</th><th></th></tr></thead><tbody id="pin-tb"></tbody></table>
         <div class="row3" style="margin-top:8px">
           <div class="frm"><label>MAC</label><input id="ap-mac" class="mono" placeholder="aa:bb:cc:dd:ee:ff"></div>
           <div class="frm"><label>出口线路</label><select id="ap-op"><option value="2">有线宽带</option><option value="1">蜂窝</option></select></div>
         </div><button class="pri" onclick="agPinAdd()">添加</button>
         <span class="hint">长时间保持连接的程序建议固定到单侧线路</span>`, 1)}
    </div>`,
    async tick() {
        const a = await api("agg");
        const mode = a.mode || "weight";
        F("ag-mode", mode); setTag("ag-on", a.enable === "1");   // G-10: 真实启用态, 删除恒真 tag
        // v3.28: 权重卡只在按权重分流模式显示
        const wc = document.getElementById("card-aggw");
        if (wc) wc.style.display = (mode === "weight") ? "" : "none";
        T("ag-eng", a.engine === "vendor" ? "硬件加速" : (a.engine ? "软件转发" : "--"));   // G-17: 引擎实现名不直出
        T("ag-wm", wanModeTxt(a.wanmode));   // G-13: wan_mode token 映射为运行状态
        const s = await api("status");
        if (/^\d+$/.test(s.agg.w1pct)) {
            const w1 = +s.agg.w1pct;
            F("ag-w", w1); T("ag-wv", `${w1}% / ${100 - w1}%`);
        }
        const pins = (a.pins_conf || "").split(";").filter(Boolean);
        H("pin-tb", pins.map(p => { const [m, op] = p.trim().split(/\s+/); return `<tr><td class="mono">${m}</td><td>${op === "2" ? "有线宽带" : "蜂窝"}</td><td><button class="mini ghost" onclick="agPin('${m}',0)">删除</button></td></tr>`; }).join(""));
    }
};
window.agMode = async () => {   // v3.28: 五模式选择(替代旧总开关)
    const m = $("ag-mode").value;
    const name = { weight: "按权重分流", eth_prio: "有线宽带优先", cell_prio: "蜂窝优先", eth_only: "仅有线宽带", cell_only: "仅蜂窝" }[m];
    const j = await api("agg_mode", `mode=${m}`).catch(e => ({ error: e.message }));
    j.ok ? toast(`已应用：${name}（约 5s 内生效）`) : toast(eMsg(j.error), 1);
    setTimeout(() => PAGES.agg.tick(), 6500);
};
window.agW = async () => {
    const j = await api("agg_weights", `w1=${$("ag-w").value}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已应用"); setTimeout(() => PAGES.agg.tick(), 900); }   // v3.26: 应用后回读同步滑块/比例
    else toast(eMsg(j.error), 1);
};
window.agPinAdd = async () => {
    const j = await api("agg_pin", `mac=${$("ap-mac").value}&op=${$("ap-op").value}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已添加"); PAGES.agg.tick(); } else toast(eMsg(j.error), 1);
};
window.agPin = async (m, op) => {
    const j = await api("agg_pin", `mac=${m}&op=${op}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已删除"); PAGES.agg.tick(); } else toast(eMsg(j.error), 1);
};

/* ================ 短信 ================ */
PAGES.sms = {
    html: `<div>
      ${card(`收件箱 <span class="tag on" id="sm-n">0 条</span>`, '<table><thead><tr><th>#</th><th>来自</th><th>内容</th></tr></thead><tbody id="sm-tb"></tbody></table>', 1)}
      ${card("发送短信", `
        <div class="row3">
          <div class="frm"><label>接收号码</label><input id="sm-to" class="mono" placeholder="+86 138xxxxxxxx"></div>
        </div>
        <div class="frm"><label>内容</label><textarea id="sm-txt" rows="3" style="width:100%;background:var(--input);border:1px solid var(--line);color:var(--tx);border-radius:7px;padding:8px;font-size:13px"></textarea></div>
        <button class="pri" onclick="smSend()">发送</button>
        <span class="hint">暂不支持中文短信（仅英文/数字）</span>`)}
    </div>`,
    async tick() {
        const j = await api("sms");
        T("sm-n", `${j.count || 0} 条`);
        H("sm-tb", (j.msgs || []).map(m => `<tr><td>${m.idx}</td><td class="mono">${esc(m.from)}</td><td>${esc(m.text)}</td></tr>`).join("") ||
            `<tr><td colspan="3" class="hint">暂无短信</td></tr>`);
    }
};
window.smSend = async () => {
    const j = await api("sms_send", `num=${encodeURIComponent($("sm-to").value.trim())}&text=${encodeURIComponent($("sm-txt").value)}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已发送"); $("sm-txt").value = ""; }
    else toast(eMsg(j.error), 1);
};

/* ================ 蜂窝 ================ */
PAGES.cellular = {
    html: `<div>
      ${card("服务小区", kv("运营商", "ce-op") + kv("频段 / 频点（ARFCN）/ PCI", "ce-cell", 1) + kv("RSRP / SINR / RSSI", "ce-sig"))}
      ${card("频段锁定 " + tag("tg-bl", "已开启", "已关闭"), `
        <div class="row3">
          <div class="frm"><label>启用</label><select id="cb-en"><option value="0">关闭</option><option value="1">开启</option></select></div>
          <div class="frm"><label>4G 频段</label><input id="cb-lte" class="mono" placeholder="3,8,38,39,40,41"></div>
          <div class="frm"><label>5G 频段</label><input id="cb-nr" class="mono" placeholder="28,41,79"></div>
        </div>
        <button class="pri" onclick="cbSave()">应用</button>
        <span class="hint">与小区锁定不能同时开启；示例：移动 n41,n79；联通/电信 n78,n41</span>`)}
      ${card("小区锁定 " + tag("tg-cl", "已开启", "已关闭"), `<table><thead><tr><th>#</th><th>制式</th><th>ARFCN</th><th>PCI</th><th></th></tr></thead><tbody id="ce-lock-tb"></tbody></table>
         <div class="row3" style="margin-top:8px">
           <div class="frm"><label>制式</label><select id="ce-act"><option value="nr">5G（NR）</option><option value="lte">4G（LTE）</option></select></div>
           <div class="frm"><label>频点（ARFCN 0-875000）</label><input id="ce-arf" class="mono" placeholder="504990（示例）"></div>
           <div class="frm"><label>PCI（0-2000）</label><input id="ce-pci" class="mono" placeholder="341（示例）"></div>
         </div>
         <button class="pri" onclick="ceAdd()">添加锁定小区</button>
         <button class="ghost" onclick="ceClear()">清空全部</button>`, 1)}
      ${card("网络制式", `
        <div class="row3">
          <div class="frm"><label>制式</label><select id="nm-mode"><option value="0">仅 4G</option><option value="1">4G 优先</option><option value="2">仅 5G</option><option value="3" selected>5G 优先（自动）</option></select></div>
          <div class="frm"><label>飞行模式</label><select id="nm-air"><option value="0">关闭</option><option value="1">开启（将断网）</option></select></div>
        </div>
        <button class="pri" onclick="nmSave()">应用制式</button>
        <button class="ghost" onclick="nmAir()">应用飞行模式</button>
        <button class="ghost" onclick="plmnScan()">扫描可用网络（10-60s）</button>
        <div id="plmn-out" class="hint" style="margin-top:8px"></div>`)}
      ${card("SIM 卡", kv("IMSI", "sim-imsi", 1) + kv("ICCID", "sim-iccid", 1) + kv("运营商", "sim-carrier") +
        kv("SIM 卡号码", "sim-phone", 1) + kv("IMEI", "sim-imei", 1) + `
        <div style="margin-top:10px"></div>
        <div class="row3">
          <div class="frm"><label>PIN 操作</label><select id="pin-act"><option value="disable">关闭 PIN 锁</option><option value="enable">开启 PIN 锁</option><option value="change">修改 PIN</option></select></div>
          <div class="frm"><label>PIN 码</label><input id="pin-cur" type="password" class="mono" maxlength="8"></div>
          <div class="frm"><label>新 PIN（修改时）</label><input id="pin-new" type="password" class="mono" maxlength="8"></div>
        </div>
        <button class="ghost" onclick="pinDo()">执行 PIN 操作</button>
        <span class="hint">连续输错 3 次将锁定 SIM 卡（需 PUK 解锁）</span>`)}
      ${card("流量统计", kv("下行（累计）", "tr-rx") + kv("上行（累计）", "tr-tx") + `
        <div class="row3" style="margin-top:8px">
          <div class="frm"><label>日限额（MB）</label><input id="tr-day" class="mono"></div>
          <div class="frm"><label>月限额（MB）</label><input id="tr-month" class="mono"></div>
        </div>
        <button class="ghost" onclick="trSave()">保存限额</button>
        <span class="hint">0 = 不限</span>`)}
      ${card('实时小区列表 (<b id="ce-n">0</b>)', '<table><thead><tr><th></th><th>频段</th><th>ARFCN</th><th>PCI</th><th>RSRP</th><th>SINR</th></tr></thead><tbody id="ce-tb"></tbody></table>', 1)}
    </div>`,
    async tick() {
        const j = await api("cellular");
        T("ce-op", `${j.operator.name} (${j.operator.plmn})`);
        T("ce-cell", `${fmtBand(j.serving.band)} · ARFCN ${j.serving.arfcn} · PCI ${j.serving.pci}`);   // G-03: 不再前置 B
        T("ce-sig", `${j.serving.rsrp} dBm · ${j.serving.sinr} dB · ${j.serving.rssi}`);
        setTag("tg-bl", j.bandlock.enable === "1");
        F("cb-en", j.bandlock.enable); F("cb-lte", j.bandlock.lte); F("cb-nr", j.bandlock.nr);
        setTag("tg-cl", j.celllock.enable === "1");
        H("ce-lock-tb", (j.celllock.entries || []).map(e => `<tr><td>${e.idx}</td><td>${e.act === "nr" ? "5G" : "4G"}</td><td class="mono">${e.arfcn}</td><td class="mono">${e.pci}</td>
            <td><button class="mini ghost" onclick="ceDel(${e.idx})">删除</button></td></tr>`).join(""));
        const rows = celRows(j);   // G-05: mipc=数组, 树=逗号串, 统一渲染
        T("ce-n", j.n != null ? j.n : rows.length);
        H("ce-tb", rows.map((c, i) => `<tr><td>${i === 0 ? `<span class="tag on">服务</span>` : ""}</td><td><b>${esc(fmtBand(c.band))}</b></td><td class="mono">${esc(c.arfcn)}</td><td class="mono">${esc(c.pci)}</td><td>${esc(c.rsrp)}</td><td>${esc(c.sinr)}</td></tr>`).join(""));
        const nm = await api("netmode");
        F("nm-mode", nm.mode); F("nm-air", nm.airplane || "0");
        const sim = await api("sim");
        T("sim-imsi", sim.imsi); T("sim-iccid", sim.iccid); T("sim-carrier", sim.carrier);
        T("sim-phone", sim.phone); T("sim-imei", sim.imei);
        const tr = await api("traffic").catch(() => null);
        if (tr) { T("tr-rx", fmtB(tr.rx)); T("tr-tx", fmtB(tr.tx)); F("tr-day", tr.day_limit_mb); F("tr-month", tr.month_limit_mb); }
    }
};
window.cbSave = async () => {
    const j = await api("cell_bandlock", `enable=${$("cb-en").value}&lte=${encodeURIComponent($("cb-lte").value)}&nr=${encodeURIComponent($("cb-nr").value)}`).catch(e => ({ error: e.message }));
    j.ok ? toast("已应用（模组重扫约 20-60 秒）") : toast(eMsg(j.error), 1);
};
window.ceAdd = async () => {
    const j = await api("cell_lock", `op=add&act=${$("ce-act").value}&arfcn=${$("ce-arf").value}&pci=${$("ce-pci").value}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已添加（模组重扫约 20-60 秒）"); PAGES.cellular.tick(); } else toast(eMsg(j.error), 1);
};
window.ceDel = async (i) => {
    const j = await api("cell_lock", `op=del&idx=${i}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已删除"); PAGES.cellular.tick(); } else toast(eMsg(j.error), 1);
};
window.ceClear = async () => {
    const j = await api("cell_lock", `op=clear`).catch(e => ({ error: e.message }));
    j.ok ? toast("已清空") : toast(eMsg(j.error), 1);
};
window.nmSave = async () => {
    const j = await api("netmode_set", `mode=${$("nm-mode").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("已应用") : toast(eMsg(j.error), 1);
};
window.plmnScan = async () => {
    const el = document.getElementById("plmn-out");
    if (el) el.textContent = "扫描中…（10-60s）";
    const j = await api("plmn_scan").catch(e => ({ error: e.message }));
    if (!el) return;
    if (j.error) { el.textContent = eMsg(j.error); return; }
    const rows = (j.networks || []).map(n =>
        `${n.name || n.mcc + n.mnc} [${n.rat}]${n.status === 1 ? " ←当前" : n.status === 4 ? " 可用" : ""}`);
    el.textContent = rows.length ? rows.join(" · ") : "无结果";   // v3.32(P2/L-3): innerHTML→textContent, 运营商名/伪基站注入不再成为 XSS 面
};

window.nmAir = async () => {
    if ($("nm-air").value === "1" && !confirm("开启飞行模式将断开蜂窝网络，确认执行？")) return;
    const j = await api("airplane_set", `on=${$("nm-air").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("已应用") : toast(eMsg(j.error), 1);
};
window.pinDo = async () => {
    if (!confirm("确认执行 PIN 操作？连续输错 3 次将锁定 SIM 卡")) return;
    const j = await api("pin_set", `action=${$("pin-act").value}&pin=${$("pin-cur").value}&new_pin=${$("pin-new").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("PIN 操作已应用") : toast(eMsg(j.error), 1);   // G-08: mipc 路径无 ubus 字段, 悬空冒号已删
};
window.trSave = async () => {
    const j = await api("traffic_limit", `day=${$("tr-day").value}&month=${$("tr-month").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("已保存") : toast(eMsg(j.error), 1);
};

/* ================ 插件页(可选) ================
 * /plugins.js 由设备侧可选提供(v3httpd 静态服务): 存在时其中代码调用
 * LG_plugin({id,title,page}) 动态注册页面并注入导航; 文件不存在则静默跳过。
 * 页面对象结构与内置页一致: {html, tick()}; 动作函数挂 window。 */
window.LG_plugin = (p) => {
    if (!p || !p.id || !p.page || PAGES[p.id]) return;
    PAGES[p.id] = p.page;
    const a = document.createElement("a");
    a.href = "#/" + p.id; a.dataset.p = p.id; a.textContent = p.title || p.id;
    const nav = document.getElementById("nav");
    nav.insertBefore(a, nav.querySelector('a[data-p="sys"]') || null);
    route();
};
(function () {
    const s = document.createElement("script");
    s.src = "/plugins.js?t=" + Date.now();
    s.onerror = () => {};   // 无插件文件: 静默
    document.head.appendChild(s);
})();
//

//
/* ================ 系统 ================ */
PAGES.sys = {
    html: `<div>
      ${card("系统", kv("运行", "sy-up") + kv("固件", "sy-fw") + kv("内核", "sy-kern"))}
      ${card("散热风扇", kv("风扇模式", "fan-mode") + kv("转速", "fan-rpm") + kv("SoC 温度", "fan-temp") +
        `<button class="ghost" id="fan-btn" onclick="fanTgl()">切换模式</button>`)}
      ${card("指示灯", kv("夜间模式", "led-night") +
        `<button class="ghost" id="led-btn" onclick="ledTgl()">切换</button>
         <span class="hint">夜间模式 = 除电源外全部熄灭</span>`)}
      ${card("时间同步（NTP）", kv("当前时间", "ntp-date") + kv("时区", "ntp-tz") + kv("NTP 服务器", "ntp-srv") + `
        <div class="row3" style="margin-top:8px">
          <div class="frm"><label>时区</label><select id="nt-tz"><option value="CST-8">北京时间（UTC+8）</option><option value="UTC">UTC</option></select></div>
          <div class="frm"><label>NTP 服务器</label><input id="nt-srv" class="mono"></div>
        </div>
        <button class="ghost" onclick="ntSync()">应用并立即同步</button>`)}
      ${card("管理密码", `
        <div class="row3">
          <div class="frm"><label>当前密码</label><input id="pw-old" type="password"></div>
          <div class="frm"><label>新密码（8-63 位）</label><input id="pw-new" type="password"></div>
          <div class="frm"><label>确认新密码</label><input id="pw-new2" type="password"></div>
        </div>
        <button class="pri" onclick="pwDo()">修改密码</button>
        <span class="hint">修改后需重新登录</span>`)}
      ${card("维护", `
        <button class="ghost" onclick="syReboot()">重启网关</button>
        <button class="ghost" onclick="logout()">退出登录</button>
        <span class="hint">重启约 3 分钟；全部服务自动恢复</span>`)}
      ${card("聚合日志", '<pre class="log" id="log-agg"></pre>', 1)}
      ${card("WiFi 日志", '<pre class="log" id="log-wifi"></pre>', 1)}
    </div>`,
    async tick() {
        const s = await api("sys").catch(() => ({ uptime: 0 }));
        T("sy-up", s.uptime ? Math.floor(s.uptime / 86400) + " 天 " + Math.floor(s.uptime % 86400 / 3600) + " 时" : "--");
        T("sy-fw", "v4 slot-A RP0103 (lg6151m)"); T("sy-kern", "5.15.134 MT6990");
        const fan = await api("fan");
        T("fan-mode", fan.mode === "silent" ? "静音" : "性能");
        T("fan-rpm", `${fan.rpm} rpm`);
        T("fan-temp", (fan.soc_temp > 0 ? (fan.soc_temp / 1000).toFixed(1) : "--") + " °C");
        T("fan-btn", fan.mode === "silent" ? "改为性能模式" : "改为静音模式");
        const led = await api("led");
        T("led-night", led.night === "1" ? "已开启" : "已关闭");
        T("led-btn", led.night === "1" ? "恢复正常指示" : "进入夜间模式");
        const ntp = await api("ntp");
        T("ntp-date", ntp.date); T("ntp-tz", TZ_TXT[ntp.tz] || ntp.tz || "--"); T("ntp-srv", ntp.ntp_server);
        F("nt-srv", ntp.ntp_server);
        const l = await api("logs");
        H("log-agg", esc((l.wan_agg || "").replace(/\\n/g, "\n")));
        H("log-wifi", esc((l.wifi || "").replace(/\\n/g, "\n")));
    }
};
window.fanTgl = async () => {
    const f = await api("fan");
    const j = await api("fan_set", `mode=${f.mode === "silent" ? "performance" : "silent"}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已应用"); PAGES.sys.tick(); } else toast(eMsg(j.error), 1);
};
window.ledTgl = async () => {
    const l = await api("led");
    const j = await api("led_set", `night=${l.night === "1" ? 0 : 1}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已应用（10s 内生效）"); PAGES.sys.tick(); } else toast(eMsg(j.error), 1);
};
window.ntSync = async () => {
    const j = await api("ntp_set", `tz=${$("nt-tz").value}&server=${encodeURIComponent($("nt-srv").value)}`).catch(e => ({ error: e.message }));
    j.ok ? toast("已应用，正在同步时间") : toast(eMsg(j.error), 1);
};
window.pwDo = async () => {
    if (!confirm("确认修改管理密码?")) return;
    if ($("pw-new").value !== $("pw-new2").value) { toast("两次输入的新密码不一致", 1); return; }
    const j = await api("pass_set", `old=${encodeURIComponent($("pw-old").value)}&new=${encodeURIComponent($("pw-new").value)}`).catch(e => ({ error: e.message }));
    if (j.ok) { setLogin(false); toast("已修改, 请重新登录"); }
    else toast(eMsg(j.error), 1);
};
window.syReboot = () => {
    modal("确认重启", `<p>确定要重启网关吗？约 3 分钟恢复。</p><div class="row3"><button class="pri" onclick="syRebootGo()">确认重启</button><button class="ghost" onclick="modalClose()">取消</button></div>`);
};
window.syRebootGo = async () => {
    modalClose();
    await api("sys_reboot").catch(() => {});
    toast("重启中…约 3 分钟");
};

/* ---------- router (骨架一次成型, 轮询仅 tick 更新槽位) ---------- */
function showLoginWall() {
    if (timer) clearInterval(timer);
    const main = document.getElementById("main");
    main.innerHTML = `<div style="display:flex;justify-content:center;align-items:center;min-height:70vh">
      <div class="card" style="width:min(92vw,360px)">
        <h3>LG6151M 网关登录</h3>
        <div class="frm"><label>管理密码</label><input type="password" id="wall-pass" autofocus></div>
        <button class="pri" id="wall-go" style="width:100%">登 录</button>
        <span class="hint">未登录不可查看任何信息 (与原厂行为一致)</span>
        <span class="hint">首次刷入的默认密码见 README (登录后请立即修改)</span>
      </div></div>`;
    const go = async () => {
        const j = await api("login", "pass=" + encodeURIComponent($("wall-pass").value)).catch(() => ({ error: "x" }));
        if (j.token) { TOKEN = j.token; sessionStorage.setItem("gw_token", TOKEN); setLogin(true); route();
            if (j.default) setTimeout(() => modal("安全警告", `<p><b>当前使用默认密码！</b></p><p>任何能接入本网络的人都可完全控制网关。请立即到 系统 → 管理密码 修改。</p><div class="row3"><button class="pri" onclick="modalClose();location.hash='#/sys'">去修改</button><button class="ghost" onclick="modalClose()">稍后</button></div>`), 400); }
        else { toast("密码错误", 1); $("wall-pass").value = ""; $("wall-pass").focus(); }
    };
    $("wall-go").onclick = go;
    $("wall-pass").addEventListener("keydown", e => { if (e.key === "Enter") go(); });
    setTimeout(() => $("wall-pass") && $("wall-pass").focus(), 50);
}
function route() {
    DIRTY.clear();   // 换页重建骨架, 脏标随之失效
    if (window.waStop) window.waStop();   // 分析仪自动扫描定时器不跨页存活
    if (!TOKEN) { showLoginWall(); return; }
    const h = (location.hash || "#/status").slice(2).split("?")[0];
    const p = PAGES[h] ? h : "status";
    document.querySelectorAll("#nav a").forEach(a => a.classList.toggle("act", a.dataset.p === p));
    const main = document.getElementById("main");
    main.innerHTML = PAGES[p].html;   // 仅切换页面时建骨架
    window.scrollTo(0, 0);            // 换页才回顶
    if (timer) clearInterval(timer);
    const run = () => PAGES[p].tick().catch(e => {
        if (e.message !== "need_login") main.innerHTML = `<div class="card">加载失败，请检查网络连接 <button class="ghost" onclick="route()">重试</button></div>`;   // G-40: 不直出英文异常
    });
    run();
    timer = setInterval(run, p === "status" ? 3000 : 8000);
}
window.route = route;
window.addEventListener("hashchange", route);
route();
