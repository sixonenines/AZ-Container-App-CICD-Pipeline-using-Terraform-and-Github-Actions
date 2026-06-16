# Replace with your real service. This is a minimal placeholder that
# satisfies the Container App's liveness probe on /healthz:8080.
FROM python:3.12-slim
WORKDIR /app
COPY server.py .
EXPOSE 8080
CMD ["python", "server.py"]
