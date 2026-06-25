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
