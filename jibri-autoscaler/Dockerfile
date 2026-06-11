FROM python:3.11-slim

RUN pip install --no-cache-dir requests docker

COPY main.py /app/main.py

WORKDIR /app

CMD ["python", "main.py"]
