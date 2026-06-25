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
