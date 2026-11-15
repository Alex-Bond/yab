"""Tern's marketing site as Vite serves it on Mira's Mac.

Vite's own client script, and the API the dev server proxies to the local
backend (`/api` to localhost:8787), which is only half running: Postgres is
up but the testimonials migration was never run, and the queue the waitlist
writes to (Redis) isn't started.
"""
import time
import uuid

PLANS = {
    "currency": "USD",
    "interval": "seat_month",
    "plans": [
        {
            "id": "free",
            "name": "Free",
            "price": {"monthly": 0, "yearly": 0},
            "seats": {"min": 1, "max": 5},
            "highlight": False,
            "features": ["focus_blocks", "find_a_time", "booking_link", "calendars_2"],
        },
        {
            "id": "team",
            "name": "Team",
            "price": {"monthly": 800, "yearly": 640},
            "seats": {"min": 2, "max": None},
            "highlight": True,
            "badge": "Most popular",
            "features": ["focus_policies", "smart_buffers", "no_meeting_days", "focus_report", "round_robin"],
        },
        {
            "id": "business",
            "name": "Business",
            "price": {"monthly": 1400, "yearly": 1120},
            "seats": {"min": 10, "max": None},
            "highlight": False,
            "features": ["sso_scim", "audit_log", "eu_residency", "priority_support", "uptime_sla"],
        },
    ],
}


def request_id():
    return "req_" + uuid.uuid4().hex[:24]


def api(ctx, obj, status=200, wait=0.02, headers=None):
    """A reply as the backend sends it, through Vite's proxy."""
    time.sleep(wait)
    sent = {
        "Content-Type": "application/json; charset=utf-8",
        "X-Request-Id": request_id(),
        "X-Response-Time": "%dms" % round(wait * 1000 + 2),
        "Vary": "Origin, Accept-Encoding",
    }
    sent.update(headers or {})
    return ctx.json(obj, status, sent)


def handle(req, ctx):
    path = req.path.rstrip("/") or "/"

    if path == "/@vite/client":
        return ctx.file("@vite/client.js", kind="text/javascript; charset=utf-8")

    if not path.startswith("/api/"):
        return None

    if path == "/api/plans" and req.method == "GET":
        return api(ctx, PLANS, wait=0.04, headers={"ETag": 'W/"3f1-plans-v7"'})

    if path == "/api/session" and req.method == "GET":
        return api(ctx, {"error": {"code": "unauthenticated", "message": "No session. Sign in to continue."}},
                   401, wait=0.015, headers={"WWW-Authenticate": 'Session realm="tern"'})

    if path == "/api/waitlist/count" and req.method == "GET":
        return api(ctx, {"count": 2481}, wait=0.06)

    if path == "/api/testimonials" and req.method == "GET":
        rid = request_id()
        return api(ctx, {"error": {"code": "internal_error", "message": 'relation "testimonials" does not exist',
                                   "requestId": rid}}, 500, wait=0.18, headers={"X-Request-Id": rid})

    if path == "/api/waitlist" and req.method == "POST":
        rid = request_id()
        return api(ctx, {"error": {"code": "internal_error",
                                   "message": "Queue \"welcome-email\" unavailable: connect ECONNREFUSED 127.0.0.1:6379",
                                   "requestId": rid}}, 500, wait=0.42, headers={"X-Request-Id": rid})

    if path in ("/api/plans", "/api/session", "/api/waitlist/count", "/api/testimonials", "/api/waitlist"):
        return api(ctx, {"error": {"code": "method_not_allowed", "message": "%s is not allowed on %s" % (req.method, path)}},
                   405, headers={"Allow": "POST" if path == "/api/waitlist" else "GET"})

    return api(ctx, {"error": {"code": "not_found", "message": "No route for %s %s" % (req.method, path)}}, 404)
