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
