#!/bin/sh
# webs_revive.sh v1.2 -- 原厂 GUI/FH-App API 后端复活 (v3.1 起入 rc19 开机常驻)
# 链路: cfg_tool(建16MB shm key=0x7539) -> cfgmgr(重启挂段) -> webs(fastcgi:8840)
#       -> nginx(192.168.9.1:8080, SPA=/www/html, API=/fh_api/*)
# v1.1: WEBS_REVIVE_KEEP_CFGMGR=1 时, 若 cfgmgr 已在跑(rc_netfh 拉起)则复用,
#       不再 killall 重启(避免闪断 ubus cfgmgr 消费者)。
#       v3httpd v2.2 把 /fh_api/* 与 /api/tmp/* 隧道到本栈 8080 → 烽火终端App 走 80 口。
# 风险: 勿用 sysmgr 全量拉起(会启动原厂网络栈与自建层争抢 WAN/路由)。
set -e
export LD_LIBRARY_PATH=/lib:/fhrom/lib
if ! awk 'NR>1 && $3==16777216' /proc/sysvipc/shm | grep -q .; then
    /fhrom/bin/cfg_tool /fhrom/fhconf/param.pdt.enc
fi
if ! netstat -tln 2>/dev/null | grep -q :8840; then
    if [ -n "$WEBS_REVIVE_KEEP_CFGMGR" ] && pgrep -x cfgmgr >/dev/null 2>&1; then
        echo "cfgmgr alive (rc_netfh) -- reuse, no restart"
    else
        killall cfgmgr 2>/dev/null || true; sleep 1
        /fhrom/bin/cfgmgr -L 4 >/tmp/cfgmgr.out 2>&1 &
        sleep 2
    fi
    mkdir -p /var/web_temp/logs
    /fhrom/bin/spawn-fcgi -a 127.0.0.1 -p 8840 -f /fhrom/bin/webs
fi

# /var 重启即空 — 自足生成 nginx 配置
if [ ! -s /var/web_temp_nginx.conf ]; then
    cat > /var/web_temp_nginx.conf <<'NGINXCONF'
worker_processes 1;
error_log /tmp/nginx_web.err;
pid /tmp/nginx_web.pid;
events { worker_connections 64; }
http {
    include /fhrom/fhconf/webconf/mime.types;
    default_type application/octet-stream;
    access_log off;
    server {
        listen 192.168.9.1:8080;
        server_name localhost;
        set $login_user 0;
        root /www/html;
        index login.html;
        location = /fh_app/api {
            include /fhrom/fhconf/webconf/fastcgi.conf;
            fastcgi_pass 127.0.0.1:8840;
            limit_except POST { deny all; }
        }
        location ~ ^/(api/tmp/FHNCAPIS|api/tmp/FHTOOLAPIS)$ {
            include /fhrom/fhconf/webconf/fastcgi.conf;
            fastcgi_param REDIRECT_FROM_NGINX "true";
            fastcgi_param METHOD_FROM_NGINX "web_do_cpe_manage";
            fastcgi_pass 127.0.0.1:8840;
        }
        location ^~ /fh_api/sign/ {
            include /fhrom/fhconf/webconf/fastcgi.conf;
            fastcgi_pass 127.0.0.1:8840;
        }
        location ^~ /fh_api/tmp/ {
            include /fhrom/fhconf/webconf/fastcgi.conf;
            fastcgi_pass 127.0.0.1:8840;
        }
        location ^~ /fh_api/long/ {
            include /fhrom/fhconf/webconf/fastcgi.conf;
            fastcgi_pass 127.0.0.1:8840;
        }
        location / { try_files $uri $uri/ /login.html; }
    }
}
NGINXCONF
fi
if ! netstat -tln 2>/dev/null | grep -q "192.168.9.1:8080"; then
    killall nginx 2>/dev/null || true; sleep 1
    /fhrom/bin/nginx -c /var/web_temp_nginx.conf
fi
# v1.2: iotagtd — 烽火终端App 的本地 NDMP 服务(:18998 明文/:18996 TLS) + 云连接。
# 链 liblocal_agent.so。LAN 侧探测/控制靠它; App 首选 18998。
# 它绑 0.0.0.0 -> 补 iptables 只放行 br-lan 侧 (WAN侧不可达)。
if ! pgrep -x iotagtd >/dev/null 2>&1; then
    /fhrom/bin/iotagtd >/tmp/iotagtd.log 2>&1 &
    sleep 2
fi
iptables -C INPUT -i eth0 -p tcp --dport 18996:18998 -j DROP 2>/dev/null || \
    iptables -I INPUT -i eth0 -p tcp --dport 18996:18998 -j DROP
netstat -tln 2>/dev/null | grep -E ":8840|:8080|:1899"
echo "stock FH-App API: :8080 + NDMP :18996/:18998 (v3httpd :80 tunnels /fh_api/* + /api/tmp/*)"
