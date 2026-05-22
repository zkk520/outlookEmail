#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="/opt/outlookemail"
LOG_FILE="$DEPLOY_DIR/deploy.log"

mkdir -p "$DEPLOY_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
log_ok() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK]    $*"; }
log_err(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }

log "===== outlookemail 初始化部署 ====="
log "日志文件: $LOG_FILE"
cd "$DEPLOY_DIR"

# 1. 检查依赖
log "检查 docker 环境..."
command -v docker >/dev/null           || { log_err "未安装 docker，请先安装"; exit 1; }
docker compose version >/dev/null 2>&1 || { log_err "未安装 docker compose plugin"; exit 1; }
log_ok "docker 和 docker compose 就绪"

# 2. 检测 Docker 默认网桥网关
log "检测 Docker 默认网桥网关..."
DOCKER_GATEWAY=$(docker network inspect bridge \
  --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")
log_ok "Docker 网关: $DOCKER_GATEWAY  (容器代理将使用此 IP)"

# 3. 收集密钥（read -rsp 不回显，不写入日志）
echo ""
echo -n "登录密码（留空使用默认 admin123）: "
read -rsp "" LOGIN_PASSWORD
echo ""
LOGIN_PASSWORD="${LOGIN_PASSWORD:-admin123}"
SECRET_KEY=$(openssl rand -hex 32)
log_ok "SECRET_KEY 已自动生成（值已隐藏）"
log_ok "LOGIN_PASSWORD 已设置（值已隐藏）"

# 4. 写入 .env
cat > "$DEPLOY_DIR/.env" << EOF
SECRET_KEY=${SECRET_KEY}
LOGIN_PASSWORD=${LOGIN_PASSWORD}
PORT=5000
HOST=0.0.0.0
FLASK_ENV=production
DATABASE_PATH=data/outlook_accounts.db
EOF
log_ok ".env 已写入"

# 5. 生成服务器版 docker-compose.yml（含代理配置）
cat > "$DEPLOY_DIR/docker-compose.yml" << EOF
services:
  outlookemail:
    image: ghcr.io/zkk520/outlookemail:latest
    restart: unless-stopped
    ports:
      - "5000:5000"
    volumes:
      - ./data:/app/data
    env_file:
      - .env
    environment:
      HTTP_PROXY: "http://${DOCKER_GATEWAY}:7890"
      HTTPS_PROXY: "http://${DOCKER_GATEWAY}:7890"
      http_proxy: "http://${DOCKER_GATEWAY}:7890"
      https_proxy: "http://${DOCKER_GATEWAY}:7890"
      ALL_PROXY: "socks5://${DOCKER_GATEWAY}:7891"
      all_proxy: "socks5://${DOCKER_GATEWAY}:7891"
      NO_PROXY: "localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10"
      no_proxy: "localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10"
    mem_limit: 256m
    healthcheck:
      test:
        - CMD-SHELL
        - "env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy curl -sf http://localhost:5000/login"
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s
EOF
log_ok "docker-compose.yml 已生成（代理网关: ${DOCKER_GATEWAY}）"

# 6. 创建数据目录
mkdir -p "$DEPLOY_DIR/data"
log_ok "数据目录: $DEPLOY_DIR/data"

# 7. 拉取镜像（docker daemon 已配系统代理，无需 proxy 前缀）
log "拉取镜像 ghcr.io/assast/outlookemail:latest ..."
docker compose pull
log_ok "镜像拉取完成"

# 8. 启动容器
log "启动容器..."
docker compose up -d
log_ok "容器已启动"

# 9. 等待健康检查（最多 120s）
log "等待健康检查（最多 120s）..."
CONTAINER_ID=$(docker compose ps -q outlookemail 2>/dev/null | head -1)
for i in $(seq 1 12); do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER_ID" 2>/dev/null || echo "unknown")
  if [ "$STATUS" = "healthy" ]; then
    log_ok "健康检查通过 ✓"
    break
  fi
  if [ "$i" -eq 12 ]; then
    log_err "健康检查超时（当前状态: ${STATUS}）"
    log_err "查看日志: docker logs outlookemail"
    exit 1
  fi
  log "等待中... ($i/12) 当前状态: $STATUS"
  sleep 10
done

# 10. 完成
SERVER_IP=$(curl -sf --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null \
  || hostname -I | awk '{print $1}')
echo ""
log_ok "===== 部署完成 ====="
log_ok "访问地址: http://${SERVER_IP}:5000"
log_ok "查看状态: docker compose -f $DEPLOY_DIR/docker-compose.yml ps"
log_ok "查看日志: docker logs -f outlookemail"
log_ok "完整日志: $LOG_FILE"
