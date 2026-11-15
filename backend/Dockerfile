FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

WORKDIR /app

# psycopg2-binary ships its own libpq; compiler tooling is not required.
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt alembic

COPY app ./app
COPY migrations ./migrations
COPY alembic.ini ./alembic.ini

EXPOSE 8000

# Run schema migrations as a separately approved one-off task, never per replica.
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
