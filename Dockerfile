# 使用 Python 3.11 作为基础镜像
FROM python:3.11-slim

WORKDIR /app

# 安装 curl（用于健康检查）
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# 从官方镜像复制 uv 二进制（不引入额外依赖）
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# 设置环境变量
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_NO_CACHE=1 \
    GUNICORN_TIMEOUT=300 \
    GUNICORN_THREADS=4 \
    IMAP_TIMEOUT=45

# 复制服务端依赖文件（不含 Windows 专用的 pystray / Pillow）
COPY requirements-server.txt .

# 用 uv 安装依赖到系统 Python（容器内无需虚拟环境）
RUN uv pip install --system -r requirements-server.txt gunicorn

# 复制应用代码
COPY . .

# 注入构建提交哈希（CI 传入，本地构建默认 unknown）
ARG BUILD_COMMIT=unknown
RUN echo "${BUILD_COMMIT}" > /app/BUILD_COMMIT

# 创建数据目录
RUN mkdir -p /app/data

# 暴露端口
EXPOSE 5000

# 启动应用（保持单 worker，使用线程提升慢请求容错）
CMD ["sh", "-c", "gunicorn -k gthread -w 1 --threads ${GUNICORN_THREADS:-4} -b 0.0.0.0:5000 --timeout ${GUNICORN_TIMEOUT:-300} --graceful-timeout 30 --access-logfile - --error-logfile - --capture-output web_outlook_app:app"]
