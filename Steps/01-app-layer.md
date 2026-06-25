# 01 — App Layer (frontend + worker + docker-compose)

**Goal:** a working weather round-trip on your laptop, proven before any cloud exists.
**Prereqts:** Docker + Docker Compose. Nothing else.
**Done when:** you submit "Tokyo" in a browser and get the temperature back, and scaling workers
to 2 shows them splitting the load.

The RPC code below is correctness-critical. A weaker model tends to get three things wrong:
(1) sharing one pika connection across threads (not thread-safe),
(2) acking before the reply is published, (3) no timeout on the blocking wait.
The reference code handles all three. **Copy it closely.**

---

## Repo layout for this step

```
app/
  frontend/
    app.py
    rpc_client.py
    requirements.txt
    templates/index.html
  worker/
    worker.py
    requirements.txt
docker-compose.yml
```

## Step 1 — `app/frontend/rpc_client.py`

One short-lived connection **per request** (simplest thread-safe option at demo scale). Each request
gets its own exclusive, auto-named reply queue, matched by `correlation_id`, with a hard timeout.

```python
import json
import os
import time
import uuid

import pika

QUEUE = "weather_jobs"
RPC_TIMEOUT_SECONDS = 15


def _params():
    creds = pika.PlainCredentials(
        os.environ["RABBITMQ_USERNAME"], os.environ["RABBITMQ_PASSWORD"]
    )
    return pika.ConnectionParameters(
        host=os.environ.get("RABBITMQ_HOST", "localhost"),
        credentials=creds,
        heartbeat=30,
        blocked_connection_timeout=30,
    )


def query_weather(city):
    """Publish a job and block until the worker replies, or time out. Returns dict or None."""
    conn = pika.BlockingConnection(_params())
    try:
        ch = conn.channel()
        ch.queue_declare(queue=QUEUE, durable=False)  # non-durable: emptyDir broker
        callback_queue = ch.queue_declare(queue="", exclusive=True).method.queue
        corr_id = str(uuid.uuid4())
        holder = {}

        def on_response(chx, method, props, body):
            if props.correlation_id == corr_id:
                holder["body"] = body
                chx.basic_ack(method.delivery_tag)

        ch.basic_consume(callback_queue, on_response, auto_ack=False)
        ch.basic_publish(
            exchange="",
            routing_key=QUEUE,
            properties=pika.BasicProperties(
                reply_to=callback_queue,
                correlation_id=corr_id,
                content_type="application/json",
            ),
            body=json.dumps({"city": city, "request_id": corr_id}),
        )

        deadline = time.time() + RPC_TIMEOUT_SECONDS
        while time.time() < deadline and "body" not in holder:
            conn.process_data_events(time_limit=1)  # dispatches the callback

        if "body" in holder:
            return json.loads(holder["body"])
        return None  # timed out (e.g. worker died mid-flight)
    finally:
        conn.close()
```

## Step 2 — `app/frontend/app.py`

```python
from flask import Flask, render_template, request

from rpc_client import query_weather

app = Flask(__name__)


@app.route("/", methods=["GET", "POST"])
def index():
    result = None
    error = None
    if request.method == "POST":
        city = (request.form.get("city") or "").strip()
        if not city:
            error = "Please enter a city."
        else:
            result = query_weather(city)
            if result is None:
                error = "Timed out waiting for a worker. Try again."
            elif "error" in result:
                error = result["error"]
                result = None
    return render_template("index.html", result=result, error=error)


@app.route("/healthz")
def healthz():
    return "ok", 200
```

## Step 3 — `app/frontend/templates/index.html`

Minimal; no JS framework needed.

```html
<!doctype html>
<html>
<head><title>SkyWatch</title></head>
<body style="font-family: sans-serif; max-width: 480px; margin: 3rem auto;">
  <h1>🌤️ SkyWatch</h1>
  <form method="post">
    <input name="city" placeholder="City name" autofocus>
    <button type="submit">Get weather</button>
  </form>
  {% if error %}<p style="color:#b91c1c">{{ error }}</p>{% endif %}
  {% if result %}
    <h2>{{ result.city }}{% if result.country %}, {{ result.country }}{% endif %}</h2>
    <p>Temperature: {{ result.temperature_c }} °C</p>
  {% endif %}
</body>
</html>
```

## Step 4 — `app/worker/worker.py`

`prefetch=1`, **ack only after the reply is published**, reconnect loop.

