from fastapi import FastAPI, Depends, HTTPException, Header, status
from pydantic import BaseModel
import os
import psycopg2
from psycopg2.extras import RealDictCursor

app = FastAPI()

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_NAME = os.getenv("DB_NAME", "inspection")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "postgres")
REPORTER_TOKEN = os.getenv("REPORTER_TOKEN", "secret-token")
VALID_DEVICE_IDS = os.getenv("IOT_DEVICE_IDS", "").split(",")

def get_db():
    conn = psycopg2.connect(
        host=DB_HOST,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        cursor_factory=RealDictCursor
    )
    try:
        yield conn
    finally:
        conn.close()

def verify_token(authorization: str = Header(...)):
    try:
        scheme, token = authorization.split()
        if scheme.lower() != "bearer" or token != REPORTER_TOKEN:
            raise HTTPException(status_code=401, detail="Invalid token")
    except ValueError:
        raise HTTPException(status_code=401, detail="Invalid authorization header")

@app.get("/health")
def health_check():
    return {"status": "ok", "service": "inspection"}

class EventPayload(BaseModel):
    event_id: str
    device_id: str
    timestamp: str
    data: dict = {}

@app.post("/events", status_code=201)
def create_event(payload: EventPayload, db = Depends(get_db), _ = Depends(verify_token)):
    if VALID_DEVICE_IDS and payload.device_id not in VALID_DEVICE_IDS:
        raise HTTPException(status_code=400, detail="Device not allowed")

    cursor = db.cursor()
    try:
        cursor.execute("SELECT event_id FROM events WHERE event_id = %s", (payload.event_id,))
        if cursor.fetchone():
            return {"status": "duplicate", "event_id": payload.event_id}

        cursor.execute(
            "INSERT INTO events (event_id, device_id, timestamp, data) VALUES (%s, %s, %s, %s)",
            (payload.event_id, payload.device_id, payload.timestamp, psycopg2.extras.Json(payload.data))
        )
        db.commit()
        return {"status": "created", "event_id": payload.event_id}
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        cursor.close()
