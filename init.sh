#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="/opt/outlookemail"
LOG_FILE="$DEPLOY_DIR/deploy.log"
CONTAINER_NAME="outlookemail-outlookemail-1"

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

# 2. 收集密钥（read -rsp 不回显，不写入日志）
echo ""
echo -n "登录密码（留空使用默认 admin123）: "
read -rsp "" LOGIN_PASSWORD
echo ""
LOGIN_PASSWORD="${LOGIN_PASSWORD:-admin123}"
SECRET_KEY=$(openssl rand -hex 32)
log_ok "SECRET_KEY 已自动生成（值已隐藏）"
log_ok "LOGIN_PASSWORD 已设置（值已隐藏）"

# 3. 写入 .env
cat > "$DEPLOY_DIR/.env" << EOF
SECRET_KEY=${SECRET_KEY}
LOGIN_PASSWORD=${LOGIN_PASSWORD}
PORT=5000
HOST=0.0.0.0
FLASK_ENV=production
DATABASE_PATH=data/outlook_accounts.db
EOF
log_ok ".env 已写入"

# 4. 生成不含代理的初始 docker-compose.yml（代理地址需容器启动后才能确定）
cat > "$DEPLOY_DIR/docker-compose.yml" << 'EOF'
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
log_ok "docker-compose.yml 初始版已生成"

# 5. 创建数据目录
mkdir -p "$DEPLOY_DIR/data"
log_ok "数据目录: $DEPLOY_DIR/data"

# 6. 拉取镜像（docker daemon 已配系统代理，无需 proxy 前缀）
log "拉取镜像 ghcr.io/zkk520/outlookemail:latest ..."
docker compose pull
log_ok "镜像拉取完成"

# 7. 首次启动容器（无代理配置），用于检测实际网关 IP
log "首次启动容器（用于检测网络网关）..."
docker compose up -d
log_ok "容器已启动"

# 8. 检测容器实际所在网络的网关 IP
log "检测容器实际网关..."
sleep 2  # 等待网络接口初始化
DOCKER_GATEWAY=$(docker inspect -f \
  '{{range $n,$v := .NetworkSettings.Networks}}{{$v.Gateway}}{{end}}' \
  "$CONTAINER_NAME" 2>/dev/null || echo "")

if [ -z "$DOCKER_GATEWAY" ]; then
  log_err "无法检测到容器网关，请手动检查容器网络配置"
  exit 1
fi
log_ok "容器实际网关: $DOCKER_GATEWAY"

# 9. 重新生成含代理配置的 docker-compose.yml
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
log_ok "docker-compose.yml 已更新（代理网关: ${DOCKER_GATEWAY}）"

# 10. 重启容器使代理配置生效
log "重启容器使代理配置生效..."
docker compose up -d
log_ok "容器已重启"

# 11. 等待健康检查（最多 120s）
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
    log_err "查看日志: docker logs $CONTAINER_NAME"
    exit 1
  fi
  log "等待中... ($i/12) 当前状态: $STATUS"
  sleep 10
done

# 12. 完成
SERVER_IP=$(curl -sf --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null \
  || hostname -I | awk '{print $1}')
echo ""
log_ok "===== 部署完成 ====="
log_ok "访问地址: http://${SERVER_IP}:5000"
log_ok "查看状态: docker compose -f $DEPLOY_DIR/docker-compose.yml ps"
log_ok "查看日志: docker logs -f $CONTAINER_NAME"
log_ok "完整日志: $LOG_FILE"
