/* app.js v3.4 -- v3 gateway console SPA
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
function card(title, inner, wide) { return `<div class="card${wide ? " wide" : ""}"><h3>${title}</h3>${inner}</div>`; }
function kv(k, id, mono) {
    return `<div class="kv"><span>${k}</span><b id="${id}" class="${mono ? "mono" : ""}">--</b></div>`;
}
function tag(id, onTxt, offTxt) { return `<span class="tag" id="${id}" data-on="${onTxt}" data-off="${offTxt}">--</span>`; }
function setTag(id, ok) { const e = $(id); if (!e) return; const v = ok ? e.dataset.on : e.dataset.off; if (e.textContent !== v) { e.textContent = v; e.className = "tag " + (ok ? "on" : "off"); } }

/* ---------- pages ---------- */
const PAGES = {};
let timer = null;

/* ================ 状态 ================ */
PAGES.status = {
    html: `<div class="grid">
      ${card("系统", kv("运行时间", "up-up") + kv("负载", "up-load") + kv("内存", "up-mem") + kv("LAN", "up-lan"))}
      ${card("上行 · 5G " + tag("tg-5g", "在线", "离线"),
        kv("接口", "w5-if") + kv("IPv4", "w5-ip", 1) + kv("IPv6", "w5-v6", 1) +
        `<div class="rate"><span>↓ <b id="w5-rx">…</b></span><span>↑ <b id="w5-tx">…</b></span></div>`)}
      ${card("上行 · 有线宽带 " + tag("tg-home", "已连接", "未连接"),
        kv("IPv4", "ho-ip", 1) + kv("IPv6", "ho-v6", 1) +
        `<div class="rate"><span>↓ <b id="ho-rx">…</b></span><span>↑ <b id="ho-tx">…</b></span></div>`)}
      ${card("蜂窝载波 " + tag("tg-cel", "5G", "无服务"),
        kv("运营商", "cel-op") + kv("服务小区", "cel-cell", 1) + kv("信号", "cel-sig") + kv("载波聚合", "cel-n"))}
      ${card("聚合引擎 " + tag("tg-agg", "运行中", "未启用"),
        kv("内核引擎", "agg-eng") + kv("权重 5G/家宽", "agg-w") + kv("状态", "agg-st", 1))}
      ${card("WiFi " + tag("tg-wifi", "正常", "异常"),
        kv("2.4G", "wf-2g") + kv("5G", "wf-5g") + kv("hostapd", "wf-hap"))}
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
            setTag("tg-cel", cel.serving.rat !== "--");
            T("cel-op", `${cel.operator.name} (${cel.operator.plmn})`);
            T("cel-cell", `B${cel.serving.band} · ARFCN ${cel.serving.arfcn} · PCI ${cel.serving.pci}`);
            T("cel-sig", `RSRP ${cel.serving.rsrp} dBm · SINR ${cel.serving.sinr} dB`);
            T("cel-n", `${cel.cells.n} 个小区`);
        } else { setTag("tg-cel", false); T("cel-op", "--"); T("cel-cell", "--"); T("cel-sig", "--"); T("cel-n", "--"); }
        setTag("tg-agg", j.agg.on === "1");
        T("agg-eng", j.agg.on === "1" ? (j.agg.engine === "vendor" ? "quecadp (原厂)" : "iptables") : "已旁路");
        const wp = /^\d+$/.test(j.agg.w1pct) ? `${j.agg.w1pct}% / ${100 - j.agg.w1pct}%` : "—";
        T("agg-w", wp);
        T("agg-st", j.agg.state);
        const w = j.wifi || {};
        setTag("tg-wifi", (w.hostapd2g > 0) && (w.hostapd5g > 0));
        T("wf-2g", `${w.ssid2g || "?"} · ${w.secured ? "已加密" : "开放!"} · ch${w.ch2g}`);
        T("wf-5g", `${w.ssid5g || "?"} · ${w.secured ? "已加密" : "开放!"} · ch${w.ch5g}`);
        T("wf-hap", `${w.hostapd2g > 0 ? "2G✓" : "2G✕"} ${w.hostapd5g > 0 ? "5G✓" : "5G✕"}`);
        H("tp-body", Object.entries(j.temps || {}).map(([k, v]) => `<div class="kv"><span>${k}</span><b>${(v / 1000).toFixed(1)} °C</b></div>`).join(""));
        T("v6-ula", "fd42:9ac1:7e50::/64"); T("v6-mode", "SLAAC + NAT66");
        document.getElementById("hdr-sub").textContent = wp === "—" ? "v4 · 5G 聚合" : `v4 · 5G ${j.agg.w1pct}% / 家宽 ${100 - j.agg.w1pct}% · ${j.wanmode || ""}`;
        lastCounters = j.counters; lastTs = j.ts;
    }
};
let lastCounters = null, lastTs = 0;

/* ================ 设备 ================ */
PAGES.clients = {
    html: `<div id="cl-body">
      ${card(`DHCP 客户端 <span class="tag on" id="cl-n">0 台</span>`, '<table><thead><tr><th>主机名</th><th>IP</th><th>MAC</th><th>状态</th><th></th></tr></thead><tbody id="cl-tb"></tbody></table>', 1)}
      ${card("DHCP 静态租约", `<table><thead><tr><th>MAC</th><th>固定 IP</th><th>主机名</th><th></th></tr></thead><tbody id="ds-tb"></tbody></table>
         <div class="row3" style="margin-top:8px">
           <div class="frm"><label>MAC</label><input id="ds-mac" class="mono" placeholder="aa:bb:cc:dd:ee:ff"></div>
           <div class="frm"><label>IP</label><input id="ds-ip" class="mono" placeholder="192.168.9.150"></div>
           <div class="frm"><label>主机名</label><input id="ds-name" placeholder="mypc"></div>
         </div>
         <button class="pri" onclick="dsAdd()">添加绑定</button>`)}
      ${card("WiFi 已连接终端", '<table><thead><tr><th>接口</th><th>MAC</th><th>信号</th><th>↓流量</th><th>↑流量</th></tr></thead><tbody id="st-tb"></tbody></table>', 1)}
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
    if (j.ok) { toast(del ? "已解禁" : "已禁网"); PAGES.clients.tick(); } else toast("操作失败: " + (j.error || ""), 1);
};
window.dsAdd = async () => {
    const j = await api("dhcp_static_set", `op=add&mac=${$("ds-mac").value}&ip=${$("ds-ip").value}&name=${encodeURIComponent($("ds-name").value)}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("绑定已生效"); PAGES.clients.tick(); } else toast("失败: " + j.error, 1);
};
window.dsDel = async (m) => {
    const j = await api("dhcp_static_set", `op=del&mac=${m}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已删除"); PAGES.clients.tick(); } else toast("失败: " + j.error, 1);
};

/* ================ WiFi ================ */
PAGES.wifi = {
    html: `<div>
      ${card("无线设置", `
        <div class="frm"><label>WiFi 名称 (统一名称, 自动加频段后缀)</label><input id="wf-base"></div>
        <div class="frm"><label>密码 (8-63 字符)</label><input id="wf-pw" type="password" placeholder="留空=不修改"></div>
        <div class="frm"><label>加密</label><select id="wf-auth"><option>WPA2PSK</option><option>WPA2PSKWPA3PSK</option></select></div>
        <button class="pri" onclick="wfSave()">保存并应用</button>
        <span class="hint">应用会重启无线 (已连设备需重连)</span>`)}
      ${card("状态 " + tag("tg-wfst", "正常", "异常"),
        kv("2.4G", "wfs-2g") + kv("5G", "wfs-5g") + kv("加密", "wfs-sec") + kv("hostapd", "wfs-hap"))}
      ${card("高级设置", `
        <div class="row3">
          <div class="frm"><label>WiFi 名称</label><input id="wa-base"></div>
          <div class="frm"><label>2.4G 信道</label><select id="wa-ch2"><option value="0">自动 (启动时扫描选道)</option>${Array.from({length:13},(_,i)=>i+1).map(c=>`<option value="${c}">${c}</option>`).join("")}</select></div>
          <div class="frm"><label>2.4G 带宽 MHz</label><select id="wa-bw2"><option value="20">20</option><option value="40">40</option></select></div>
          <div class="frm"><label>5G 信道</label><select id="wa-ch5"><option value="0">自动 (启动时扫描选道)</option>${[36,40,44,48,149,153,157,161].map(c=>`<option value="${c}">${c}</option>`).join("")}</select></div>
          <div class="frm"><label>5G 带宽 MHz</label><select id="wa-bw5"><option value="20">20</option><option value="40">40</option><option value="80">80</option><option value="160">160 (含雷达信道, 启动需CAC约1分钟)</option></select></div>
          <div class="frm"><label>发射功率 %</label><select id="wa-pw">${[25,50,75,100].map(p => `<option value="${p}">${p}</option>`).join("")}</select></div>
          <div class="frm"><label>隐藏 SSID</label><select id="wa-hid"><option value="0">关闭</option><option value="1">隐藏</option></select></div>
          <div class="frm"><label>访客网络</label><select id="wa-guest"><option value="0">关闭</option><option value="1">开启 (SSID-guest, 隔离)</option></select></div>
          <div class="frm"><label>访客密码</label><input id="wa-gpass" type="password" placeholder="8-63位"></div>
          <div class="frm"><label>双频合一</label><select id="wa-inone"><option value="0">独立双频</option><option value="1">同名单频(漫游)</option></select></div>
        </div>
        <button class="pri" onclick="waSave()">应用高级设置</button>
        <span class="hint">应用会重启无线; 访客独立密码+客户端隔离; 信道选「自动」时每次启动多约10s扫描选道</span>`)}
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
            <button class="tb act" data-b="2" onclick="waBand(2)">2.4G</button>
            <button class="tb" data-b="5" onclick="waBand(5)">5G</button>
          </span>
        </div>
        <canvas id="wa-cv" style="width:100%;height:340px"></canvas>
        <div id="wa-list" style="display:none"></div>
        <span class="hint" id="wa-info">点击扫描 — 仿 WiFi Analyzer 多视图</span>`, 1)}
    </div>`,
    async tick() {
        const j = await api("wifi");
        F("wf-base", j.ssid_base);
        WA.own = [j.ssid2g, j.ssid5g];   // 信道图只标注本机 SSID
        WA.ownCh = { 2: +j.ch2g || 0, 5: +j.ch5g || 0 };   // 本机信道(apcli扫不到自家BSS, 合成绘制)
        WA.ownBw = { 2: 20, 5: 80 };   // v3.17: 本机带宽(adv0 就绪后更新) — 信道图按真实频宽画矩形
        setTag("tg-wfst", (j.hostapd2g > 0) && (j.hostapd5g > 0));
        T("wfs-2g", `${j.ssid2g} · ch${j.ch2g}`); T("wfs-5g", `${j.ssid5g} · ch${j.ch5g}`);
        const adv0 = await api("wifi_adv").catch(() => ({}));
        if (adv0.bw2g) WA.ownBw[2] = +adv0.bw2g;
        if (adv0.bw5g) WA.ownBw[5] = +adv0.bw5g;
        F("wa-base", adv0.ssid_base || "");
        T("wfs-sec", j.secured ? "WPA2-PSK (AES)" : "开放!");
        T("wfs-hap", `${j.hostapd2g > 0 ? "2G✓" : "2G✕"} ${j.hostapd5g > 0 ? "5G✓" : "5G✕"}`);
        H("wfs-tb", (j.stations || []).map(s => `<tr><td>${s.if}</td><td class="mono">${s.mac}</td><td>${s.signal} dBm</td><td>${fmtB(s.rx)}</td><td>${fmtB(s.tx)}</td></tr>`).join(""));
        const adv = await api("wifi_adv");
        F("wa-ch2", adv.ch2g); F("wa-bw2", adv.bw2g); F("wa-ch5", adv.ch5g);
        F("wa-bw5", adv.bw5g); F("wa-pw", adv.power); F("wa-hid", adv.hidden2g);
        F("wa-guest", adv.guest); F("wa-inone", adv.inone);
    }
};
window.wfSave = async () => {
    const body = `ssid_base=${encodeURIComponent($("wf-base").value)}&auth=${$("wf-auth").value}` +
        ($("wf-pw").value ? `&pass=${encodeURIComponent($("wf-pw").value)}` : "");
    const j = await api("wifi_set", body).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已应用, 无线重启中"); setTimeout(() => PAGES.wifi.tick(), 4000); }
    else toast("失败: " + (j.error || ""), 1);
};
window.waSave = async () => {
    const body = `ch2=${$("wa-ch2").value}&ch5=${$("wa-ch5").value}&bw2=${$("wa-bw2").value}&bw5=${$("wa-bw5").value}&power=${$("wa-pw").value}&hidden=${$("wa-hid").value}&guest=${$("wa-guest").value}&inone=${$("wa-inone").value}&ssid_base=${encodeURIComponent($("wa-base").value)}&pass=` +
        ($("wa-gpass").value ? `&guest_pass=${encodeURIComponent($("wa-gpass").value)}` : "");
    const j = await api("wifi_adv_set", body).catch(e => ({ error: e.message }));
    j.ok ? toast("已应用, 无线重启中") : toast("失败: " + j.error, 1);
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
    if (!silent) T("wa-info", "扫描中… (~10s)");
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
    return `${WA.aps.length} 个邻居 AP (2.4G ${n2} / 5G ${n5}) · ${WA.hist.length} 次扫描 · 最后 ${stamp}`;
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
        const ownSsid = WA.band === 2 ? (WA.own[0] || "本机") : (WA.own[1] || "本机");
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
        ? `<table><thead><tr><th>SSID</th><th>MAC</th><th>频段</th><th>信道</th><th>信号</th><th>加密</th></tr></thead><tbody>` +
          aps.map(a => `<tr><td>${esc(a.ssid) || "(隐藏)"}</td><td class="mono">${a.mac}</td><td>${a.fr < 4000 ? "2.4G" : "5G"}</td><td class="mono">${a.ch}</td><td>${a.sig} dBm</td><td>${a.sec}</td></tr>`).join("") + "</tbody></table>"
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
          <div class="frm"><label>开关</label><select id="dm-en"><option value="0">关闭</option><option value="1">开启</option></select></div>
          <div class="frm"><label>目标 IP</label><input id="dm-ip" class="mono"></div>
        </div>
        <button class="pri" onclick="dmSave()">应用</button>
        <span class="hint">开启后所有未映射入站端口转发到该主机</span>`)}
      ${card("端口映射", `<table><thead><tr><th>协议</th><th>外部端口</th><th>目标 IP</th><th>内部端口</th><th></th></tr></thead><tbody id="fw-tb"></tbody></table>
         <div class="row3" style="margin-top:8px">
           <div class="frm"><label>协议</label><select id="fw-p"><option>tcp</option><option>udp</option></select></div>
           <div class="frm"><label>外部端口</label><input id="fw-ep" class="mono" placeholder="8080"></div>
           <div class="frm"><label>目标 IP</label><input id="fw-ip" class="mono" placeholder="192.168.9.120"></div>
           <div class="frm"><label>内部端口</label><input id="fw-dp" class="mono" placeholder="80"></div>
         </div>
         <button class="pri" onclick="fwdAdd()">添加映射</button>`, 1)}
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
    j.ok ? toast("DHCP 已应用") : toast("失败: " + j.error, 1);
};
window.dmSave = async () => {
    const j = await api("dmz_set", `enabled=${$("dm-en").value}&ip=${$("dm-ip").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("DMZ 已应用") : toast("失败: " + j.error, 1);
};
window.fwdAdd = async () => {
    const j = await api("fwd_add", `proto=${$("fw-p").value}&eport=${$("fw-ep").value}&dip=${$("fw-ip").value}&dport=${$("fw-dp").value}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已添加"); PAGES.net.tick(); } else toast("失败: " + j.error, 1);
};
window.fwdDel = async (i, p, e) => {
    const j = await api("fwd_del", `proto=${p}&eport=${e}`).catch(x => ({ error: x.message }));
    if (j.ok) { toast("已删除"); PAGES.net.tick(); } else toast("失败: " + j.error, 1);
};

/* ================ 聚合 ================ */
PAGES.agg = {
    html: `<div>
      ${card("聚合模式 " + tag("ag-on", "已启用", "已旁路"), `
        <div class="frm"><label>总开关</label><select id="ag-en"><option value="1">启用（按权重分流 / 主备）</option><option value="0">旁路（全走当前主路，拆除分流）</option></select></div>
        <button class="pri" onclick="agEn()">应用开关</button>
        ${kv("引擎", "ag-eng") + kv("当前形态", "ag-wm")}
        <span class="hint">旁路 = 纯路由器单路上网（双活时走 5G，家宽主备时走家宽）；断线看门狗与 NAT 不受影响；重新启用即恢复分流</span>`)}
      ${card("聚合权重 (5G / 家宽)", `
        <div class="slider-row"><input type="range" id="ag-w" min="0" max="100" step="5" oninput="T('ag-wv', this.value+'% / '+(100-this.value)+'%')"><b id="ag-wv">--</b></div>
        <button class="pri" onclick="agW()">应用权重</button>
        <span class="hint">新连接按此比例分流; 已有连接保持粘性; 极端值(95~100/0~5)引擎按 95/5 实际执行</span>`)}
      ${card("引擎状态", kv("状态机", "ag-sm") + kv("最近", "ag-log", 1))}
      ${card("MAC 钉死表", `<table><thead><tr><th>MAC</th><th>钉到</th><th></th></tr></thead><tbody id="pin-tb"></tbody></table>
         <div class="row3" style="margin-top:8px">
           <div class="frm"><label>MAC</label><input id="ap-mac" class="mono" placeholder="aa:bb:cc:dd:ee:ff"></div>
           <div class="frm"><label>钉到</label><select id="ap-op"><option value="2">家宽 WAN2</option><option value="1">5G WAN1</option></select></div>
         </div><button class="pri" onclick="agPinAdd()">添加钉死</button>
         <span class="hint">会话绑定源 IP 的应用建议钉单侧</span>`, 1)}
    </div>`,
    async tick() {
        const a = await api("agg");
        F("ag-en", a.enable); setTag("ag-on", a.enable === "1");
        T("ag-eng", a.engine === "vendor" ? "quecadp 内核" : (a.engine ? "iptables 用户态" : "--"));
        T("ag-wm", a.wanmode || "--");
        const s = await api("status");
        if (/^\d+$/.test(s.agg.w1pct)) {
            const w1 = +s.agg.w1pct;
            F("ag-w", w1); T("ag-wv", `${w1}% / ${100 - w1}%`);
        }
        T("ag-sm", s.agg.wanmode);
        T("ag-log", a.log);
        const pins = (a.pins_conf || "").split(";").filter(Boolean);
        H("pin-tb", pins.map(p => { const [m, op] = p.trim().split(/\s+/); return `<tr><td class="mono">${m}</td><td>${op === "2" ? "家宽 WAN2" : "5G WAN1"}</td><td><button class="mini ghost" onclick="agPin('${m}',0)">删除</button></td></tr>`; }).join(""));
    }
};
window.agEn = async () => {
    const j = await api("agg_mode", `enable=${$("ag-en").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast($("ag-en").value === "1" ? "聚合已启用（约 5s 内恢复分流）" : "聚合已旁路（约 5s 内单路化）") : toast("失败: " + j.error, 1);
    setTimeout(() => PAGES.agg.tick(), 6500);
};
window.agW = async () => {
    const j = await api("agg_weights", `w1=${$("ag-w").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("权重已下发") : toast("失败: " + j.error, 1);
};
window.agPinAdd = async () => {
    const j = await api("agg_pin", `mac=${$("ap-mac").value}&op=${$("ap-op").value}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已钉死"); PAGES.agg.tick(); } else toast("失败: " + j.error, 1);
};
window.agPin = async (m, op) => {
    const j = await api("agg_pin", `mac=${m}&op=${op}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已删除"); PAGES.agg.tick(); } else toast("失败: " + j.error, 1);
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
        <span class="hint">MIPC 直发通道 (ql_sms_send_msg, 同步确认); 中文请用英文或后续 UCS2 支持</span>`)}
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
    if (j.ok) { toast("已发送 (modem 确认)"); $("sm-txt").value = ""; }
    else toast("发送失败: " + (j.error || "?"), 1);
};

/* ================ 蜂窝 ================ */
PAGES.cellular = {
    html: `<div>
      ${card("服务小区", kv("运营商", "ce-op") + kv("频段/频点/PCI", "ce-cell", 1) + kv("RSRP / SINR / RSSI", "ce-sig"))}
      ${card("锁频段 " + tag("tg-bl", "已启用", "未启用"), `
        <div class="row3">
          <div class="frm"><label>开关</label><select id="cb-en"><option value="0">关闭</option><option value="1">开启</option></select></div>
          <div class="frm"><label>4G 频段</label><input id="cb-lte" class="mono" placeholder="3,8,38,39,40,41"></div>
          <div class="frm"><label>5G 频段</label><input id="cb-nr" class="mono" placeholder="28,41,79"></div>
        </div>
        <button class="pri" onclick="cbSave()">应用锁频段</button>
        <span class="hint">与锁小区互斥; 移动5G=n41,n79,n28 · 联通/电信=n78,n41</span>`)}
      ${card("锁小区 " + tag("tg-cl", "已启用", "未启用"), `<table><thead><tr><th>#</th><th>制式</th><th>频点 ARFCN</th><th>PCI</th><th></th></tr></thead><tbody id="ce-lock-tb"></tbody></table>
         <div class="row3" style="margin-top:8px">
           <div class="frm"><label>制式</label><select id="ce-act"><option value="nr">5G NR</option><option value="lte">4G LTE</option></select></div>
           <div class="frm"><label>频点 (0-875000)</label><input id="ce-arf" class="mono" placeholder="504990"></div>
           <div class="frm"><label>PCI (0-2000)</label><input id="ce-pci" class="mono" placeholder="341"></div>
         </div>
         <button class="pri" onclick="ceAdd()">添加锁定小区</button>
         <button class="ghost" onclick="ceClear()">清空全部</button>`, 1)}
      ${card("网络制式", `
        <div class="row3">
          <div class="frm"><label>制式</label><select id="nm-mode"><option value="0">仅 4G</option><option value="1">4G 优先</option><option value="2">仅 5G</option><option value="3" selected>5G 优先(自动)</option></select></div>
          <div class="frm"><label>飞行模式</label><select id="nm-air"><option value="0">关闭</option><option value="1">开启(断网!)</option></select></div>
        </div>
        <button class="pri" onclick="nmSave()">应用制式</button>
        <button class="ghost" onclick="nmAir()">应用飞行模式</button>
        <button class="ghost" onclick="plmnScan()">扫描可用网络 (10-60s)</button>
        <div id="plmn-out" class="hint" style="margin-top:8px"></div>`)}
      ${card("SIM 卡", kv("IMSI", "sim-imsi", 1) + kv("ICCID", "sim-iccid", 1) + kv("运营商", "sim-carrier") +
        kv("本机号码", "sim-phone", 1) + kv("IMEI", "sim-imei", 1) + `
        <div style="margin-top:10px"></div>
        <div class="row3">
          <div class="frm"><label>PIN 操作</label><select id="pin-act"><option value="disable">关闭 PIN 锁</option><option value="enable">开启 PIN 锁</option><option value="change">修改 PIN</option></select></div>
          <div class="frm"><label>PIN 码</label><input id="pin-cur" type="password" class="mono" maxlength="8"></div>
          <div class="frm"><label>新 PIN (改锁时)</label><input id="pin-new" type="password" class="mono" maxlength="8"></div>
        </div>
        <button class="ghost" onclick="pinDo()">执行 PIN 操作</button>
        <span class="hint">连续错 3 次将锁卡需 PUK; 谨慎操作</span>`)}
      ${card("流量统计", kv("下行累计", "tr-rx") + kv("上行累计", "tr-tx") + `
        <div class="row3" style="margin-top:8px">
          <div class="frm"><label>日限额 MB (0=不限)</label><input id="tr-day" class="mono"></div>
          <div class="frm"><label>月限额 MB (0=不限)</label><input id="tr-month" class="mono"></div>
        </div>
        <button class="ghost" onclick="trSave()">保存限额</button>`)}
      ${card('实时小区列表 (<b id="ce-n">0</b>)', '<table><thead><tr><th></th><th>频段</th><th>ARFCN</th><th>PCI</th><th>RSRP</th><th>SINR</th></tr></thead><tbody id="ce-tb"></tbody></table>', 1)}
    </div>`,
    async tick() {
        const j = await api("cellular");
        T("ce-op", `${j.operator.name} (${j.operator.plmn})`);
        T("ce-cell", `B${j.serving.band} · ${j.serving.arfcn} · PCI ${j.serving.pci}`);
        T("ce-sig", `${j.serving.rsrp} dBm · ${j.serving.sinr} dB · ${j.serving.rssi}`);
        setTag("tg-bl", j.bandlock.enable === "1");
        F("cb-en", j.bandlock.enable); F("cb-lte", j.bandlock.lte); F("cb-nr", j.bandlock.nr);
        setTag("tg-cl", j.celllock.enable === "1");
        H("ce-lock-tb", (j.celllock.entries || []).map(e => `<tr><td>${e.idx}</td><td>${e.act === "nr" ? "5G" : "4G"}</td><td class="mono">${e.arfcn}</td><td class="mono">${e.pci}</td>
            <td><button class="mini ghost" onclick="ceDel(${e.idx})">删除</button></td></tr>`).join(""));
        const bands = (j.cells.band || "").split(",").filter(Boolean);
        T("ce-n", j.cells.n || 0);
        const arf = (j.cells.arfcn || "").split(","), pci = (j.cells.pci || "").split(",");
        const rs = (j.cells.rsrp || "").split(","), si = (j.cells.sinr || "").split(",");
        H("ce-tb", bands.map((b, i) => `<tr><td>${i === 0 ? `<span class="tag on">服务</span>` : ""}</td><td><b>${esc(b)}</b></td><td class="mono">${esc(arf[i])}</td><td class="mono">${esc(pci[i])}</td><td>${esc(rs[i])}</td><td>${esc(si[i])}</td></tr>`).join(""));
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
    j.ok ? toast("锁频段已应用") : toast("失败: " + j.error, 1);
};
window.ceAdd = async () => {
    const j = await api("cell_lock", `op=add&act=${$("ce-act").value}&arfcn=${$("ce-arf").value}&pci=${$("ce-pci").value}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已添加"); PAGES.cellular.tick(); } else toast("失败: " + j.error, 1);
};
window.ceDel = async (i) => {
    const j = await api("cell_lock", `op=del&idx=${i}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已删除"); PAGES.cellular.tick(); } else toast("失败: " + j.error, 1);
};
window.ceClear = async () => {
    const j = await api("cell_lock", `op=clear`).catch(e => ({ error: e.message }));
    j.ok ? toast("已清空") : toast("失败: " + j.error, 1);
};
window.nmSave = async () => {
    const j = await api("netmode_set", `mode=${$("nm-mode").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("制式已应用") : toast("失败: " + j.error, 1);
};
window.plmnScan = async () => {
    const el = document.getElementById("plmn-out");
    if (el) el.textContent = "扫描中... (10-60s)";
    const j = await api("plmn_scan").catch(e => ({ error: e.message }));
    if (!el) return;
    if (j.error) { el.textContent = "扫描失败: " + j.error; return; }
    const rows = (j.networks || []).map(n =>
        `${n.name || n.mcc + n.mnc} [${n.rat}]${n.status === 1 ? " ←当前" : n.status === 4 ? " 可用" : ""}`);
    el.innerHTML = rows.length ? rows.join(" · ") : "无结果";
};

window.nmAir = async () => {
    if ($("nm-air").value === "1" && !confirm("开启飞行模式将断开蜂窝网络, 确认?")) return;
    const j = await api("airplane_set", `on=${$("nm-air").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("飞行模式已应用") : toast("失败: " + j.error, 1);
};
window.pinDo = async () => {
    if (!confirm("确认执行 PIN 操作? 错误三次将锁卡!")) return;
    const j = await api("pin_set", `action=${$("pin-act").value}&pin=${$("pin-cur").value}&new_pin=${$("pin-new").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("PIN 操作已下发: " + (j.ubus || "")) : toast("失败: " + j.error, 1);
};
window.trSave = async () => {
    const j = await api("traffic_limit", `day=${$("tr-day").value}&month=${$("tr-month").value}`).catch(e => ({ error: e.message }));
    j.ok ? toast("限额已保存") : toast("失败: " + j.error, 1);
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
      ${card("散热风扇", kv("模式", "fan-mode") + kv("转速", "fan-rpm") + kv("SoC 温度", "fan-temp") +
        `<button class="ghost" id="fan-btn" onclick="fanTgl()">切换模式</button>`)}
      ${card("指示灯", kv("夜间模式", "led-night") +
        `<button class="ghost" id="led-btn" onclick="ledTgl()">切换</button>
         <span class="hint">夜间模式 = 除电源外全灭</span>`)}
      ${card("时间与 NTP", kv("当前时间", "ntp-date") + kv("时区", "ntp-tz") + kv("NTP 服务器", "ntp-srv") + `
        <div class="row3" style="margin-top:8px">
          <div class="frm"><label>时区</label><select id="nt-tz"><option value="CST-8">CST-8 (北京)</option><option value="UTC">UTC</option></select></div>
          <div class="frm"><label>NTP 服务器</label><input id="nt-srv" class="mono"></div>
        </div>
        <button class="ghost" onclick="ntSync()">保存并立即对时</button>`)}
      ${card("管理密码", `
        <div class="row3">
          <div class="frm"><label>当前密码</label><input id="pw-old" type="password"></div>
          <div class="frm"><label>新密码 (8-63位)</label><input id="pw-new" type="password"></div>
          <div class="frm"><label>确认新密码</label><input id="pw-new2" type="password"></div>
        </div>
        <button class="pri" onclick="pwDo()">修改密码</button>
        <span class="hint">修改后需重新登录</span>`)}
      ${card("维护动作", `
        <button class="ghost" onclick="syReboot()">重启网关</button>
        <button class="ghost" onclick="logout()">退出登录</button>
        <span class="hint">重启约 3 分钟; 全部服务自动恢复</span>`)}
      ${card("wan_agg 日志", '<pre class="log" id="log-agg"></pre>', 1)}
      ${card("wifi 日志", '<pre class="log" id="log-wifi"></pre>', 1)}
    </div>`,
    async tick() {
        const s = await api("sys").catch(() => ({ uptime: 0 }));
        T("sy-up", s.uptime ? Math.floor(s.uptime / 86400) + " 天 " + Math.floor(s.uptime % 86400 / 3600) + " 时" : "--");
        T("sy-fw", "v4 slot-A RP0103 (lg6151m)"); T("sy-kern", "5.15.134 MT6990");
        const fan = await api("fan");
        T("fan-mode", fan.mode === "silent" ? "静音 (+6°C)" : "性能");
        T("fan-rpm", `${fan.rpm} rpm`);
        T("fan-temp", (fan.soc_temp > 0 ? (fan.soc_temp / 1000).toFixed(1) : "--") + " °C");
        T("fan-btn", fan.mode === "silent" ? "切性能模式" : "切静音模式");
        const led = await api("led");
        T("led-night", led.night === "1" ? "已开启(全灭)" : "关闭");
        T("led-btn", led.night === "1" ? "恢复正常指示" : "进入夜间模式");
        const ntp = await api("ntp");
        T("ntp-date", ntp.date); T("ntp-tz", ntp.tz); T("ntp-srv", ntp.ntp_server);
        F("nt-srv", ntp.ntp_server);
        const l = await api("logs");
        H("log-agg", esc((l.wan_agg || "").replace(/\\n/g, "\n")));
        H("log-wifi", esc((l.wifi || "").replace(/\\n/g, "\n")));
    }
};
window.fanTgl = async () => {
    const f = await api("fan");
    const j = await api("fan_set", `mode=${f.mode === "silent" ? "performance" : "silent"}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已切换"); PAGES.sys.tick(); } else toast("失败: " + j.error, 1);
};
window.ledTgl = async () => {
    const l = await api("led");
    const j = await api("led_set", `night=${l.night === "1" ? 0 : 1}`).catch(e => ({ error: e.message }));
    if (j.ok) { toast("已切换 (10s 内生效)"); PAGES.sys.tick(); } else toast("失败: " + j.error, 1);
};
window.ntSync = async () => {
    const j = await api("ntp_set", `tz=${$("nt-tz").value}&server=${encodeURIComponent($("nt-srv").value)}`).catch(e => ({ error: e.message }));
    j.ok ? toast("已保存并触发对时") : toast("失败: " + j.error, 1);
};
window.pwDo = async () => {
    if (!confirm("确认修改管理密码?")) return;
    if ($("pw-new").value !== $("pw-new2").value) { toast("两次输入的新密码不一致", 1); return; }
    const j = await api("pass_set", `old=${encodeURIComponent($("pw-old").value)}&new=${encodeURIComponent($("pw-new").value)}`).catch(e => ({ error: e.message }));
    if (j.ok) { setLogin(false); toast("已修改, 请重新登录"); }
    else toast(j.error === "bad_old" ? "当前密码错误" : "失败: " + j.error, 1);
};
window.syReboot = () => {
    modal("确认重启", `<p>确定要重启网关吗? 约 3 分钟恢复。</p><div class="row3"><button class="pri" onclick="syRebootGo()">确认重启</button><button class="ghost" onclick="modalClose()">取消</button></div>`);
};
window.syRebootGo = async () => {
    modalClose();
    await api("sys_reboot").catch(() => {});
    toast("重启中… 约 3 分钟");
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
        <span class="hint">首次刷入的默认口令见 README (登录后请立即修改)</span>
      </div></div>`;
    const go = async () => {
        const j = await api("login", "pass=" + encodeURIComponent($("wall-pass").value)).catch(() => ({ error: "x" }));
        if (j.token) { TOKEN = j.token; sessionStorage.setItem("gw_token", TOKEN); setLogin(true); route();
            if (j.default) setTimeout(() => modal("安全警告", `<p><b>当前使用默认口令!</b></p><p>任何能接入本网络的人都可完全控制网关。请立即到 系统 → 管理密码 修改。</p><div class="row3"><button class="pri" onclick="modalClose();location.hash='#/sys'">去修改</button><button class="ghost" onclick="modalClose()">稍后</button></div>`), 400); }
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
        if (e.message !== "need_login") main.innerHTML = `<div class="card">加载失败: ${esc(e.message)} <button class="ghost" onclick="route()">重试</button></div>`;
    });
    run();
    timer = setInterval(run, p === "status" ? 3000 : 8000);
}
window.route = route;
window.addEventListener("hashchange", route);
route();