```python
import json
import os
import time

import pika
import requests

QUEUE = "weather_jobs"
GEO = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST = "https://api.open-meteo.com/v1/forecast"


def get_weather(city):
    g = requests.get(GEO, params={"name": city, "count": 1}, timeout=10).json()
    if not g.get("results"):
        return {"error": "City not found: %s" % city}
    loc = g["results"][0]
    f = requests.get(
        FORECAST,
        params={
            "latitude": loc["latitude"],
            "longitude": loc["longitude"],
            "current": "temperature_2m,weather_code",
        },
        timeout=10,
    ).json()
    cur = f.get("current", {})
    return {
        "city": loc["name"],
        "country": loc.get("country"),
        "temperature_c": cur.get("temperature_2m"),
        "weather_code": cur.get("weather_code"),
    }


def on_message(ch, method, props, body):
    try:
        job = json.loads(body)
        result = get_weather(job["city"])
    except Exception as exc:  # never crash the consumer on one bad job
        result = {"error": str(exc)}
    if props.reply_to:
        ch.basic_publish(
            exchange="",
            routing_key=props.reply_to,
            properties=pika.BasicProperties(
                correlation_id=props.correlation_id, content_type="application/json"
            ),
            body=json.dumps(result),
        )
    ch.basic_ack(delivery_tag=method.delivery_tag)  # ACK AFTER reply -> redelivery is safe


def _params():
    creds = pika.PlainCredentials(
        os.environ["RABBITMQ_USERNAME"], os.environ["RABBITMQ_PASSWORD"]
    )
    return pika.ConnectionParameters(
        host=os.environ.get("RABBITMQ_HOST", "localhost"), credentials=creds, heartbeat=30
    )


def main():
    while True:
        try:
            conn = pika.BlockingConnection(_params())
            ch = conn.channel()
            ch.queue_declare(queue=QUEUE, durable=False)
            ch.basic_qos(prefetch_count=1)
            ch.basic_consume(QUEUE, on_message)
            print("worker: waiting for jobs", flush=True)
            ch.start_consuming()
        except pika.exceptions.AMQPConnectionError:
            print("worker: rabbitmq not ready, retrying in 5s", flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
```

## Step 5 — requirements

`app/frontend/requirements.txt`:
```
flask==3.0.*
pika==1.3.*
gunicorn==22.0.*
```
`app/worker/requirements.txt`:
```
pika==1.3.*
requests==2.32.*
```

## Step 6 — `docker-compose.yml`

```yaml
services:
  rabbitmq:
    image: rabbitmq:3.13-management
    environment:
      RABBITMQ_DEFAULT_USER: skywatch
      RABBITMQ_DEFAULT_PASS: skywatch-dev
    ports: ["5672:5672", "15672:15672"]
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  frontend:
    build: ./app/frontend
    command: gunicorn -b 0.0.0.0:5000 -w 4 --threads 4 app:app
    environment:
      RABBITMQ_HOST: rabbitmq
      RABBITMQ_USERNAME: skywatch
      RABBITMQ_PASSWORD: skywatch-dev
    ports: ["5000:5000"]
    depends_on:
      rabbitmq: {condition: service_healthy}

  worker:
    build: ./app/worker
    command: python worker.py
    environment:
      RABBITMQ_HOST: rabbitmq
      RABBITMQ_USERNAME: skywatch
      RABBITMQ_PASSWORD: skywatch-dev
    depends_on:
      rabbitmq: {condition: service_healthy}
```

> Use `rabbitmq-diagnostics ping` for the **compose** healthcheck (laptop has RAM). In k8s we switch
> to a **TCP probe** on 5672 — see file 05 — because the exec probe stalls under the memory watermark
> alarm on a 1 GiB node.

Minimal Dockerfiles can live here too, but the real multi-stage ones are defined in file `02`.
For now a one-liner image is fine:

`app/frontend/Dockerfile` and `app/worker/Dockerfile` — see file 02 (use those from the start to
avoid rework).

## Done when

```bash
docker compose up --build --scale worker=2
# open http://localhost:5000 , submit "Tokyo" -> temperature appears
# submit a few cities; `docker compose logs -f worker` shows BOTH workers handling jobs
# submit "asdfqwer" -> friendly "City not found" (no crash)
```
Also confirm: kill one worker mid-load (`docker compose stop` one) — requests still succeed via the
other; nothing hangs longer than the 15s timeout.
