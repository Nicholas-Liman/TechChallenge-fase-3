
# Stage 1: Build
FROM python:3.12-slim-bookworm AS builder

WORKDIR /app

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

RUN python -m venv ${VIRTUAL_ENV}

COPY requirements.txt .

RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# Stage 2: Runtime
FROM python:3.12-slim-bookworm AS runner

WORKDIR /app

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PORT=8002
ENV HOST=0.0.0.0

# Cria usuário sem privilégios administrativos
RUN groupadd --system app \
    && useradd --system --gid app --create-home app

# Copia ambiente virtual e aplicação
COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app . .

USER app

EXPOSE 8002

CMD ["gunicorn", "--bind", "0.0.0.0:8002", "--workers", "2", "--timeout", "30", "app:app"]
